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
  ContentTemplate,
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
//
// ContentTemplate-shaped so resolveContent has ONE code path that runs
// every value through renderTemplate (both defaults and operator
// overrides) -- see buildTemplateVariables for the available
// substitutions ({project}, {branch}, {permission_type}, etc).

const DEFAULT_TITLES: Record<NotificationEvent, ContentTemplate> = {
  "session.idle": { value: "Agent Idle" },
  "session.error": { value: "Agent Error" },
  "permission.asked": { value: "Permission Asked" },
}

// Per-notification signal: `<workspace-slug> · <branch>` for the
// async events, `<workspace-slug> · <permission_type>` for the
// interactive one so the operator sees WHAT was asked without
// expanding the notification.
const DEFAULT_MESSAGES: Record<NotificationEvent, ContentTemplate> = {
  "session.idle": { value: "{project} · {branch}" },
  "session.error": { value: "{project} · {branch}" },
  "permission.asked": { value: "{project} · {permission_type}" },
}

// Tags MUST match ntfy's emoji shortcode list
// (https://docs.ntfy.sh/emojis/) -- unrecognised names render as
// literal text in the notification card.
const DEFAULT_TAGS: Record<NotificationEvent, string> = {
  "session.idle": "hourglass",
  "session.error": "warning",
  "permission.asked": "lock",
}

// ---- Templates ----

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

// `{var_name}` substitution from event context (unknown → ""). Pure
// string interpolation; never feeds a shell. Static `{env:VAR}` /
// `{file:path}` substitution happens at config-load time
// (config.ts:substituteAll).
function renderTemplate(template: string, context: NotificationContext): string {
  const vars = buildTemplateVariables(context.event, context.metadata)
  return template.replace(/\{(\w+)\}/g, (_, key: string) => vars[key] ?? "")
}

function resolveContent(
  templates: ContentTemplateMap | undefined,
  event: NotificationEvent,
  defaults: Record<NotificationEvent, ContentTemplate>,
  context: NotificationContext,
): string {
  const template = templates?.[event] ?? defaults[event]
  return renderTemplate(template.value, context)
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
