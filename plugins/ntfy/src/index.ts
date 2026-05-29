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
//   - Routes opencode events locally so kfactory can apply subagent,
//     PTY-pending, and notifyAfter gates before sending.
import type { Plugin, PluginInput } from "@opencode-ai/plugin"
import { basename } from "node:path"

type OpencodeClient = PluginInput["client"]
import { loadConfig, type NotificationEvent, type NtfyPluginConfig } from "./config.js"
import { sendNtfy, type EventMetadata, type NotificationContext } from "./backend.js"
import { unfinishedNotifyOnExitPtys } from "./pty-lifecycle.js"

export { unfinishedNotifyOnExitPtys } from "./pty-lifecycle.js"

export interface NtfyPluginDeps {
  loadConfig?: () => NtfyPluginConfig
  send?: typeof sendNtfy
}

// ---- Pending-PTY check (suppress idle while opencode-pty is running) ----

type PtyNotifyState = "pending" | "clear" | "unknown"

async function ptyNotifyState(client: OpencodeClient, sessionID: string): Promise<PtyNotifyState> {
  try {
    const resp = await client.session.messages({ path: { id: sessionID } })
    const messages = resp.data
    if (!Array.isArray(messages)) {
      console.warn(`ntfy: pty state unknown for ${sessionID}: session.messages returned non-array data`)
      return "unknown"
    }
    return unfinishedNotifyOnExitPtys(messages).size > 0 ? "pending" : "clear"
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.warn(`ntfy: pty state unknown for ${sessionID}: session.messages lookup failed: ${msg}`)
    return "unknown"
  }
}

// ---- Subagent check ----

// Non-empty parentID means subagent; suppress to avoid notification floods.
// Fail closed on lookup errors, and cache only successful immutable reads.
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

function normalizeBranch(branch: unknown): string {
  if (typeof branch !== "string" || branch === "") return "no-git"
  if (branch === "HEAD") return "detached"
  return branch
}

function makeBranchResolver(client: OpencodeClient): {
  current: () => Promise<string>
  update: (branch: unknown) => void
} {
  let cached: string | undefined
  let pending: Promise<void> | undefined

  async function refresh(): Promise<void> {
    try {
      const resp = await client.vcs.get()
      cached = normalizeBranch(resp.data?.branch)
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      console.warn(`ntfy: vcs.get branch lookup failed: ${msg}`)
      cached = "no-git"
    }
  }

  return {
    async current() {
      if (cached !== undefined) return cached
      pending ??= refresh().finally(() => {
        pending = undefined
      })
      await pending
      return cached ?? "no-git"
    },
    update(branch) {
      cached = normalizeBranch(branch)
    },
  }
}

function extractIdle(props: { sessionID: string }, projectName: string, branch: string): EventMetadata {
  return {
    sessionId: props.sessionID,
    projectName,
    branch,
    timestamp: nowISO(),
  }
}

// opencode's NamedError union (ProviderAuthError | UnknownError | etc.)
// always carries `data.message: string`.
function errorMessage(v: unknown): string | undefined {
  const msg = (v as { data?: { message?: unknown } } | null | undefined)?.data?.message
  return typeof msg === "string" ? msg : undefined
}

// opencode emits user interruption as session.error with this name; for
// kfactory's recovery semantics it means "agent stopped, operator may resume".
function isUserInterruption(v: unknown): boolean {
  return isRecord(v) && v.name === "MessageAbortedError"
}

