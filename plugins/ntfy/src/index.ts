// MIT License
//
// Copyright (c) 2026 Anthony Lannutti
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// SPDX-License-Identifier: MIT
//
// Vendored, carved-out subset derived from:
//   - github.com/lannuttia/opencode-ntfy.sh @ 6a8d93d9d75aa7f572821a4e15f04bfc0432a204
//   - github.com/lannuttia/opencode-notification-sdk @ a5bd684df1e16e0bbe0faa8b42b8202cf74dd3e1
//
// kfactory modifications (AGPLv3, see top-level LICENSE):
//   - Event routing + subagent suppression inlined (formerly in
//     opencode-notification-sdk) so wait + skip-on-connect can
//     intercept before send.
//   - Per-event `notifyAfter` wait window: defers backend.send() by
//     N ms; subscriber attach cancels in-flight timers (not re-armed
//     on detach; later events for the same key start fresh windows).
//   - `kfactory.subscribers.changed` is the bus event from the
//     opencode-session-subscribers patch (absolute per-workspace
//     count). On unpatched opencode the count stays 0 and every
//     event fires after its wait -- useful for dev / single-attach.
import type { Plugin, PluginInput } from "@opencode-ai/plugin"
import { spawnSync } from "node:child_process"
import { basename } from "node:path"

type OpencodeClient = PluginInput["client"]
import {
  loadConfig,
  type EventConfig,
  type NotificationEvent,
  type NtfyPluginConfig,
} from "./config.js"
import { sendNtfy, type EventMetadata, type NotificationContext } from "./backend.js"

// ---- Pending-PTY check (suppress idle while opencode-pty is running) ----

// When the agent uses opencode-pty's pty_spawn with notifyOnExit=true,
// the tool returns immediately and the LLM turn completes; session.idle
// fires even though the *task* isn't done. opencode-pty's
// notification-manager.js injects a `<pty_exited>` user message when
// the PTY exits, kicking off a new agent turn. Without this check the
// operator gets a misleading "Agent Idle" ping mid-task.
//
// We resolve unfinished PTYs by reading session history: collect every
// pty_spawn(notifyOnExit=true) tool part, extract the pty_id from its
// output (format: `<pty_spawned>\nID: pty_XXXX\n...`), then scan
// subsequent user messages for the matching `<pty_exited>...ID: pty_X`
// block. Any pty_id without a follow-up is still pending.
//
// Fail-OPEN on lookup error: the alternative (suppressing every idle
// when the lookup fails) silently mutes notifications, which is worse
// than the false-positive we're trying to avoid.
async function hasUnfinishedPtySpawn(client: OpencodeClient, sessionID: string): Promise<boolean> {
  try {
    const resp = await client.session.messages({ path: { id: sessionID } })
    const messages = resp.data
    if (!Array.isArray(messages)) return false

    // Forward walk: assistant pty_spawn(notifyOnExit=true) adds an
    // entry; a subsequent user-role `</pty_exited>...ID: <pty_id>`
    // text part removes it. Any entry surviving the walk is a
    // pending PTY. Closing tag `</pty_exited>` discriminates the
    // plugin's synthetic user message from the agent's prose
    // (system_reminder "Waiting for the `<pty_exited>` signal").
    // Per-id match closes the multi-PTY false-negative class.
    //
    // pty_id format: `pty_` + 8 hex chars (opencode-pty's
    // session-lifecycle.js:5, SESSION_ID_BYTE_LENGTH=4). Tight regex
    // catches a format change loudly instead of silently widening.
    const pending = new Set<string>()
    for (const msg of messages) {
      const role = msg.info?.role
      if (role === "assistant") {
        for (const part of msg.parts ?? []) {
          if (part.type !== "tool" || part.tool !== "pty_spawn") continue
          // Narrow on the discriminated ToolState union. `output` is
          // only present in the "completed" branch; "running" / "error"
          // never carry a pty_id, so skip them.
          if (part.state.status !== "completed") continue
          if (part.state.input?.notifyOnExit !== true) continue
          const m = part.state.output.match(/ID:\s+(pty_[a-f0-9]+)/)
          if (m) pending.add(m[1])
        }
      } else if (role === "user" && pending.size > 0) {
        const text = (msg.parts ?? [])
          .filter((p) => p.type === "text")
          .map((p) => (p as { text: string }).text)
          .join("")
        if (text.includes("</pty_exited>")) {
          for (const id of [...pending]) {
            if (text.includes(`ID: ${id}`)) pending.delete(id)
          }
        }
      }
    }
    return pending.size > 0
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.warn(`ntfy: hasUnfinishedPtySpawn(${sessionID}) lookup failed: ${msg}`)
    return false
  }
}

