// /loop plugin -- auto-continues a session until a sentinel appears as
// the LAST line of the assistant's response (trimmed, case-sensitive
// equality). Mid-response mentions don't terminate.
//
// Inspired by charfeng1/opencode-ralph-loop (MIT) + Anthropic's
// ralph-wiggum pattern; reduced to one slash command (/loop) + two
// tools (loop-start, loop-stop). Default sentinel
// `<promise>EXHAUSTIVELY COMPLETED</promise>` is intentionally verbose
// to avoid speculative emission. Runs on session.status idle; operator
// stops via /loop-stop.
//
// State at $XDG_STATE_HOME/kfactory-loop/<sha256(dir)>.json -- outside
// the workspace tree to prevent accidental `git add .`. Slash-command
// markdowns (commands/) are not auto-installed; consumers wire them
// into opencode's command dir explicitly (README example).

import { tool, type Plugin, type PluginInput } from "@opencode-ai/plugin"
import { createHash, randomUUID } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

type OpencodeClient = PluginInput["client"]

// ---- Constants ----

const DEFAULT_SENTINEL = "<promise>EXHAUSTIVELY COMPLETED</promise>"
const DEFAULT_MAX_ITERATIONS = 100
const MIN_MAX_ITERATIONS = 1
const MAX_MAX_ITERATIONS = 10_000
// Distinct from maxIterations (the "no completion in N turns" cap);
// this caps "server stopped accepting our calls" -- 3 tolerates
// transient blips without letting a broken backend drain the budget.
const MAX_CONSECUTIVE_FAILURES = 3

// Bump + migrate on incompatible LoopState changes; readState rejects
// unknown versions rather than parse garbage.
const STATE_SCHEMA_VERSION = 2

// ---- State file location ----

function stateRootDir(): string {
  const xdg = process.env.XDG_STATE_HOME
  const base = xdg && xdg.length > 0 ? xdg : join(homedir(), ".local", "state")
  return join(base, "kfactory-loop")
}

// 64-bit truncated SHA-256: collision-free for realistic workspace counts.
function workspaceKey(directory: string): string {
  return createHash("sha256").update(directory).digest("hex").slice(0, 16)
}

function stateFile(directory: string): string {
  return join(stateRootDir(), `${workspaceKey(directory)}.json`)
}

// ---- State schema ----

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

interface LoopState {
  schemaVersion: number
  runID: string
  iteration: number
  maxIterations: number
  sentinel: string
  sessionID: string
  task: string
  consecutiveFailures: number
}

