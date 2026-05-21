// kfactory /loop plugin -- auto-continues a session until a user-defined
// sentinel string appears in the assistant's output.
//
// Inspired by github.com/charfeng1/opencode-ralph-loop (MIT) and
// Anthropic's ralph-wiggum pattern, but carved down to the minimum that
// kfactory actually needs:
//   - One slash command (/loop) + two tools (loop-start, loop-stop).
//   - User-defined sentinel string passed as `--sentinel "..."`. Default
//     is `<promise>EXHAUSTIVELY COMPLETED</promise>` -- intentionally
//     verbose so the model is unlikely to emit it speculatively. The
//     matcher does LAST-NON-EMPTY-LINE trimmed equality (case-sensitive)
//     across the joined text parts of the last assistant message: the
//     trailing line must equal the sentinel exactly. Mid-response
//     mentions (a plan, a quoted prompt, a paraphrase) do NOT terminate
//     the loop -- only a clean trailing sentinel does. An earlier shape
//     used substring-anywhere matching, which trip-fired whenever the
//     model restated the sentinel for any reason; matchesSentinel's
//     header has the full rationale.
//   - No coupling to kfactory.subscribers.changed; the loop runs on
//     session.idle alone. Operator stops manually with /loop-stop.
//
// State lives in `$XDG_STATE_HOME/kfactory-loop/<hash>.json`, keyed by
// the workspace directory's sha256. NOT in the workspace tree -- prevents
// accidental `git add .` of the state file.
//
// Slash command markdown files (under `commands/`) are NOT auto-installed.
// Consumers wire them into opencode's command dir explicitly (NixOS
// example in the project README). This avoids a workspace-scope plugin
// mutating operator-global config every load.

import { tool, type Plugin, type PluginInput } from "@opencode-ai/plugin"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

// `PluginInput["client"]` is the full opencode SDK client. Aliased so
// signatures don't repeat the indexed-access type.
type OpencodeClient = PluginInput["client"]

// ---- Constants ----

const DEFAULT_SENTINEL = "<promise>EXHAUSTIVELY COMPLETED</promise>"
const DEFAULT_MAX_ITERATIONS = 100
const MIN_MAX_ITERATIONS = 1
const MAX_MAX_ITERATIONS = 10_000
// After this many consecutive HTTP failures (messages OR prompt), clear
// state with a warn log. Distinct from maxIterations (the "no completion
// in N turns" cap); this is the "the server stopped accepting our
// calls" cap. Three so transient blips don't kill an otherwise-healthy
// loop, but unlimited retries on a broken backend don't drain the
// iteration budget either.
const MAX_CONSECUTIVE_FAILURES = 3

// On-disk state schema version. Bump and add a migration if the
// LoopState shape changes incompatibly. readState rejects unknown
// versions rather than parse garbage.
const STATE_SCHEMA_VERSION = 1

// ---- State file location ----

// Per-workspace state lives under $XDG_STATE_HOME (or ~/.local/state)
// rather than inside the workspace tree. Prevents accidental git-add of
// the state file; the workspace dir stays clean of plugin internals.
function stateRootDir(): string {
  const xdg = process.env.XDG_STATE_HOME
  const base = xdg && xdg.length > 0 ? xdg : join(homedir(), ".local", "state")
  return join(base, "kfactory-loop")
}

// Hash the workspace directory to derive a filesystem-safe filename.
// SHA-256 truncated to 16 hex chars (64 bits) -- collision-free for any
// realistic workspace count on a single host.
function workspaceKey(directory: string): string {
  return createHash("sha256").update(directory).digest("hex").slice(0, 16)
}

function stateFile(directory: string): string {
  return join(stateRootDir(), `${workspaceKey(directory)}.json`)
}

// ---- State schema ----

interface LoopState {
  schemaVersion: number
  active: boolean
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
  try {
    const parsed: unknown = JSON.parse(readFileSync(p, "utf-8"))
    if (typeof parsed !== "object" || parsed === null) return null
    const obj = parsed as Record<string, unknown>
    // Reject unknown schema versions -- an older plugin reading a
    // newer state file shouldn't blindly parse fields it doesn't
    // understand. Treat missing/zero as "no state".
    if (obj.schemaVersion !== STATE_SCHEMA_VERSION) {
      console.warn(
        `loop: state file ${p} has schemaVersion=${String(obj.schemaVersion)} ` +
          `(supported: ${STATE_SCHEMA_VERSION}); ignoring`,
      )
      return null
    }
    if (obj.active !== true) return null
    return {
      schemaVersion: STATE_SCHEMA_VERSION,
      active: true,
      iteration: typeof obj.iteration === "number" ? obj.iteration : 0,
      maxIterations:
        typeof obj.maxIterations === "number" ? obj.maxIterations : DEFAULT_MAX_ITERATIONS,
      sentinel: typeof obj.sentinel === "string" ? obj.sentinel : DEFAULT_SENTINEL,
      sessionID: typeof obj.sessionID === "string" ? obj.sessionID : "",
      task: typeof obj.task === "string" ? obj.task : "",
      consecutiveFailures:
        typeof obj.consecutiveFailures === "number" ? obj.consecutiveFailures : 0,
    }
  } catch {
    return null
  }
}