// ---- Subagent check ----

// A session with non-empty parentID is a subagent (child of the operator's
// session). Firing ntfy per-subagent floods; suppress. Fail-CLOSED on
// lookup error: missed notification recoverable, noisy false-positive
// stream is not. parentID is immutable so successful lookups memoize
// forever; failures don't cache (next event retries).
function makeSubagentChecker(client: OpencodeClient): (sessionId: string) => Promise<boolean> {
  const cache = new Map<string, boolean>()
  return async function isSubagent(sessionId: string): Promise<boolean> {
    const cached = cache.get(sessionId)
    if (cached !== undefined) return cached
    try {
      const resp = await client.session.get({ path: { id: sessionId } })
      const result = Boolean(resp.data?.parentID)
      cache.set(sessionId, result)
      return result
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      console.warn(`ntfy: isSubagent(${sessionId}) lookup failed, treating as subagent: ${msg}`)
      return true
    }
  }
}

// ---- Metadata extractors ----

function nowISO(): string {
  return new Date().toISOString()
}

// Shared with kfactory-adapter (one absolute git path per deployment;
// asymmetric wiring under systemd PATH sanitization turns notification
// bodies into `<slug> · no-git` on healthy workspaces).
const GIT = process.env.KFACTORY_ADAPTER_GIT ?? "git"

// Detached HEAD -> "detached"; non-repo (e.g. clone failed mid-create)
// -> "no-git" so the body still renders a meaningful trailer.
function resolveBranch(directory: string): string {
  try {
    const r = spawnSync(GIT, ["-C", directory, "rev-parse", "--abbrev-ref", "HEAD"], {
      encoding: "utf8",
      timeout: 1500,
    })
    if (r.status !== 0) return "no-git"
    const out = (r.stdout ?? "").trim()
    if (out === "" || out === "HEAD") return "detached"
    return out
  } catch {
    return "no-git"
  }
}

function extractIdle(
  props: { sessionID: string },
  projectName: string,
  branch: string,
): EventMetadata {
  return { sessionId: props.sessionID, projectName, branch, timestamp: nowISO() }
}

// opencode's NamedError union (ProviderAuthError | UnknownError | etc.)
// always carries `data.message: string`.
function errorMessage(v: unknown): string | undefined {
  const msg = (v as { data?: { message?: unknown } } | null | undefined)?.data?.message
  return typeof msg === "string" ? msg : undefined
}

function extractError(
  props: { sessionID?: string; error?: unknown },
  projectName: string,
  branch: string,
): EventMetadata {
  const meta: EventMetadata = {
    sessionId: props.sessionID ?? "",
    projectName,
    branch,
    timestamp: nowISO(),
  }
  const msg = errorMessage(props.error)
  if (msg !== undefined) meta.error = msg
  return meta
}

function extractPermission(
  props: { sessionID: string; permission: string; patterns?: string[] },
  projectName: string,
  branch: string,
): EventMetadata {
  const meta: EventMetadata = {
    sessionId: props.sessionID,
    projectName,
    branch,
    timestamp: nowISO(),
    permissionType: props.permission,
  }
  if (props.patterns && props.patterns.length > 0) {
    meta.permissionPatterns = props.patterns
  }
  return meta
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v)
}

// ---- Plugin ----

