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
//   - Per-event `notifyAfter` shorthand-duration ("3s") wait window.
//   - Removed runtime dependency on `iso8601-duration`; minimal in-tree
//     parser instead (`PT...` only -- weeks/days/years rejected as
//     out-of-scope for notification timers).
//   - Removed `opencode-notification-sdk` indirection; the event-routing
//     logic lives in ./index.ts so kfactory-specific gates and debounce
//     happen in one place.
//
// Config file: $XDG_CONFIG_HOME/opencode/notification-ntfy.json (or
// ~/.config/opencode/notification-ntfy.json on linux). `{env:VAR}` and
// `{file:path}` placeholders inside string values are substituted at
// load time -- useful for keeping the ntfy token out of the config.
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

// ---- Event taxonomy ----

export const NOTIFICATION_EVENTS = ["session.idle", "session.error", "permission.asked"] as const
export type NotificationEvent = (typeof NOTIFICATION_EVENTS)[number]

// ---- Duration parsing ----
//
// Shorthand strings: `<number><unit>` segments where unit ∈ h|m|s
// (case-insensitive), e.g. `"3s"`, `"1h30m"`, `"0.5s"`, `"0s"`.
// Returns MILLISECONDS (setTimeout/AbortSignal.timeout-compatible).

const DURATION_RE = /^(?:\s*(\d+(?:\.\d+)?)\s*([hms])\s*)+$/i
const DURATION_SEGMENT_RE = /(\d+(?:\.\d+)?)\s*([hms])/gi

export function parseDuration(s: string): number {
  if (!DURATION_RE.test(s)) {
    throw new Error(`ntfy: invalid duration "${s}"; expected shorthand like "3s", "5m", "1h30m"`)
  }
  let totalSec = 0
  for (const m of s.matchAll(DURATION_SEGMENT_RE)) {
    const value = parseFloat(m[1]!)
    const unit = m[2]!.toLowerCase()
    if (unit === "h") totalSec += value * 3600
    else if (unit === "m") totalSec += value * 60
    else totalSec += value
  }
  return Math.round(totalSec * 1000)
}

function parseRequiredDurationMs(value: unknown, fieldName: string): number {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`ntfy: ${fieldName} must be a non-empty duration string`)
  }
  return parseDuration(value)
}

// ---- Content templates (per-event) ----

export interface ValueTemplate {
  readonly value: string
}
// Templates are value-only: `{command: ...}` executed the operator's shell;
// use config-load `{env:VAR}` / `{file:path}` substitution for dynamic values.
export type ContentTemplate = ValueTemplate
export type ContentTemplateMap = Partial<Record<NotificationEvent, ContentTemplate>>

// ---- Event-level config ----

export interface EventConfig {
  /** Whether this event type triggers notifications at all. */
  enabled: boolean
  /**
   * `0` means immediate. Configured as a shorthand string in JSON (`"3m"`).
   * Nonzero values debounce notifications for the same `(session, event)`
   * key; the latest event replaces the previous pending timer.
   */
  notifyAfterMs: number
}

// ---- Backend (ntfy.sh) config ----

const VALID_PRIORITIES = ["min", "low", "default", "high", "max"] as const
export type NtfyPriority = (typeof VALID_PRIORITIES)[number]

// Default 10s: a hung ntfy server otherwise stalls Hook.event
// indefinitely (dispatcher awaits) and starves other plugin work.
// Override via `fetchTimeout: "30s"` in the config file.
export const DEFAULT_FETCH_TIMEOUT_MS = 10_000

export interface NtfyBackendConfig {
  topic: string
  server: string
  token?: string
  priority: NtfyPriority
  iconUrl?: string
  fetchTimeoutMs: number
  title?: ContentTemplateMap
  message?: ContentTemplateMap
}

// ---- Full plugin config ----

export interface NtfyPluginConfig {
  enabled: boolean
  events: Record<NotificationEvent, EventConfig>
  backend: NtfyBackendConfig
}

function defaultEvents(): Record<NotificationEvent, EventConfig> {
  return {
    "session.idle": { enabled: true, notifyAfterMs: 0 },
    "session.error": { enabled: true, notifyAfterMs: 0 },
    "permission.asked": { enabled: true, notifyAfterMs: 0 },
  }
}