// Atomic write: serialize to <p>.tmp, fsync via close, rename over <p>.
// rename is atomic on the same filesystem (POSIX guarantee). Without
// this, a process kill mid-write truncates the JSON and the next
// readState returns null, silently killing an in-flight loop. With it,
// readers see either the previous state or the new one, never garbage.
function writeStateTo(directory: string, s: LoopState): void {
  const p = stateFile(directory)
  mkdirSync(dirname(p), { recursive: true })
  const tmp = p + ".tmp"
  writeFileSync(tmp, JSON.stringify(s, null, 2))
  renameSync(tmp, p)
}

// Remove the on-disk state file. Throws on rm failure so the caller
// (typically /loop-stop) can surface it. An earlier shape swallowed
// errors silently -- the operator then got `loop-stop: cancelled after
// N iteration(s)` even when the file lingered, and the next
// /loop-start would refuse because state was still active. Propagating
// the error makes that recovery path explicit.
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

// Same as clearState but swallows the error after logging. Use from
// internal cleanup paths (handleIdle's terminal branches, session.deleted)
// where there's no operator-facing surface to throw to. The /loop-stop
// tool uses the throwing variant so an operator-typed stop that
// silently fails is surfaced.
function tryClearState(directory: string): void {
  try {
    clearState(directory)
  } catch {
    // already logged inside clearState
  }
}

// ---- Subagent suppression ----
//
// A session is a SUBAGENT (child) session if its row carries a non-empty
// parentID. opencode dispatches subagent loops as children of the
// operator's session; firing continuations on subagent idles would
// hijack the wrong session and spam the parent. Skip them.
// Fail-CLOSED: if the lookup fails (network, missing session), treat
// the session as a subagent and skip the continuation. False
// suppression on a transient blip is recoverable (next idle retries);
// a false-positive continuation injected into a subagent's session
// mid-task corrupts work the operator cares about.
async function isSubagentSession(client: OpencodeClient, sessionID: string): Promise<boolean> {
  try {
    const resp = await client.session.get({ path: { id: sessionID } })
    return Boolean(resp.data?.parentID)
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.warn(`loop: isSubagentSession(${sessionID}) lookup failed, treating as subagent: ${msg}`)
    return true
  }
}

// ---- Completion detection ----

// Pull the last assistant message via the opencode SDK, concatenate its
// text parts. Returns `null` when no assistant message exists yet
// (typically: the very first session.idle after loop-start, before the
// first prompt has produced a response). Returns the concatenated text
// (possibly empty) otherwise. Caller distinguishes "wait for first
// response" from "response exists, no sentinel".
//
// throwOnError: true so HTTP failures propagate; the caller counts them
// toward the consecutive-failure budget (NOT silently treating them as
// "no sentinel found", which would burn maxIterations on iterations
// that never actually checked completion).
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

// Sentinel match anchored to the LAST non-empty line of the assistant
// response, with whitespace trimmed. An earlier shape used a substring
// match anywhere in the response, which trip-fired whenever the model
// restated the sentinel for any reason (planning, paraphrasing, quoting
// the continuation prompt back). Last-line equality eliminates that
// class: the model has to emit the sentinel as its concluding line,
// not just mention it.
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
    state.task || "(none recorded)",
  ].join("\n")
}

// ---- Plugin entry ----

