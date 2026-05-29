import assert from "node:assert/strict"
import { spawnSync, type SpawnSyncOptionsWithStringEncoding } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

type ExitRecord = {
  role: "user" | "assistant"
  order: "before" | "after"
  text: string
}

type ContractCase = {
  name: string
  notifyOnExit?: boolean
  spawnOutput: string
  exits: ExitRecord[]
  pending: string[]
}

type Message = {
  info: { role: "user" | "assistant" }
  parts: unknown[]
}

function env(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is required`)
  return value
}

function run(
  command: string,
  args: string[],
  options: Partial<SpawnSyncOptionsWithStringEncoding> = {},
): { stdout: string; stderr: string } {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    ...options,
  })
  if (result.error) throw result.error
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args.join(" ")} failed with ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    )
  }
  return { stdout: result.stdout ?? "", stderr: result.stderr ?? "" }
}

function sqlString(value: string): string {
  return `'${value.replaceAll("'", "''")}'`
}

function sqlJSON(value: unknown): string {
  return `json(${sqlString(JSON.stringify(value))})`
}

function safeName(name: string): string {
  return name.replace(/[^A-Za-z0-9_]/g, "_")
}

function textMessage(exit: ExitRecord): Message {
  return {
    info: { role: exit.role },
    parts: [{ type: "text", text: exit.text }],
  }
}

function messagesFor(tc: ContractCase): Message[] {
  const notifyOnExit = tc.notifyOnExit ?? true
  return [
    ...tc.exits.filter((exit) => exit.order === "before").map(textMessage),
    {
      info: { role: "assistant" },
      parts: [
        {
          type: "tool",
          tool: "pty_spawn",
          state: {
            status: "completed",
            input: { notifyOnExit },
            output: tc.spawnOutput,
          },
        },
      ],
    },
    ...tc.exits.filter((exit) => exit.order === "after").map(textMessage),
  ]
}

function insertExitSQL(id: string, sessionID: string, exit: ExitRecord, timeCreated: number): string {
  const messageID = `msg_${id}`
  const partID = `part_${id}`
  return [
    `INSERT INTO message (id, session_id, data) VALUES (${sqlString(messageID)}, ${sqlString(sessionID)}, ${sqlJSON({ role: exit.role, time: { created: timeCreated, completed: timeCreated } })});`,
    `INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (${sqlString(partID)}, ${sqlString(messageID)}, ${sqlString(sessionID)}, ${timeCreated}, ${sqlJSON({ type: "text", text: exit.text })});`,
  ].join("\n")
}

function caseSQL(tc: ContractCase, workspaceID: string): string {
  const id = safeName(tc.name)
  const sessionID = `ses_${id}`
  const spawnMessageID = `msg_${id}_spawn`
  const spawnPartID = `part_${id}_spawn`
  const notifyOnExit = tc.notifyOnExit ?? true
  const before = tc.exits
    .filter((exit) => exit.order === "before")
    .map((exit, index) => insertExitSQL(`${id}_before_${index}`, sessionID, exit, 500 + index))
  const after = tc.exits
    .filter((exit) => exit.order === "after")
    .map((exit, index) => insertExitSQL(`${id}_after_${index}`, sessionID, exit, 3000 + index))
  return [
    `INSERT INTO session (id, workspace_id) VALUES (${sqlString(sessionID)}, ${sqlString(workspaceID)});`,
    ...before,
    `INSERT INTO message (id, session_id, data) VALUES (${sqlString(spawnMessageID)}, ${sqlString(sessionID)}, ${sqlJSON({ role: "assistant", time: { created: 1000, completed: 2000 } })});`,
    `INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (${sqlString(spawnPartID)}, ${sqlString(spawnMessageID)}, ${sqlString(sessionID)}, 1000, ${sqlJSON({ type: "tool", tool: "pty_spawn", state: { status: "completed", input: { notifyOnExit }, output: tc.spawnOutput } })});`,
    ...after,
  ].join("\n")
}

function parseHealLog(stdout: string): { abandoned_pty: number } {
  const lines = stdout.trim().split(/\r?\n/).reverse()
  const line = lines.find((entry) => entry.startsWith("opencode-heal: {"))
  if (!line) throw new Error(`opencode-heal JSON log missing from:\n${stdout}`)
  return JSON.parse(line.replace(/^opencode-heal: /, ""))
}

const casesPath = env("PTY_LIFECYCLE_CASES")
const schemaPath = env("OPENCODE_SCHEMA")
const ntfySrc = env("NTFY_SRC")
const heal = env("OPENCODE_HEAL")
const tmp = mkdtempSync(join(tmpdir(), "kfactory-pty-contract-"))

try {
  const cases = JSON.parse(readFileSync(casesPath, "utf8")) as ContractCase[]
  const modulePath = pathToFileURL(join(ntfySrc, "src", "pty-lifecycle.ts")).href
  const { unfinishedNotifyOnExitPtys } = await import(modulePath) as {
    unfinishedNotifyOnExitPtys: (messages: unknown[]) => Set<string>
  }

  for (const tc of cases) {
    const expectedPending = [...tc.pending].sort()
    const actualPending = [...unfinishedNotifyOnExitPtys(messagesFor(tc))].sort()
    assert.deepEqual(actualPending, expectedPending, `${tc.name}: TypeScript parser pending IDs`)

    const db = join(tmp, `${safeName(tc.name)}.db`)
    const queue = join(tmp, `${safeName(tc.name)}.queue.json`)
    run("sqlite3", [db], { input: readFileSync(schemaPath, "utf8") })
    const workspaceID = `wrk_${safeName(tc.name)}`
    run("sqlite3", [db], { input: caseSQL(tc, workspaceID) })
    const result = run(heal, [db], {
      env: { ...process.env, KFACTORY_RECOVERY_QUEUE: queue },
    })
    const actualQueue = JSON.parse(readFileSync(queue, "utf8"))
    const expectedQueue = expectedPending.length > 0 ? [workspaceID] : []
    assert.deepEqual(actualQueue, expectedQueue, `${tc.name}: SQL heal queue`)
    const healLog = parseHealLog(result.stdout)
    assert.equal(healLog.abandoned_pty, expectedQueue.length, `${tc.name}: SQL heal abandoned count`)
    console.log(`ok ${tc.name}`)
  }
} finally {
  rmSync(tmp, { recursive: true, force: true })
}