// ---- Substitution: {env:VAR} and {file:path} ----

function substituteString(value: string, configDir: string): string {
  const envSubstituted = value.replace(/\{env:([^}]+)\}/g, (_m, varName: string): string => {
    const v = process.env[varName]
    if (v === undefined) {
      throw new Error(`ntfy: config {env:${varName}} -- env var unset`)
    }
    return v
  })
  return envSubstituted.replace(/\{file:([^}]+)\}/g, (_m, filePath: string): string => {
    const resolved = filePath.startsWith("/") ? filePath : filePath.startsWith("~") ? join(homedir(), filePath.slice(1)) : join(configDir, filePath)
    try {
      return readFileSync(resolved, "utf-8").trim()
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      throw new Error(`ntfy: config {file:${filePath}} -- read failed at ${resolved}: ${msg}`)
    }
  })
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function substituteAll(value: unknown, configDir: string): unknown {
  if (typeof value === "string") return substituteString(value, configDir)
  if (Array.isArray(value)) return value.map((v) => substituteAll(v, configDir))
  if (isRecord(value)) {
    const out = Object.create(null) as Record<string, unknown>
    for (const k of Object.keys(value)) out[k] = substituteAll(value[k], configDir)
    return out
  }
  return value
}

// ---- Parsers ----

function isValidEvent(key: string): key is NotificationEvent {
  return NOTIFICATION_EVENTS.some((e) => e === key)
}

function assertKnownKeys(raw: Record<string, unknown>, allowed: readonly string[], where: string): void {
  for (const key of Object.keys(raw)) {
    if (!allowed.includes(key)) {
      throw new Error(`ntfy: unknown key ${where}.${key}`)
    }
  }
}

function parseContentTemplateMap(raw: Record<string, unknown>, fieldName: string): ContentTemplateMap {
  const result: ContentTemplateMap = {}
  for (const key of Object.keys(raw)) {
    if (!isValidEvent(key)) {
      throw new Error(`ntfy: invalid event '${key}' in backend.${fieldName}; valid: ${NOTIFICATION_EVENTS.join(", ")}`)
    }
    const entry = raw[key]
    if (!isRecord(entry)) throw new Error(`ntfy: backend.${fieldName}.${key} must be an object`)
    assertKnownKeys(entry, ["value", "command"], `backend.${fieldName}.${key}`)
    if (typeof entry.command === "string") {
      throw new Error(`ntfy: backend.${fieldName}.${key}: 'command' template is no longer supported. ` + `Use {value: "..."} with {env:VAR} / {file:path} substitution for dynamic content.`)
    }
    if (typeof entry.value !== "string") {
      throw new Error(`ntfy: backend.${fieldName}.${key} must contain a 'value' string`)
    }
    result[key] = { value: entry.value }
  }
  return result
}

function parseOptionalContentTemplateMap(raw: unknown, fieldName: string): ContentTemplateMap | undefined {
  if (raw === undefined) return undefined
  if (!isRecord(raw)) throw new Error(`ntfy: backend.${fieldName} must be an object`)
  return parseContentTemplateMap(raw, fieldName)
}

function parseEventConfig(key: NotificationEvent, raw: unknown, defaults: EventConfig): EventConfig {
  if (raw === undefined) return defaults
  if (!isRecord(raw)) throw new Error(`ntfy: events.${key} must be an object`)
  assertKnownKeys(raw, ["enabled", "notifyAfter"], `events.${key}`)
  const enabled = raw.enabled === undefined ? defaults.enabled : raw.enabled
  if (typeof enabled !== "boolean") throw new Error(`ntfy: events.${key}.enabled must be a boolean`)
  const notifyAfterMs = raw.notifyAfter === undefined ? defaults.notifyAfterMs : parseRequiredDurationMs(raw.notifyAfter, `events.${key}.notifyAfter`)
  return { enabled, notifyAfterMs }
}