const Ntfy: Plugin = async (input) => {
  // Config load failure should NOT crash opencode boot. `info`
  // because missing config = "not set up yet", not a malfunction.
  let config: NtfyPluginConfig
  try {
    config = loadConfig()
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.info(`ntfy: disabled (${msg})`)
    return {}
  }

  const projectName = basename(input.directory)
  const client = input.client
  const isSubagent = makeSubagentChecker(client)

  // ---- Subscriber-tracking state ----
  //
  // `kfactory.subscribers.changed` publishes the ABSOLUTE per-workspace
  // count (not a delta) so we assign directly. Transitions:
  //   0 -> >0  cancel ALL in-flight timers (operator just attached)
  //   >0 -> 0  no-op (next event evaluates fresh; cancelled timers
  //            are NOT re-armed)
  // Cold start while already-attached: next publish (their detach or
  // a new attach) brings us into sync; absolute-count semantics
  // sidesteps the accumulator-desync class.
  //
  // Granularity is per-workspace (the patch publishes on the workspace
  // bus). Subscribing to ANY session in a workspace suppresses ALL
  // notifications for the workspace -- intended ("watching" is
  // workspace-level), but concurrent sessions stay silent while
  // tailing any one.
  let subscriberCount = 0
  const timers = new Map<string, ReturnType<typeof setTimeout>>()

  function timerKey(sessionID: string, event: NotificationEvent): string {
    return `${sessionID}|${event}`
  }

  function cancelAllTimers(reason: string): void {
    const n = timers.size
    if (n === 0) return
    for (const t of timers.values()) clearTimeout(t)
    timers.clear()
    console.info(`ntfy: cancelled ${n} pending notification(s): ${reason}`)
  }

  function scheduleSend(
    key: string,
    eventCfg: EventConfig,
    context: NotificationContext,
  ): void {
    // Replace any existing timer for the same key (latest event wins).
    const prev = timers.get(key)
    if (prev !== undefined) clearTimeout(prev)

    if (eventCfg.notifyAfterMs <= 0) {
      timers.delete(key)
      void sendNtfy(config.backend, context).catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err)
        console.warn(`ntfy: send failed: ${msg}`)
      })
      return
    }

    const t = setTimeout(() => {
      timers.delete(key)
      void sendNtfy(config.backend, context).catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err)
        console.warn(`ntfy: send failed: ${msg}`)
      })
    }, eventCfg.notifyAfterMs)
    timers.set(key, t)
  }

  // ---- Event dispatch ----

  async function dispatchNotification(
    event: NotificationEvent,
    sessionID: string,
    metadata: EventMetadata,
  ): Promise<void> {
    if (!config.enabled) return
    const eventCfg = config.events[event]
    if (!eventCfg.enabled) return

    // Drop empty-sessionID events: timerKey("", event) collides
    // across calls, so a coalesce would silently overwrite pending
    // timers. session.error is the realistic empty case (server-side
    // dispatch before a session is established).
    if (sessionID === "") {
      console.info(`ntfy: dropping ${event} notification: empty sessionID`)
      return
    }

    if (await isSubagent(sessionID)) return
    // Subscriber attached at event time -> suppress unconditionally
    // (non-configurable: "notify when nobody's watching" is the
    // plugin's stated purpose). Next event evaluates fresh.
    if (subscriberCount > 0) return

    // Pending opencode-pty session: agent's LLM is idle but a
    // notifyOnExit=true PTY will inject `<pty_exited>` and wake the
    // agent. Suppress idle to avoid a misleading "task done" ping.
    // Only relevant for session.idle -- session.error / permission.asked
    // are real signals regardless of PTY state.
    if (event === "session.idle" && (await hasUnfinishedPtySpawn(client, sessionID))) {
      console.info(`ntfy: suppressing session.idle for ${sessionID}: pending PTY (notifyOnExit=true)`)
      return
    }

    const key = timerKey(sessionID, event)
    const context: NotificationContext = { event, metadata }
    scheduleSend(key, eventCfg, context)
  }

  return {
    async event({ event }) {
      // @opencode-ai/plugin's Event union doesn't cover permission.asked
      // or kfactory.subscribers.changed; widen via string for a single
      // dispatch handling all four cases.
      const evt = event as { type: string; properties?: unknown }
      const props = evt.properties

      switch (evt.type) {
        case "kfactory.subscribers.changed": {
          if (!isRecord(props) || typeof props.count !== "number") return
          const prev = subscriberCount
          subscriberCount = props.count
          if (subscriberCount > 0 && prev === 0) {
            cancelAllTimers(`subscriber attached (count ${prev} -> ${subscriberCount})`)
          }
          return
        }
        case "permission.asked": {
          // Schema: {permission, patterns: string[], sessionID, ...} per
          // packages/opencode/src/permission/index.ts.
          if (!isRecord(props)) return
          const sessionID = typeof props.sessionID === "string" ? props.sessionID : ""
          const permission = typeof props.permission === "string" ? props.permission : ""
          const patterns = Array.isArray(props.patterns)
            ? (props.patterns.filter((p): p is string => typeof p === "string"))
            : undefined
          const meta = extractPermission(
            { sessionID, permission, patterns },
            projectName,
            resolveBranch(input.directory),
          )
          await dispatchNotification("permission.asked", sessionID, meta)
          return
        }
        case "session.idle": {
          if (!isRecord(props) || typeof props.sessionID !== "string") return
          const meta = extractIdle(
            { sessionID: props.sessionID },
            projectName,
            resolveBranch(input.directory),
          )
          await dispatchNotification("session.idle", props.sessionID, meta)
          return
        }
        case "session.error": {
          if (!isRecord(props)) return
          const sessionID = typeof props.sessionID === "string" ? props.sessionID : ""
          const errorVal: { sessionID?: string; error?: unknown } = {
            sessionID,
            error: "error" in props ? props.error : undefined,
          }
          const meta = extractError(errorVal, projectName, resolveBranch(input.directory))
          await dispatchNotification("session.error", sessionID, meta)
          return
        }
      }
    },
  }
}

export default Ntfy