function readState(directory: string): LoopState | null {
  const p = stateFile(directory)
  if (!existsSync(p)) return null
  const invalid = (reason: string): null => {
    console.warn(`loop: invalid state file ${p}: ${reason}; clearing`)
    try {
      unlinkSync(p)
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      console.warn(`loop: failed to clear invalid state file ${p}: ${msg}`)
    }
    return null
  }
  try {
    const parsed: unknown = JSON.parse(readFileSync(p, "utf-8"))
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return invalid("expected object")
    const obj = parsed as Record<string, unknown>
    const allowed = new Set(["schemaVersion", "runID", "iteration", "maxIterations", "sentinel", "sessionID", "task", "consecutiveFailures"])
    for (const key of Object.keys(obj)) {
      if (!allowed.has(key)) return invalid(`unknown field ${key}`)
    }
    if (obj.schemaVersion !== STATE_SCHEMA_VERSION) return invalid(`schemaVersion=${String(obj.schemaVersion)}`)
    const runID = obj.runID
    const iteration = obj.iteration
    const maxIterations = obj.maxIterations
    const sentinel = obj.sentinel
    const sessionID = obj.sessionID
    const task = obj.task
    const consecutiveFailures = obj.consecutiveFailures
    if (typeof runID !== "string" || runID.length === 0) return invalid("runID must be a non-empty string")
    if (typeof iteration !== "number" || !Number.isInteger(iteration) || iteration < 0) return invalid("iteration must be a non-negative integer")
    if (typeof maxIterations !== "number" || !Number.isInteger(maxIterations) || maxIterations < MIN_MAX_ITERATIONS || maxIterations > MAX_MAX_ITERATIONS) {
      return invalid(`maxIterations must be an integer in [${MIN_MAX_ITERATIONS}, ${MAX_MAX_ITERATIONS}]`)
    }
    if (!validSentinel(sentinel)) return invalid("sentinel must be non-empty, single-line, and must not have leading/trailing whitespace")
    if (typeof sessionID !== "string" || sessionID.length === 0) return invalid("sessionID must be a non-empty string")
    if (typeof task !== "string" || task.trim().length === 0) return invalid("task must be a non-empty string")
    if (typeof consecutiveFailures !== "number" || !Number.isInteger(consecutiveFailures) || consecutiveFailures < 0) return invalid("consecutiveFailures must be a non-negative integer")
    return {
      schemaVersion: STATE_SCHEMA_VERSION,
      runID,
      iteration,
      maxIterations,
      sentinel,
      sessionID,
      task,
      consecutiveFailures,
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    return invalid(msg)
  }
}

// Atomic write via tmp+rename (POSIX guarantee on same fs); a kill
// mid-write would otherwise truncate to invalid JSON and silently
// kill in-flight loops.
function writeStateTo(directory: string, s: LoopState): void {
  const p = stateFile(directory)
  mkdirSync(dirname(p), { recursive: true })
  const tmp = p + ".tmp"
  writeFileSync(tmp, JSON.stringify(s, null, 2))
  renameSync(tmp, p)
}

// Throws on rm failure so /loop-stop surfaces it -- swallowing meant
// "cancelled after N iterations" while the file lingered and the next
// /loop-start refused.
function clearState(directory: string): void {
  const p = stateFile(directory)
  if (!existsSync(p)) return
  try {
    unlinkSync(p)
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.warn(`loop: clearState ${p} failed: ${msg}`)
    throw err
  }
}

// Swallowing variant for internal cleanup paths (no operator surface
// to throw to). /loop-stop uses the throwing variant.
function tryClearState(directory: string): void {
  try {
    clearState(directory)
  } catch {
    // already logged inside clearState
  }
}

type SessionKind = "root" | "subagent" | "missing" | "unknown"

function isNotFoundError(err: unknown): boolean {
  if (!isRecord(err)) return false
  const direct = err.status ?? err.statusCode
  if (direct === 404) return true
  const response = isRecord(err.response) ? err.response : undefined
  if (response?.status === 404) return true
  const error = isRecord(err.error) ? err.error : undefined
  return error?.status === 404 || error?.statusCode === 404
}

// Non-empty parentID = subagent (child of operator's session). Firing
// continuations on subagent idles would hijack the wrong session and
// spam the parent. Fail-CLOSED on lookup error: false-positive
// injection mid-task corrupts work the operator cares about; missed
// suppression retries next idle.
async function sessionKind(client: OpencodeClient, sessionID: string): Promise<SessionKind> {
  try {
    const resp = await client.session.get({ path: { id: sessionID } })
    return resp.data?.parentID ? "subagent" : "root"
  } catch (err) {
    if (isNotFoundError(err)) return "missing"
    const msg = err instanceof Error ? err.message : String(err)
    console.warn(`loop: session.get(${sessionID}) lookup failed, skipping injection: ${msg}`)
    return "unknown"
  }
}

function validSentinel(sentinel: unknown): sentinel is string {
  return (
    typeof sentinel === "string" &&
    sentinel.trim().length > 0 &&
    sentinel === sentinel.trim() &&
    !sentinel.includes("\n") &&
    !sentinel.includes("\r")
  )
}

// ---- Completion detection ----

// `null` = no assistant message yet (first idle after loop-start);
// caller distinguishes that from "response exists, no sentinel".
// throwOnError so HTTP failures propagate to the consecutive-failure
// budget (silently treating them as "no sentinel" would burn
// maxIterations on iterations that never checked completion).
async function lastAssistantText(
  client: OpencodeClient,
  sessionID: string,
  directory: string,
): Promise<string | null> {
  const resp = await client.session.messages({
    path: { id: sessionID },
    query: { directory },
    throwOnError: true,
  })
  const data = resp.data ?? []
  for (let i = data.length - 1; i >= 0; i--) {
    const row = data[i]
    if (!row || row.info.role !== "assistant") continue
    const texts: string[] = []
    for (const part of row.parts) {
      // Discriminated union: only `type: "text"` parts carry `text`.
      if (part.type === "text") texts.push(part.text)
    }
    return texts.join("\n")
  }
  return null
}

// Last-non-empty-line trimmed equality (case-sensitive). Substring-
// anywhere would trip-fire whenever the model restated the sentinel
// (planning, paraphrasing, quoting back).
function matchesSentinel(text: string, sentinel: string): boolean {
  const lines = text.split(/\r?\n/)
  for (let i = lines.length - 1; i >= 0; i--) {
    const trimmed = lines[i]!.trim()
    if (trimmed.length === 0) continue
    return trimmed === sentinel
  }
  return false
}

function buildContinuation(state: LoopState, nextIteration: number): string {
  return [
    `[loop iteration ${nextIteration}/${state.maxIterations}]`,
    ``,
    `Your last turn did not contain the completion sentinel. Continue`,
    `working on the task. When fully done, emit the sentinel as the very`,
    `LAST line of your response (it must be the final non-empty line,`,
    `trimmed, and match exactly):`,
    ``,
    `    ${state.sentinel}`,
    ``,
    `If the sentinel appears anywhere ELSE in your output (a plan, a`,
    `restatement, a tool result), the loop will NOT terminate -- only`,
    `the trailing line is checked.`,
    ``,
    `Original task:`,
    state.task,
  ].join("\n")
}

// ---- Plugin entry ----

const LoopPlugin: Plugin = async (input) => {
  const directory = input.directory
  const client = input.client

  // {pending} (not Set): records "another idle arrived mid-handler"
  // so we re-run once when the current handler finishes -- without
  // that flag, multiple agent turns inside one long handler would
  // advance iteration once for N turns. Capped at one re-run per
  // outer event so a third nested arrival doesn't recurse; next
  // true idle picks up the rest.
  const inFlight = new Map<string, { pending: boolean }>()

  // Race guard: handleIdle reads state then awaits HTTP; during the
  // await /loop-stop can clearState. Without re-reading, writeStateTo
  // would resurrect the stopped loop from the stale local. Also
  // catches the operator stopping + starting in the same session: runID
  // changes on every loop-start.
  function stateStillOurs(original: LoopState): boolean {
    const current = readState(directory)
    return current !== null && current.sessionID === original.sessionID && current.runID === original.runID
  }

  async function handleIdle(sessionID: string): Promise<void> {
    const state = readState(directory)
    if (!state) return
    if (state.sessionID !== sessionID) return

    const kind = await sessionKind(client, sessionID)
    if (kind === "missing") {
      console.warn(`loop: session ${sessionID} no longer exists, clearing loop state`)
      tryClearState(directory)
      return
    }
    if (kind !== "root") return

    let text: string | null
    try {
      text = await lastAssistantText(client, sessionID, directory)
    } catch (err) {
      onFailure(state, err, "messages")
      return
    }

    // First idle (no assistant response yet) -- don't inject; that
    // would override the operator's initial prompt. Wait for next idle.
    if (text === null) return

    if (matchesSentinel(text, state.sentinel)) {
      console.info(`loop: completed after ${state.iteration} iteration(s)`)
      tryClearState(directory)
      return
    }

    if (state.iteration >= state.maxIterations) {
      console.warn(`loop: hit maxIterations=${state.maxIterations}, stopping`)
      tryClearState(directory)
      return
    }

    // Bump iteration on disk BEFORE awaiting the prompt call. The
    // event handler single-flights handleIdle per sessionID via
    // `inFlight` (a second idle arriving mid-await only sets
    // `tracker.pending = true` and returns), so there's no concurrent
    // second handleIdle. But the SEQUENTIAL re-entry via tracker.pending
    // (the re-run inside the try block at the end of the outer event
    // handler) reads state again after the first handler returns. If
    // the first handler writes iteration AFTER the prompt await, the
    // re-run reads stale state.iteration -- both injections compute
    // `next = state.iter + 1 = same value` and stall at the same
    // iteration label. User-visible as "loop showed 2/20 then stopped
    // advancing." Persisting `next` BEFORE the await ensures the
    // re-run sees the bumped value and either injects N+1 or hits the
    // cap.
    //
    // Trade-off: if the prompt call later fails, iteration counts a
    // turn that never produced an assistant response. onFailure
    // bumps consecutiveFailures and writes that back, but iteration
    // stays advanced. Operator sees iter=K with K-1 actual model
    // turns. Better than the alternative (silent iteration stall).
    const next = state.iteration + 1
    if (!stateStillOurs(state)) {
      console.info(`loop: state cleared during handler, skipping pre-inject bump`)
      return
    }
    writeStateTo(directory, {
      ...state,
      iteration: next,
      consecutiveFailures: 0,
    })

    // throwOnError: SDK defaults to {data, error} without throwing,
    // which would leave us thinking the prompt succeeded when it didn't.
    try {
      await client.session.prompt({
        path: { id: sessionID },
        body: { parts: [{ type: "text", text: buildContinuation(state, next) }] },
        throwOnError: true,
      })
    } catch (err) {
      onFailure({ ...state, iteration: next }, err, "prompt")
      return
    }
  }

  async function processIdle(sessionID: string): Promise<void> {
    // Single-flight + at-most-one re-run. See inFlight comment above.
    const existing = inFlight.get(sessionID)
    if (existing !== undefined) {
      existing.pending = true
      return
    }
    const tracker = { pending: false }
    inFlight.set(sessionID, tracker)
    try {
      await handleIdle(sessionID)
      if (tracker.pending) {
        tracker.pending = false
        await handleIdle(sessionID)
      }
    } finally {
      inFlight.delete(sessionID)
    }
  }

  function onFailure(state: LoopState, err: unknown, op: string): void {
    const failures = state.consecutiveFailures + 1
    const msg = err instanceof Error ? err.message : String(err)
    if (failures >= MAX_CONSECUTIVE_FAILURES) {
      console.warn(
        `loop: ${failures} consecutive ${op} failures, stopping. Last error: ${msg}`,
      )
      tryClearState(directory)
      return
    }
    console.warn(`loop: ${op} failed (${failures}/${MAX_CONSECUTIVE_FAILURES}): ${msg}`)
    if (!stateStillOurs(state)) {
      console.info(`loop: state cleared during handler, skipping failure write-back`)
      return
    }
    writeStateTo(directory, { ...state, consecutiveFailures: failures })
  }

  async function processCurrentStatus(): Promise<void> {
    const state = readState(directory)
    if (!state) return
    try {
      const session = client.session as unknown as {
        status?: (args: { query: { directory: string }; throwOnError: true }) => Promise<{ data?: Record<string, unknown> }>
      }
      if (typeof session.status !== "function") {
        console.warn("loop: client.session.status unavailable; waiting for next session.status event")
        return
      }
      const resp = await session.status({ query: { directory }, throwOnError: true })
      const status = resp.data?.[state.sessionID]
      if (status === undefined) {
        await processIdle(state.sessionID)
        return
      }
      if (!isRecord(status)) {
        console.warn(`loop: session.status for ${state.sessionID} was malformed; waiting for next event`)
        return
      }
      if (status.type === "idle") await processIdle(state.sessionID)
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      console.warn(`loop: session.status init check failed: ${msg}`)
    }
  }

  void processCurrentStatus()

  return {
    tool: {
      "loop-start": tool({
        description:
          "Start an auto-continuation loop. After each assistant turn, the plugin checks the LAST non-empty line of the latest assistant message (trimmed, case-sensitive equality) against `sentinel`; if it doesn't match and iteration < maxIterations, injects a continuation prompt. Use the /loop slash command for the operator-facing flow.",
        args: {
          task: tool.schema
            .string()
            .min(1)
            .describe("The task to keep working on until the sentinel appears."),
          sentinel: tool.schema
            .string()
            .min(1)
            .default(DEFAULT_SENTINEL)
            .describe(
              "String (case-sensitive) the assistant must emit as the LAST line of its response (trimmed, exact equality) to terminate the loop. Mid-response mentions do NOT terminate.",
            ),
          maxIterations: tool.schema
            .number()
            .int()
            .min(MIN_MAX_ITERATIONS)
            .max(MAX_MAX_ITERATIONS)
            .default(DEFAULT_MAX_ITERATIONS)
            .describe(
              `Safety cap; loop stops after this many continuations (must be integer in [${MIN_MAX_ITERATIONS}, ${MAX_MAX_ITERATIONS}]).`,
            ),
        },
        async execute(args, ctx) {
          const task = args.task
          const sentinel = args.sentinel ?? DEFAULT_SENTINEL
          const maxIterations = args.maxIterations ?? DEFAULT_MAX_ITERATIONS
          if (task.trim().length === 0) {
            return "loop-start: refusing empty task. Provide a non-empty task string."
          }
          if (!validSentinel(sentinel)) {
            return "loop-start: refusing invalid sentinel. Provide a non-empty single-line completion string with no leading or trailing whitespace."
          }
          if (
            !Number.isInteger(maxIterations) ||
            maxIterations < MIN_MAX_ITERATIONS ||
            maxIterations > MAX_MAX_ITERATIONS
          ) {
            return `loop-start: maxIterations must be an integer in [${MIN_MAX_ITERATIONS}, ${MAX_MAX_ITERATIONS}], got ${maxIterations}`
          }
          // Refuse to start if a loop is already active in this
          // workspace -- silent clobber would kill any in-flight loop
          // running in a different session invisibly. (See docs/spec.md
          // decisions log entry on loop scoping.)
          const existing = readState(directory)
          if (existing) {
            const sameSession = existing.sessionID === ctx.sessionID
            return (
              `loop-start: refused -- a loop is already active in this workspace ` +
              `for session ${existing.sessionID} (iteration ${existing.iteration}/${existing.maxIterations}). ` +
              `Run /loop-stop${sameSession ? "" : " in that session"} first, then re-run /loop-start.`
            )
          }
          const kind = await sessionKind(client, ctx.sessionID)
          if (kind !== "root") {
            if (kind === "subagent") {
              return `loop-start: refused -- session ${ctx.sessionID} is a child/subagent session. Start the loop from the parent operator session.`
            }
            if (kind === "missing") {
              return `loop-start: refused -- session ${ctx.sessionID} does not exist.`
            }
            return `loop-start: refused -- could not verify session ${ctx.sessionID} is a root operator session.`
          }
          // ctx.sessionID is the invoking session (per ToolContext);
          // persisted so session.status idle matches exactly.
          const state: LoopState = {
            schemaVersion: STATE_SCHEMA_VERSION,
            runID: randomUUID(),
            iteration: 0,
            maxIterations,
            sentinel,
            sessionID: ctx.sessionID,
            task,
            consecutiveFailures: 0,
          }
          writeStateTo(directory, state)
          console.info(
            `loop: started for session ${ctx.sessionID} (max ${maxIterations}, sentinel=${sentinel})`,
          )
          return [
            `loop-start: active (max ${maxIterations} iterations, session ${ctx.sessionID}).`,
            `sentinel: ${sentinel}`,
            `task: ${task}`,
            ``,
            `Emit the sentinel as the LAST line of your response when the`,
            `task is fully complete. The matcher checks the trailing`,
            `non-empty line only -- mentioning the sentinel mid-response`,
            `(planning, paraphrasing, restating the prompt) does NOT`,
            `terminate the loop. Operator can interrupt with /loop-stop.`,
          ].join("\n")
        },
      }),

      "loop-stop": tool({
        description: "Cancel the active /loop, if any. No-op if no loop is active.",
        args: {},
        async execute() {
          const s = readState(directory)
          if (!s) return "loop-stop: no active loop."
          clearState(directory)
          console.info(`loop: stopped after ${s.iteration} iteration(s)`)
          return `loop-stop: cancelled after ${s.iteration} iteration(s).`
        },
      }),
    },

    event: async ({ event }) => {
      // String-compare to widen: published Event union doesn't cover
      // session.deleted cleanly.
      const evt: { type: string; properties?: unknown } = event
      if (evt.type === "session.deleted") {
        const props = evt.properties
        if (props && typeof props === "object" && "sessionID" in props) {
          const deletedID = (props as { sessionID?: unknown }).sessionID
          if (typeof deletedID === "string") {
            const state = readState(directory)
            if (state && state.sessionID === deletedID) {
              console.info(`loop: session ${deletedID} deleted, clearing loop state`)
              tryClearState(directory)
            }
            // Drop the in-flight marker for a deleted session.
            inFlight.delete(deletedID)
          }
        }
        return
      }
      if (evt.type === "session.idle") return
      if (evt.type !== "session.status") return

      const props = evt.properties
      if (!isRecord(props)) return
      const status = isRecord(props.status) ? props.status : undefined
      if (status?.type !== "idle") return
      const sessionID = typeof props.sessionID === "string" ? props.sessionID : undefined
      if (!sessionID) return

      await processIdle(sessionID)
    },
  }
}

export default LoopPlugin
