import { afterEach, test } from "bun:test"
import assert from "node:assert/strict"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import fc from "fast-check"
import { makeNtfyPlugin, unfinishedNotifyOnExitPtys } from "../src/index.js"
import type { NotificationContext } from "../src/backend.js"
import type { NotificationEvent, NtfyPluginConfig } from "../src/config.js"

const tmpdirs: string[] = []

afterEach(() => {
  for (const dir of tmpdirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

function makeGitWorkspace(): string {
  const dir = mkdtempSync(join(tmpdir(), "kfactory-ntfy-test-"))
  tmpdirs.push(dir)
  writeFileSync(join(dir, ".git"), "gitdir: /nonexistent\n")
  return dir
}

function config(notifyAfterMs: number): NtfyPluginConfig {
  return {
    enabled: true,
    events: {
      "session.idle": { enabled: true, notifyAfterMs },
      "session.error": { enabled: true, notifyAfterMs },
      "permission.asked": { enabled: true, notifyAfterMs },
    },
    backend: {
      topic: "test-topic",
      server: "http://127.0.0.1:9",
      priority: "default",
      fetchTimeoutMs: 100,
    },
  }
}

function configWithEvents(events: Partial<NtfyPluginConfig["events"]>): NtfyPluginConfig {
  const base = config(0)
  return {
    ...base,
    events: {
      ...base.events,
      ...events,
    },
  }
}

function tick(ms = 0): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

const ptyMessages = [
  {
    info: { role: "assistant" },
    parts: [
      {
        type: "tool",
        tool: "pty_spawn",
        state: {
          status: "completed",
          input: { notifyOnExit: true },
          output: "<pty_spawned>\nID: pty_1234abcd\nNotifyOnExit: true\n</pty_spawned>\n",
        },
      },
    ],
  },
]

const ptyExitMessage = {
  info: { role: "user" },
  parts: [
    {
      type: "text",
      text: [
        "<pty_exited>",
        "ID: pty_1234abcd",
        "Description: test",
        "Exit Code: 0",
        "TimeoutSeconds: none",
        "Timed Out: no",
        "Output Lines: 1",
        "Last Line: done",
        "</pty_exited>",
      ].join("\n"),
    },
  ],
}

const ptyInlineUserProse = {
  info: { role: "user" },
  parts: [
    {
      type: "text",
      text: "The operator mentioned <pty_exited> ID: pty_1234abcd </pty_exited> inline; this is prose, not a lifecycle block.",
    },
  ],
}

const ptyInvalidIDMessages = [
  {
    info: { role: "assistant" },
    parts: [
      {
        type: "tool",
        tool: "pty_spawn",
        state: {
          status: "completed",
          input: { notifyOnExit: true },
          output: "<pty_spawned>\nID: pty_nothexzz\nNotifyOnExit: true\n</pty_spawned>\n",
        },
      },
    ],
  },
]

async function makeHooks(
  notifyAfterMs: number,
  sends: NotificationContext[],
  overrides: {
    sessionGet?: (args: any) => Promise<any>
    sessionMessages?: (args: any) => Promise<any>
    vcsGet?: () => Promise<any>
  } = {},
) {
  const plugin = makeNtfyPlugin({
    loadConfig: () => config(notifyAfterMs),
    send: async (_backend, context) => {
      sends.push(context)
    },
  })

  return plugin({
    directory: makeGitWorkspace(),
    client: {
      session: {
        get: overrides.sessionGet ?? (async (args: any) => ({ data: { parentID: args.path.id === "ses_sub" ? "ses_root" : undefined } })),
        messages: overrides.sessionMessages ?? (async (args: any) => ({ data: args.path.id === "ses_pty" ? ptyMessages : [] })),
      },
      vcs: {
        get: overrides.vcsGet ?? (async () => ({ data: { branch: "main" } })),
      },
    },
  } as any)
}

function shouldSend(event: NotificationEvent, sessionID: string): boolean {
  return sessionID !== "" && sessionID !== "ses_sub" && !(event === "session.idle" && sessionID === "ses_pty")
}

async function publishNotification(hooks: Awaited<ReturnType<typeof makeHooks>>, event: NotificationEvent, sessionID: string): Promise<void> {
  const properties =
    event === "permission.asked"
      ? { sessionID, permission: "edit", patterns: ["*"] }
      : event === "session.error"
        ? { sessionID, error: { data: { message: "boom" } } }
        : { sessionID }
  await hooks.event!({
    event: {
      type: event === "session.idle" ? "session.status" : event,
      properties: event === "session.idle" ? { sessionID, status: { type: "idle" } } : properties,
    },
  } as any)
}

test("idle storms coalesce to one send per session and event", async () => {
  const sends: NotificationContext[] = []
  const hooks = await makeHooks(10, sends)

  for (let i = 0; i < 20; i++) {
    await publishNotification(hooks, "session.idle", "ses_root")
  }
  await tick(30)

  assert.equal(sends.length, 1)
  assert.equal(sends[0]?.event, "session.idle")
})

test("dispose clears pending delayed notifications", async () => {
  const sends: NotificationContext[] = []
  const hooks = await makeHooks(20, sends)

  await publishNotification(hooks, "session.idle", "ses_root")
  await hooks.dispose?.()
  await tick(40)

  assert.equal(sends.length, 0)
})

test("dispose prevents in-flight async event handling from sending", async () => {
  const sends: NotificationContext[] = []
  let releaseLookup!: () => void
  const blocked = new Promise<void>((resolve) => {
    releaseLookup = resolve
  })
  const hooks = await makeHooks(0, sends, {
    sessionGet: async () => {
      await blocked
      return { data: { parentID: undefined } }
    },
  })

  const eventPromise = publishNotification(hooks, "session.idle", "ses_root")
  await tick()
  await hooks.dispose?.()
  releaseLookup()
  await eventPromise
  await tick()

  assert.equal(sends.length, 0)
})

test("MessageAbortedError session.error is routed as session.idle", async () => {
  const sends: NotificationContext[] = []
  const plugin = makeNtfyPlugin({
    loadConfig: () =>
      configWithEvents({
        "session.idle": { enabled: true, notifyAfterMs: 0 },
        "session.error": { enabled: false, notifyAfterMs: 0 },
      }),
    send: async (_backend, context) => {
      sends.push(context)
    },
  })

  const hooks = await plugin({
    directory: makeGitWorkspace(),
    client: {
      session: {
        get: async () => ({ data: { parentID: undefined } }),
        messages: async () => ({ data: [] }),
      },
      vcs: {
        get: async () => ({ data: { branch: "main" } }),
      },
    },
  } as any)

  await hooks.event!({
    event: {
      type: "session.error",
      properties: {
        sessionID: "ses_root",
        error: { name: "MessageAbortedError", data: { message: "Aborted" } },
      },
    },
  } as any)
  await tick()

  assert.equal(sends.length, 1)
  assert.equal(sends[0]?.event, "session.idle")
  assert.equal(sends[0]?.metadata.sessionId, "ses_root")
  assert.equal(sends[0]?.metadata.error, undefined)
})

test("branch label comes from upstream VCS API and branch update events", async () => {
  const sends: NotificationContext[] = []
  let currentBranch = "main"
  const plugin = makeNtfyPlugin({
    loadConfig: () => config(0),
    send: async (_backend, context) => {
      sends.push(context)
    },
  })

  const hooks = await plugin({
    directory: makeGitWorkspace(),
    client: {
      session: {
        get: async () => ({ data: { parentID: undefined } }),
        messages: async () => ({ data: [] }),
      },
      vcs: {
        get: async () => ({ data: { branch: currentBranch } }),
      },
    },
  } as any)

  await publishNotification(hooks, "session.idle", "ses_root")
  await tick()
  await hooks.event!({ event: { type: "vcs.branch.updated", properties: { branch: "feature/a" } } } as any)
  currentBranch = "ignored"
  await publishNotification(hooks, "session.error", "ses_root")
  await tick()

  assert.equal(sends[0]?.metadata.branch, "main")
  assert.equal(sends[1]?.metadata.branch, "feature/a")
})

test("malformed permission.asked fails closed", async () => {
  const sends: NotificationContext[] = []
  const hooks = await makeHooks(0, sends)

  await hooks.event!({ event: { type: "permission.asked", properties: { sessionID: "ses_root", permission: "edit", patterns: ["*", 1] } } } as any)
  await tick()

  assert.equal(sends.length, 0)
})

test("malformed session.status and session.error fail closed", async () => {
  const sends: NotificationContext[] = []
  const hooks = await makeHooks(0, sends)

  await hooks.event!({ event: { type: "session.status", properties: { sessionID: "", status: { type: "idle" } } } } as any)
  await hooks.event!({ event: { type: "session.status", properties: { sessionID: "ses_root", status: "idle" } } } as any)
  await hooks.event!({ event: { type: "session.error", properties: { error: { data: { message: "boom" } } } } } as any)
  await hooks.event!({ event: { type: "session.error", properties: { sessionID: "", error: { data: { message: "boom" } } } } } as any)
  await tick()

  assert.equal(sends.length, 0)
})

test("malformed VCS branch updates do not poison branch cache", async () => {
  const sends: NotificationContext[] = []
  let currentBranch = "main"
  const hooks = await makeHooks(0, sends, { vcsGet: async () => ({ data: { branch: currentBranch } }) })

  await publishNotification(hooks, "session.idle", "ses_root")
  await hooks.event!({ event: { type: "vcs.branch.updated", properties: { branch: 123 } } } as any)
  currentBranch = "ignored"
  await publishNotification(hooks, "session.error", "ses_root")
  await tick()

  assert.equal(sends[0]?.metadata.branch, "main")
  assert.equal(sends[1]?.metadata.branch, "main")
})

test("unknown PTY state suppresses idle and warns", async () => {
  const sends: NotificationContext[] = []
  const warnings: string[] = []
  const originalWarn = console.warn
  console.warn = (...args: unknown[]) => {
    warnings.push(args.map(String).join(" "))
  }
  try {
    const hooks = await makeHooks(0, sends, {
      sessionMessages: async () => {
        throw new Error("message lookup failed")
      },
    })

    await publishNotification(hooks, "session.idle", "ses_root")
    await tick()
  } finally {
    console.warn = originalWarn
  }

  assert.equal(sends.length, 0)
  assert.ok(warnings.some((line) => line.includes("PTY state unknown") || line.includes("pty state unknown")))
})

test("MessageAbortedError coalesces with pending idle timer", async () => {
  const sends: NotificationContext[] = []
  const hooks = await makeHooks(10, sends)

  await publishNotification(hooks, "session.idle", "ses_root")
  await hooks.event!({
    event: {
      type: "session.error",
      properties: {
        sessionID: "ses_root",
        error: { name: "MessageAbortedError", data: { message: "Aborted" } },
      },
    },
  } as any)
  await tick(30)

  assert.equal(sends.length, 1)
  assert.equal(sends[0]?.event, "session.idle")
})

test("pending PTY parser requires a structured pty_exited block", () => {
  assert.deepEqual([...unfinishedNotifyOnExitPtys(ptyMessages)], ["pty_1234abcd"])
  assert.deepEqual(unfinishedNotifyOnExitPtys([...ptyMessages, ptyExitMessage]).size, 0)
  assert.deepEqual([...unfinishedNotifyOnExitPtys([...ptyMessages, ptyInlineUserProse])], ["pty_1234abcd"])
  assert.deepEqual(unfinishedNotifyOnExitPtys(ptyInvalidIDMessages).size, 0)
  assert.deepEqual(
    [...unfinishedNotifyOnExitPtys([...ptyMessages, { info: { role: "user" }, parts: [{ type: "text", text: "Waiting for the `<pty_exited>` signal for pty_1234abcd" }] }])],
    ["pty_1234abcd"],
  )
})

test("property: zero-delay notifications honor empty-session, subagent, and PTY gates", async () => {
  const opArb = fc.record({
    event: fc.constantFrom<NotificationEvent>("session.idle", "session.error", "permission.asked"),
    sessionID: fc.constantFrom("", "ses_root", "ses_sub", "ses_pty"),
  })

  await fc.assert(
    fc.asyncProperty(fc.array(opArb, { minLength: 1, maxLength: 40 }), async (ops) => {
      const sends: NotificationContext[] = []
      const hooks = await makeHooks(0, sends)
      let expected = 0

      for (const op of ops) {
        if (shouldSend(op.event, op.sessionID)) expected++
        await publishNotification(hooks, op.event, op.sessionID)
        await tick()
      }

      assert.equal(sends.length, expected)
    }),
    { numRuns: 75 },
  )
})

test("property: delayed notification timers coalesce by session and event", async () => {
  const opArb = fc.record({
    event: fc.constantFrom<NotificationEvent>("session.idle", "session.error", "permission.asked"),
    sessionID: fc.constantFrom("ses_a", "ses_b", "ses_c"),
  })

  await fc.assert(
    fc.asyncProperty(fc.array(opArb, { minLength: 1, maxLength: 30 }), async (ops) => {
      const sends: NotificationContext[] = []
      const hooks = await makeHooks(5, sends)
      const pending = new Set<string>()

      for (const op of ops) {
        pending.add(`${op.sessionID}|${op.event}`)
        await publishNotification(hooks, op.event, op.sessionID)
      }
      await tick(20)

      assert.equal(sends.length, pending.size)
      assert.deepEqual(
        new Set(sends.map((send) => `${send.metadata.sessionId}|${send.event}`)),
        pending,
      )
    }),
    { numRuns: 75 },
  )
})
