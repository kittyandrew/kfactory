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
//   - Templates collapsed into this file (sdk/templates.ts) rather than
//     a separate module; only renderTemplate + execTemplate are used.
//   - Backend interface trimmed: no abstraction layer over multiple
//     backends -- ntfy is the only backend, inline its send().
import type {
  ContentTemplateMap,
  NotificationEvent,
  NtfyBackendConfig,
} from "./config.js"

// ---- Notification context (event + metadata) ----

export interface EventMetadata {
  sessionId: string
  projectName: string
  branch: string
  timestamp: string
  error?: string
  permissionType?: string
  permissionPatterns?: string[]
}

export interface NotificationContext {
  event: NotificationEvent
  metadata: EventMetadata
}

// ---- Defaults per event ----

const DEFAULT_TITLES: Record<NotificationEvent, string> = {
  "session.idle": "Agent Idle",
  "session.error": "Agent Error",
  "permission.asked": "Permission Asked",
}

// All three event bodies share one shape: `<workspace-slug> · <branch>`.
// The earlier shape carried a static "The agent has finished and is
// waiting for input." sentence -- redundant noise per the operator
// review, since the title + tag already carry the event type. The
// load-bearing per-notification signal is WHICH workspace, on WHICH
// branch -- everything else is constant across notifications.
const DEFAULT_MESSAGES: Record<NotificationEvent, string> = {
  "session.idle": "{project} · {branch}",
  "session.error": "{project} · {branch}",
  "permission.asked": "{project} · {branch}",
}

// Tag names MUST match ntfy's emoji shortcode list
// (https://docs.ntfy.sh/emojis/) -- unrecognised names render as
// literal text in the notification card. `hourglass_done` was a typo
// of nothing real; ntfy doesn't have that shortcode and used to ship
// the bare string. `hourglass` is the canonical "agent idle, waiting"
// emoji (⌛). `warning` (⚠️) + `lock` (🔒) are standard.
const DEFAULT_TAGS: Record<NotificationEvent, string> = {
  "session.idle": "hourglass",
  "session.error": "warning",
  "permission.asked": "lock",
}

// ---- Templates ----

// `{var_name}` substitution from the event context. Unknown vars become "".
function buildTemplateVariables(
  event: NotificationEvent,
  metadata: EventMetadata,
): Record<string, string> {
  return {
    event,
    time: metadata.timestamp,
    project: metadata.projectName,
    branch: metadata.branch,
    session_id: metadata.sessionId,
    error: metadata.error ?? "",
    permission_type: metadata.permissionType ?? "",
    permission_patterns: metadata.permissionPatterns?.join(",") ?? "",
  }
}

// `{var_name}` substitution from the event context. Unknown vars become "".
// Pure string interpolation -- never feeds a shell. Operators configure
// `{value: "..."}` templates with these placeholders; static `{env:VAR}`
// and `{file:path}` substitution already happens at config-load time
// (config.ts:substituteAll). An earlier shape accepted `{command: "..."}`
// templates that ran the operator's shell with substituted (LLM-controlled)
// values -- that's gone; see ContentTemplate's doc comment in config.ts.
function renderTemplate(template: string, context: NotificationContext): string {
  const vars = buildTemplateVariables(context.event, context.metadata)
  return template.replace(/\{(\w+)\}/g, (_, key: string) => vars[key] ?? "")
}

function resolveContent(
  templates: ContentTemplateMap | undefined,
  event: NotificationEvent,
  defaults: Record<NotificationEvent, string>,
  context: NotificationContext,
): string {
  const t = templates?.[event]
  if (!t) return defaults[event]
  return renderTemplate(t.value, context)
}

// ---- HTTP send ----

export async function sendNtfy(
  config: NtfyBackendConfig,
  context: NotificationContext,
): Promise<void> {
  const url = `${config.server}/${config.topic}`
  const title = resolveContent(config.title, context.event, DEFAULT_TITLES, context)
  const message = resolveContent(config.message, context.event, DEFAULT_MESSAGES, context)
  const tags = DEFAULT_TAGS[context.event]

  const headers: Record<string, string> = {
    Title: title,
    Priority: config.priority,
    Tags: tags,
  }
  if (config.iconUrl) headers["X-Icon"] = config.iconUrl
  if (config.token) headers.Authorization = `Bearer ${config.token}`

  const init: RequestInit = {
    method: "POST",
    headers,
    body: message,
    signal: AbortSignal.timeout(config.fetchTimeoutMs),
  }

  const resp = await fetch(url, init)
  if (!resp.ok) {
    throw new Error(`ntfy: POST ${url} -> ${resp.status} ${resp.statusText}`)
  }
}
