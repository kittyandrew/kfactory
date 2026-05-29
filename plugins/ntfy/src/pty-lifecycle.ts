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
// kfactory modifications (AGPLv3, see top-level LICENSE):
//   - Centralizes opencode-pty transcript lifecycle parsing shared by
//     notification and recovery code.

export const PTY_ID_PATTERN = /^pty_[a-f0-9]{8}$/

type LifecycleTag = "pty_spawned" | "pty_exited"

// Temporary opencode-pty bridge: lifecycle is only visible as exact
// newline-delimited transcript blocks (`<pty_spawned>` / `<pty_exited>`).
// Parse records, not prose; system reminders can mention the tags.
function parseRecordBlock(text: string, tag: LifecycleTag): Map<string, string>[] {
  const out: Map<string, string>[] = []
  let current: Map<string, string> | undefined
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (line === `<${tag}>`) {
      current = new Map()
      continue
    }
    if (line === `</${tag}>`) {
      if (current) out.push(current)
      current = undefined
      continue
    }
    if (!current) continue
    const match = line.match(/^([^:]+):\s*(.*)$/)
    if (match) current.set(match[1]!, match[2]!)
  }
  return out
}

export function parsePtySpawnedID(output: string): string | undefined {
  for (const block of parseRecordBlock(output, "pty_spawned")) {
    const id = block.get("ID")
    if (id && PTY_ID_PATTERN.test(id)) return id
  }
  return undefined
}

export function parsePtyExitedIDs(text: string): string[] {
  const ids: string[] = []
  for (const block of parseRecordBlock(text, "pty_exited")) {
    const id = block.get("ID")
    if (id && PTY_ID_PATTERN.test(id)) ids.push(id)
  }
  return ids
}

export function unfinishedNotifyOnExitPtys(messages: unknown[]): Set<string> {
  const pending = new Set<string>()
  for (const msg of messages) {
    if (!isRecord(msg)) continue
    const info = isRecord(msg.info) ? msg.info : undefined
    const role = info?.role
    const parts = Array.isArray(msg.parts) ? msg.parts : []
    if (role === "assistant") {
      for (const part of parts) {
        if (!isRecord(part) || part.type !== "tool" || part.tool !== "pty_spawn") continue
        const state = isRecord(part.state) ? part.state : undefined
        const input = isRecord(state?.input) ? state.input : undefined
        if (state?.status !== "completed" || input?.notifyOnExit !== true) continue
        if (typeof state.output !== "string") continue
        const id = parsePtySpawnedID(state.output)
        if (id) pending.add(id)
      }
    } else if (role === "user" && pending.size > 0) {
      const text = parts
        .filter((p): p is { type: "text"; text: string } => isRecord(p) && p.type === "text" && typeof p.text === "string")
        .map((p) => p.text)
        .join("")
      for (const id of parsePtyExitedIDs(text)) pending.delete(id)
    }
  }
  return pending
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v)
}
