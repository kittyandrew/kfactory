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
//   - Event routing + subagent suppression (formerly in
//     opencode-notification-sdk/src/plugin-factory.ts) is inlined here so
//     the wait + skip-on-connect logic can intercept before send.
//   - Per-event `notifyAfter` wait window: after a notification-trigger
//     event fires, the plugin defers `backend.send()` by N ms. During
//     that window, if ANY opencode subscriber connects to this workspace,
//     the pending send is cancelled (sticky -- subsequent detaches don't
//     re-arm). Once cancelled, the operator must take a new action to
//     trigger another notification.
//   - `kfactory.subscribers.changed` is the bus event published by the
//     `opencode-session-subscribers` patch on every SSE attach/detach.
//     The plugin tracks the latest count and reacts. Plugin works on
//     unpatched opencode too -- the count stays at 0 (never observed
//     incrementing), so every event fires after its `notifyAfter`
//     wait. Useful for development / single-attach deployments.
//
// Plugin entry point. The npm-package shape is honored via package.json's
// `exports["./server"]` field; opencode's PluginLoader follows that.
import type { Plugin, PluginInput } from "@opencode-ai/plugin"
import { spawnSync } from "node:child_process"
import { basename } from "node:path"

// `PluginInput["client"]` is the full opencode SDK client (returned by
// `createOpencodeClient`). Aliased here so signatures inside this file
// don't repeat the indexed-access type.
type OpencodeClient = PluginInput["client"]
import {
  loadConfig,
  type EventConfig,
  type NotificationEvent,
  type NtfyPluginConfig,
} from "./config.js"
import { sendNtfy, type EventMetadata, type NotificationContext } from "./backend.js"

// ---- Subagent check ----

// A session is a SUBAGENT (child) session if its row carries a non-empty
// parentID. opencode dispatches subagent loops as children of the operator's
// session; firing ntfy for every subagent idle/error would flood. Suppress.
// Fail-CLOSED: if the lookup fails (network, missing session), treat the
// session as a subagent and suppress. The operator who installed ntfy is
// implicitly choosing fewer-but-correct notifications; a missed
// notification on a network blip is recoverable, a noisy false-positive
// stream of subagent notifications during a long task is not.
//
// Returns a closure that memoizes successful lookups per sessionID.
// parentID is immutable after session creation, so caching forever is
// safe. Failures are NOT cached -- a transient blip shouldn't pin the
// session as a subagent for the plugin's lifetime; the next event
// retries. Map sits in the plugin-instance closure (per-workspace).
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

// `KFACTORY_ADAPTER_GIT` is the same env var the kfactory-adapter
// plugin uses for its git path (see plugins/kfactory-adapter/src/
// index.ts -- "PATH-resolved defaults work in interactive shells
// but FAIL under systemd User= units, which sanitize PATH down to a
// minimal coreutils/findutils/grep set"). Reusing the SAME var here
// rather than minting a separate `KFACTORY_NTFY_GIT` because
// operators wire one absolute git path per deployment; an asymmetric
// wiring (adapter resolves git, ntfy doesn't) is exactly the silent
// systemd-PATH degradation that turns notification bodies into
// `<slug> · no-git` on healthy workspaces.
const GIT = process.env.KFACTORY_ADAPTER_GIT ?? "git"

// Resolve the workspace's current git branch at NOTIFICATION time.
// Run `git rev-parse --abbrev-ref HEAD` inside the workspace dir; on
// detached HEAD this prints "HEAD" which we re-label to "detached" for
// readability. If the dir isn't a repo at all (e.g. clone failed
// mid-create -- waybap incident) we return "no-git" so the body still
// renders a meaningful "<slug> · no-git" rather than an empty trailer.
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