function extractError(props: { sessionID?: string; error?: unknown }, projectName: string, branch: string): EventMetadata {
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

function extractPermission(props: { sessionID: string; permission: string; patterns?: string[] }, projectName: string, branch: string): EventMetadata {
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

type DecodedEvent =
  | { type: "permission.asked"; sessionID: string; permission: string; patterns: string[] }
  | { type: "vcs.branch.updated"; branch: string }
  | { type: "session.status.idle"; sessionID: string }
  | { type: "session.error"; sessionID: string; error: unknown }
  | { type: "ignore" }

function nonEmptyString(v: unknown): v is string {
  return typeof v === "string" && v.length > 0
}

function decodeEvent(evt: { type: string; properties?: unknown }): DecodedEvent | undefined {
  const props = evt.properties
  switch (evt.type) {
    case "permission.asked":
      if (!isRecord(props)) return undefined
      if (!nonEmptyString(props.sessionID)) return undefined
      if (!nonEmptyString(props.permission)) return undefined
      if (!Array.isArray(props.patterns) || !props.patterns.every((p) => typeof p === "string")) return undefined
      return { type: "permission.asked", sessionID: props.sessionID, permission: props.permission, patterns: props.patterns }
    case "vcs.branch.updated":
      if (!isRecord(props)) return undefined
      if (!nonEmptyString(props.branch)) return undefined
      return { type: "vcs.branch.updated", branch: props.branch }
    case "session.status": {
      if (!isRecord(props)) return undefined
      const status = isRecord(props.status) ? props.status : undefined
      if (status?.type !== "idle") return { type: "ignore" }
      if (!nonEmptyString(props.sessionID)) return undefined
      return { type: "session.status.idle", sessionID: props.sessionID }
    }
    case "session.idle":
      return { type: "ignore" }
    case "session.error":
      if (!isRecord(props)) return undefined
      if (!nonEmptyString(props.sessionID)) return undefined
      return { type: "session.error", sessionID: props.sessionID, error: "error" in props ? props.error : undefined }
    default:
      return { type: "ignore" }
  }
}

// ---- Plugin ----

export function makeNtfyPlugin(deps: NtfyPluginDeps = {}): Plugin {
  return async (input) => {
    let config: NtfyPluginConfig
    try {
      config = (deps.loadConfig ?? loadConfig)()
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      if (msg.includes("config not found")) {
        console.info(`ntfy: disabled (${msg})`)
        return {}
      }
      console.error(`ntfy: invalid config (${msg})`)
      throw err
    }

    const projectName = basename(input.directory)
    const client = input.client
    const branch = makeBranchResolver(client)
    const isSubagent = makeSubagentChecker(client)
    const send = deps.send ?? sendNtfy
    const timers = new Map<string, ReturnType<typeof setTimeout>>()
    let disposed = false

    function sendNotification(context: NotificationContext): void {
      if (disposed) return
      void send(config.backend, context).catch((err: unknown) => {
        const msg = err instanceof Error ? err.message : String(err)
        console.warn(`ntfy: send failed: ${msg}`)
      })
    }

    function scheduleNotification(context: NotificationContext, notifyAfterMs: number): void {
      if (disposed) return
      const key = `${context.metadata.sessionId}|${context.event}`
      const prev = timers.get(key)
      if (prev !== undefined) clearTimeout(prev)

      if (notifyAfterMs <= 0) {
        timers.delete(key)
        sendNotification(context)
        return
      }

      const timer = setTimeout(() => {
        timers.delete(key)
        if (disposed) return
        sendNotification(context)
      }, notifyAfterMs)
      timers.set(key, timer)
    }

    // ---- Event dispatch ----

    async function dispatchNotification(event: NotificationEvent, sessionID: string, metadata: EventMetadata): Promise<void> {
      if (disposed) return
      if (!config.enabled) return
      const eventCfg = config.events[event]
      if (!eventCfg.enabled) return

      // Empty session IDs share one debounce key; session.error can arrive
      // before a session exists, so drop instead of coalescing unrelated events.
      if (sessionID === "") {
        console.info(`ntfy: dropping ${event} notification: empty sessionID`)
        return
      }

      if (await isSubagent(sessionID)) return
      if (disposed) return

      // Suppress only session.idle while a notifyOnExit PTY is pending; its
      // eventual `<pty_exited>` message wakes the agent, so idle is misleading.
      if (event === "session.idle") {
        const ptyState = await ptyNotifyState(client, sessionID)
        if (ptyState === "pending") {
          console.info(`ntfy: suppressing session.idle for ${sessionID}: pending PTY (notifyOnExit=true)`)
          return
        }
        if (ptyState === "unknown") {
          console.warn(`ntfy: suppressing session.idle for ${sessionID}: PTY state unknown`)
          return
        }
      }
      if (disposed) return

      const context: NotificationContext = { event, metadata }
      scheduleNotification(context, eventCfg.notifyAfterMs)
    }

    return {
      async dispose() {
        disposed = true
        for (const timer of timers.values()) clearTimeout(timer)
        timers.clear()
      },

      async event({ event }) {
        if (disposed) return
        // @opencode-ai/plugin's Event union doesn't cover permission.asked;
        // widen via string for one dispatch handling all plugin events.
        const evt = event as { type: string; properties?: unknown }
        const decoded = decodeEvent(evt)
        if (!decoded || decoded.type === "ignore") return

        switch (decoded.type) {
          case "permission.asked": {
            const meta = extractPermission({ sessionID: decoded.sessionID, permission: decoded.permission, patterns: decoded.patterns }, projectName, await branch.current())
            await dispatchNotification("permission.asked", decoded.sessionID, meta)
            return
          }
          case "vcs.branch.updated": {
            branch.update(decoded.branch)
            return
          }
          case "session.status.idle": {
            const meta = extractIdle({ sessionID: decoded.sessionID }, projectName, await branch.current())
            await dispatchNotification("session.idle", decoded.sessionID, meta)
            return
          }
          case "session.error": {
            if (isUserInterruption(decoded.error)) {
              const meta = extractIdle({ sessionID: decoded.sessionID }, projectName, await branch.current())
              await dispatchNotification("session.idle", decoded.sessionID, meta)
              return
            }
            const errorVal: { sessionID?: string; error?: unknown } = { sessionID: decoded.sessionID, error: decoded.error }
            const meta = extractError(errorVal, projectName, await branch.current())
            await dispatchNotification("session.error", decoded.sessionID, meta)
            return
          }
        }
      },
    }
  }
}

const Ntfy: Plugin = makeNtfyPlugin()

export default Ntfy