const LoopPlugin: Plugin = async (input) => {
  const directory = input.directory
  const client = input.client

  // Per-session in-flight tracking. `Map<sessionID, {pending}>` rather
  // than a Set because we need to record "another idle arrived while
  // the handler was running" so we can re-run once after the current
  // handler finishes. The architect's flag was that a strict Set drops
  // information from any idle arriving mid-handler -- multiple agent
  // turns inside one long handler would advance iteration once for N
  // turns. The pending flag bounds the re-run count at 1 per outer
  // event: arrivals during the SECOND run are also dropped, but at
  // that point we've made forward progress and the next true idle
  // will pick up the rest. Prevents both double-prompting AND
  // monotonic loss.
  const inFlight = new Map<string, { pending: boolean }>()

  // Re-read the on-disk state and decide whether a pending write-back
  // is still valid. The race: handleIdle reads state at entry, then
  // awaits an HTTP call; during that await, the operator runs
  // /loop-stop and clearState deletes the file. When the await
  // resolves and we go to writeStateTo, the stale local `state`
  // resurrects the stopped loop. Guard: re-read; if state is gone,
  // OR if the active sessionID changed (operator stopped + started
  // a new loop in a different session in the same workspace), abort
  // the write.
  function stateStillOurs(originalSessionID: string): boolean {
    const current = readState(directory)
    return current !== null && current.sessionID === originalSessionID
  }

  async function handleIdle(sessionID: string): Promise<void> {
    const state = readState(directory)
    if (!state) return
    if (state.sessionID !== sessionID) return

    // Don't fire continuations on subagent idles -- they'd hijack the
    // parent's session.
    if (await isSubagentSession(client, sessionID)) return

    // Try to read the last assistant message. messages() failure is
    // counted toward consecutiveFailures rather than silently treated
    // as "no sentinel" -- otherwise an auth-expired/network-broken
    // backend burns the operator's safety budget on iterations that
    // never actually verified completion.
    let text: string | null
    try {
      text = await lastAssistantText(client, sessionID, directory)
    } catch (err) {
      onFailure(state, err, "messages")
      return
    }

    // If the session has no assistant message yet (very first idle
    // after loop-start, before the initial prompt has been responded
    // to), don't inject a continuation -- that would override the
    // operator's initial prompt with the loop's "continue" text. Wait
    // for the next idle. Doesn't increment iteration.
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

    // Send continuation. Pass throwOnError:true so HTTP errors surface;
    // by default the SDK returns {data, error} without throwing, which
    // would leave us thinking the prompt succeeded when it didn't.
    const next = state.iteration + 1
    try {
      await client.session.prompt({
        path: { id: sessionID },
        body: { parts: [{ type: "text", text: buildContinuation(state, next) }] },
        throwOnError: true,
      })
    } catch (err) {
      onFailure(state, err, "prompt")
      return
    }

    // Success: advance iteration, reset failure counter. Re-read state
    // first so a concurrent /loop-stop wins over our stale read at
    // function entry.
    if (!stateStillOurs(sessionID)) {
      console.info(`loop: state cleared during handler, skipping write-back`)
      return
    }
    writeStateTo(directory, {
      ...state,
      iteration: next,
      consecutiveFailures: 0,
    })
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
    // Same race-guard as the success path: don't resurrect a stopped
    // loop just because a failure handler is finishing up.
    if (!stateStillOurs(state.sessionID)) {
      console.info(`loop: state cleared during handler, skipping failure write-back`)
      return
    }
    writeStateTo(directory, { ...state, consecutiveFailures: failures })
  }

  return {
    tool: {
      "loop-start": tool({
        description:
          "Start an auto-continuation loop. After each assistant turn, the plugin checks the LAST non-empty line of the latest assistant message (trimmed, case-sensitive equality) against `sentinel`; if it doesn't match and iteration < maxIterations, injects a continuation prompt. Use the /loop slash command for the operator-facing flow.",
        args: {
          task: tool.schema
            .string()
            .describe("The task to keep working on until the sentinel appears."),
          sentinel: tool.schema
            .string()
            .default(DEFAULT_SENTINEL)
            .describe(
              "String (case-sensitive) the assistant must emit as the LAST line of its response (trimmed, exact equality) to terminate the loop. Mid-response mentions do NOT terminate.",
            ),
          maxIterations: tool.schema
            .number()
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
          if (sentinel.length === 0) {
            return "loop-start: refusing empty sentinel. Provide a non-empty completion string."
          }
          if (
            !Number.isInteger(maxIterations) ||
            maxIterations < MIN_MAX_ITERATIONS ||
            maxIterations > MAX_MAX_ITERATIONS
          ) {
            return `loop-start: maxIterations must be an integer in [${MIN_MAX_ITERATIONS}, ${MAX_MAX_ITERATIONS}], got ${maxIterations}`
          }
          // Refuse to start if a loop is already active in this
          // workspace. The previous design silently clobbered prior
          // state; if the prior loop was running in a different
          // session, that session's loop died invisibly. Explicit
          // operator intent (/loop-stop first) is the safer default.
          // Architect-recommended Option C (per docs/spec.md decisions
          // log entry on loop scoping).
          const existing = readState(directory)
          if (existing) {
            const sameSession = existing.sessionID === ctx.sessionID
            return (
              `loop-start: refused -- a loop is already active in this workspace ` +
              `for session ${existing.sessionID} (iteration ${existing.iteration}/${existing.maxIterations}). ` +
              `Run /loop-stop${sameSession ? "" : " in that session"} first, then re-run /loop-start.`
            )
          }
          // ctx.sessionID is the canonical invoking session -- per
          // @opencode-ai/plugin's ToolContext, opencode passes the session
          // context to every tool execute. We persist it on start so the
          // session.idle handler can match exactly.
          const state: LoopState = {
            schemaVersion: STATE_SCHEMA_VERSION,
            active: true,
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
      // Widen the event type via string-compare; the published Event
      // union doesn't cover session.deleted in a way that lets us narrow
      // cleanly here.
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
      if (evt.type !== "session.idle") return

      const props = evt.properties
      const sessionID =
        props && typeof props === "object" && "sessionID" in props && typeof props.sessionID === "string"
          ? props.sessionID
          : undefined
      if (!sessionID) return

      // Single-flight guard with at-most-one re-run. If a handler is
      // already running for this session, mark it as pending and
      // return -- when the current handler finishes, the wrapper will
      // re-run once and clear pending. Idles arriving during the
      // SECOND run set pending again but the third re-run is bounded
      // out; the next true idle (after both runs complete) picks up
      // wherever state stopped. Prevents both double-prompting AND
      // the strict-drop's loss of information when multiple idles
      // arrive during a long handler.
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
    },
  }
}

export default LoopPlugin