// The session.error event's `error` is a discriminated union of opencode's
// NamedError shapes (ProviderAuthError | UnknownError | etc. -- see
// @opencode-ai/sdk's gen/types.gen.ts). All variants share `data.message:
// string`. Read it via optional chaining + a type guard on the leaf
// string. Returning undefined is fine; the operator still gets the
// notification with default messaging, just no error context.
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
  // Config load failure should NOT crash opencode boot. Log + disable
  // the plugin instead -- the host process matters more than
  // notifications. `info` rather than `warn`: this is a configuration
  // STATE (operator hasn't set up notifications yet), not a malfunction.
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
  // Updated by `kfactory.subscribers.changed` bus events from the
  // opencode-session-subscribers patch. The patch publishes the
  // ABSOLUTE per-workspace subscriber count (not a delta), so we
  // assign it directly. `>0` means an SSE / web client is attached --
  // the operator can see events live, so new notifications are skipped
  // and any pending (within-notifyAfter) ones are cancelled.
  //
  // Semantics on subscriber transition:
  //   count 0 -> >0  cancel ALL in-flight timers (operator just attached)
  //   count >0 -> 0  no-op (next event will schedule a fresh timer if
  //                  appropriate; we do NOT re-arm timers that were
  //                  cancelled by the attach)
  // Cancellation is per-timer, not per-key. A subsequent event for the
  // same (sessionID, eventType) -- after the cancel -- creates a fresh
  // timer and the fresh window decides fresh.
  //
  // Cold start: if the plugin loads while a subscriber is already
  // attached, we missed the publish announcing them. The next publish
  // (the subscriber's detach, or a new subscriber's attach) brings us
  // into sync immediately. Absolute-count semantics removes the
  // accumulator-desync class that a delta-based protocol had.
  //
  // Granularity: count is **per-workspace**, NOT per-session. The
  // upstream patch publishes the absolute count on the workspace
  // instance bus, which is workspace-scoped. Consequence: attaching
  // an SSE subscriber to ANY session inside a workspace suppresses
  // (and cancels in-flight) notifications for ALL sessions in that
  // workspace. This is the intended semantic -- "watching" is a
  // workspace-level concept and operators typically rotate between
  // sessions within a workspace -- but it means concurrent sessions
  // in the same workspace will all stay silent while you're tailing
  // any one of them.
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

    // Drop any event with an empty sessionID. session.error is the
    // realistic case (cause: server-side dispatch before a session is
    // established); session.idle and permission.asked gate sessionID
    // to non-empty strings at parse time so this is defense in depth
    // for them. The reason to drop unconditionally: timerKey("", event)
    // = "|<event>" collides across calls for the same event, so a
    // second empty-sessionID arrival of the same event would replace
    // the first's pending timer instead of scheduling its own. Better
    // to drop than to silently coalesce.
    if (sessionID === "") {
      console.info(`ntfy: dropping ${event} notification: empty sessionID`)
      return
    }

    // Subagent suppression -- before scheduling timers we don't need.
    if (await isSubagent(sessionID)) return

    // If a subscriber is currently attached at event time, suppress THIS
    // notification entirely. A subsequent event after they detach will
    // schedule a fresh timer normally -- we do NOT track per-key sticky
    // state, so the next event gets a clean evaluation. Non-configurable:
    // the plugin's stated purpose is "notify only when nobody's
    // watching" so an opt-out doesn't make sense.
    if (subscriberCount > 0) return

    const key = timerKey(sessionID, event)
    const context: NotificationContext = { event, metadata }
    scheduleSend(key, eventCfg, context)
  }

  return {
    async event({ event }) {
      // The published @opencode-ai/plugin Event union doesn't cover
      // permission.asked or our kfactory.subscribers.changed; widen via
      // string for a single dispatch table that handles all four cases
      // consistently. Per-branch we cast properties into the narrow shape
      // the handler needs.
      const evt = event as { type: string; properties?: unknown }
      const props = evt.properties

      switch (evt.type) {
        case "kfactory.subscribers.changed": {
          // The opencode-session-subscribers patch publishes the absolute
          // per-workspace count. We trust it directly -- no accumulation,
          // no clamping, no cold-start asymmetry.
          if (!isRecord(props) || typeof props.count !== "number") return
          const prev = subscriberCount
          subscriberCount = props.count
          if (subscriberCount > 0 && prev === 0) {
            cancelAllTimers(`subscriber attached (count ${prev} -> ${subscriberCount})`)
          }
          return
        }
        case "permission.asked": {
          // The opencode permission.asked event ships the
          // PermissionRequest schema (packages/opencode/src/permission/
          // index.ts:32-44): {permission: string, patterns: Array<string>,
          // sessionID, metadata, always, tool?}. An earlier shape of this
          // handler read `props.type` and `props.pattern` (singular) --
          // wrong field names -- so every permission.asked notification
          // shipped with empty permissionType + undefined
          // permissionPatterns since carve-out. Fixed.
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