function parseBackendConfig(raw: unknown): NtfyBackendConfig {
  if (!isRecord(raw)) throw new Error("ntfy: backend config must be an object")
  assertKnownKeys(raw, ["topic", "server", "token", "priority", "iconUrl", "fetchTimeout", "title", "message"], "backend")

  if (typeof raw.topic !== "string" || raw.topic.length === 0) {
    throw new Error("ntfy: backend.topic is required (non-empty string)")
  }
  const server = raw.server === undefined ? "https://ntfy.sh" : raw.server
  if (typeof server !== "string" || server.length === 0) throw new Error("ntfy: backend.server must be a non-empty string")
  const token = raw.token === undefined ? undefined : raw.token
  if (token !== undefined && (typeof token !== "string" || token.length === 0)) throw new Error("ntfy: backend.token must be a non-empty string")
  const priorityRaw = raw.priority === undefined ? "default" : raw.priority
  if (typeof priorityRaw !== "string") throw new Error("ntfy: backend.priority must be a string")
  if (!VALID_PRIORITIES.some((p) => p === priorityRaw)) {
    throw new Error(`ntfy: backend.priority must be one of ${VALID_PRIORITIES.join(", ")}`)
  }
  const priority = priorityRaw as NtfyPriority
  const iconUrl = raw.iconUrl === undefined ? undefined : raw.iconUrl
  if (iconUrl !== undefined && (typeof iconUrl !== "string" || iconUrl.length === 0)) throw new Error("ntfy: backend.iconUrl must be a non-empty string")
  const fetchTimeoutMs = raw.fetchTimeout === undefined ? DEFAULT_FETCH_TIMEOUT_MS : parseRequiredDurationMs(raw.fetchTimeout, "backend.fetchTimeout")
  const title = parseOptionalContentTemplateMap(raw.title, "title")
  const message = parseOptionalContentTemplateMap(raw.message, "message")

  return {
    topic: raw.topic,
    server: server.replace(/\/$/, ""),
    token,
    priority,
    iconUrl,
    fetchTimeoutMs,
    title,
    message,
  }
}

export function parsePluginConfig(content: string, configDir: string): NtfyPluginConfig {
  let parsed: unknown
  try {
    parsed = JSON.parse(content)
  } catch (err) {
    const msg = err instanceof Error ? err.message : "unknown parse error"
    throw new Error(`ntfy: invalid JSON in config: ${msg}`)
  }
  if (!isRecord(parsed)) throw new Error("ntfy: config must be a JSON object")

  const subbed = substituteAll(parsed, configDir)
  if (!isRecord(subbed)) throw new Error("ntfy: config must be a JSON object after substitution")
  assertKnownKeys(subbed, ["enabled", "events", "backend"], "config")

  const defEvents = defaultEvents()
  const enabled = subbed.enabled === undefined ? true : subbed.enabled
  if (typeof enabled !== "boolean") throw new Error("ntfy: enabled must be a boolean")
  const events: Record<NotificationEvent, EventConfig> = { ...defEvents }
  if (subbed.events !== undefined && !isRecord(subbed.events)) {
    throw new Error("ntfy: events must be an object")
  }
  if (isRecord(subbed.events)) {
    for (const key of Object.keys(subbed.events)) {
      if (!isValidEvent(key)) {
        throw new Error(`ntfy: invalid event '${key}' in events; valid: ${NOTIFICATION_EVENTS.join(", ")}`)
      }
    }
    for (const key of NOTIFICATION_EVENTS) {
      events[key] = parseEventConfig(key, subbed.events[key], defEvents[key])
    }
  }

  if (!enabled) {
    if (subbed.backend !== undefined) parseBackendConfig(subbed.backend)
    const backend: NtfyBackendConfig = {
      topic: "",
      server: "",
      priority: "default",
      fetchTimeoutMs: DEFAULT_FETCH_TIMEOUT_MS,
    }
    return { enabled, events, backend }
  }

  const backend = parseBackendConfig(subbed.backend)
  return { enabled, events, backend }
}

// ---- File loading ----

export function configPath(): string {
  const xdg = process.env.XDG_CONFIG_HOME
  const base = xdg && xdg.length > 0 ? xdg : join(homedir(), ".config")
  return join(base, "opencode", "notification-ntfy.json")
}

export function loadConfig(): NtfyPluginConfig {
  const p = configPath()
  let content: string
  try {
    content = readFileSync(p, "utf-8")
  } catch (err) {
    if (err instanceof Error && "code" in err && (err as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error(`ntfy: config not found at ${p}; create it with at minimum {"backend":{"topic":"..."}}`)
    }
    throw err
  }
  return parsePluginConfig(content, dirname(p))
}
