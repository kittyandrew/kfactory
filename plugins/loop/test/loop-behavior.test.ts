import { afterEach, test } from "bun:test"
import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { tmpdir } from "node:os"
import LoopPlugin from "../src/index.js"

const tmpdirs: string[] = []

afterEach(() => {
  for (const dir of tmpdirs.splice(0)) rmSync(dir, { recursive: true, force: true })
  delete process.env.XDG_STATE_HOME
})

function makeWorkspace(): string {
  const dir = mkdtempSync(join(tmpdir(), "kfactory-loop-test-workspace-"))
  const state = mkdtempSync(join(tmpdir(), "kfactory-loop-test-state-"))
  tmpdirs.push(dir, state)
  process.env.XDG_STATE_HOME = state
  return dir
}

function stateFile(directory: string): string {
  const key = createHash("sha256").update(directory).digest("hex").slice(0, 16)
  return join(process.env.XDG_STATE_HOME!, "kfactory-loop", `${key}.json`)
}

function writeLoopState(directory: string, state: Record<string, unknown>): void {
  const path = stateFile(directory)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, JSON.stringify(state, null, 2))
}

function activeLoopState(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    schemaVersion: 2,
    runID: "run-test",
    iteration: 0,
    maxIterations: 10,
    sentinel: "DONE",
    sessionID: "ses_a",
    task: "keep working",
    consecutiveFailures: 0,
    ...overrides,
  }
}

function assistant(text: string) {
  return {
    info: { role: "assistant" },
    parts: [{ type: "text", text }],
  }
}

async function makeHooks(input?: {
  directory?: string
  parentID?: string
  getError?: unknown
  status?: Record<string, unknown>
  messages?: unknown[] | (() => Promise<unknown[]>)
  prompt?: (text: string) => Promise<void>
}) {
  const prompts: string[] = []
  const directory = input?.directory ?? makeWorkspace()
  const hooks = await LoopPlugin({
    directory,
    client: {
      session: {
        get: async () => {
          if (input?.getError) throw input.getError
          return { data: { parentID: input?.parentID } }
        },
        messages: async () => ({ data: typeof input?.messages === "function" ? await input.messages() : (input?.messages ?? []) }),
        status: async () => ({ data: input?.status ?? {} }),
        prompt: async (args: any) => {
          const text = args.body.parts[0].text
          prompts.push(text)
          await input?.prompt?.(text)
          return { data: {} }
        },
      },
    },
  } as any)
  return { hooks, prompts, directory }
}

async function startLoop(hooks: any, sessionID = "ses_a", maxIterations = 10, sentinel = "DONE") {
  const tool = hooks.tool["loop-start"]
  return tool.execute({ task: "keep working", sentinel, maxIterations }, { sessionID })
}

async function stopLoop(hooks: any) {
  return hooks.tool["loop-stop"].execute({}, {})
}

async function idle(hooks: any, sessionID = "ses_a") {
  await hooks.event({ event: { type: "session.status", properties: { sessionID, status: { type: "idle" } } } })
}

function tick(ms = 0): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

test("sentinel on final non-empty assistant line clears state without prompting", async () => {
  const { hooks, prompts } = await makeHooks({ messages: [assistant("work done\nDONE")] })

  await startLoop(hooks)
  await idle(hooks)

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("maxIterations cap clears after one injected continuation", async () => {
  const { hooks, prompts } = await makeHooks({ messages: [assistant("not done")] })

  await startLoop(hooks, "ses_a", 1, "DONE")
  await idle(hooks)
  await idle(hooks)

  assert.equal(prompts.length, 1)
  assert.match(prompts[0]!, /^\[loop iteration 1\/1\]/)
  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("manual loop-stop prevents later idle continuation", async () => {
  const { hooks, prompts } = await makeHooks({ messages: [assistant("not done")] })

  await startLoop(hooks)
  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 0 iteration(s).")
  await idle(hooks)

  assert.equal(prompts.length, 0)
})

test("idle for another session is ignored", async () => {
  const { hooks, prompts } = await makeHooks({ messages: [assistant("not done")] })

  await startLoop(hooks, "ses_a")
  await idle(hooks, "ses_b")

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 0 iteration(s).")
})

test("session.deleted for the target session clears state", async () => {
  const { hooks } = await makeHooks({ messages: [assistant("not done")] })

  await startLoop(hooks, "ses_a")
  await hooks.event({ event: { type: "session.deleted", properties: { sessionID: "ses_a" } } })

  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("concurrent idle handlers advance labels instead of duplicating an iteration", async () => {
  let unblockFirstPrompt!: () => void
  const firstPromptBlocked = new Promise<void>((resolve) => {
    unblockFirstPrompt = resolve
  })
  const { hooks, prompts } = await makeHooks({
    messages: [assistant("not done")],
    async prompt() {
      if (prompts.length === 1) {
        await firstPromptBlocked
      }
    },
  })

  await startLoop(hooks, "ses_a", 10, "DONE")
  const firstIdle = hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_a", status: { type: "idle" } } } })
  while (prompts.length === 0) await new Promise((resolve) => setTimeout(resolve, 0))
  const secondIdle = hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_a", status: { type: "idle" } } } })
  unblockFirstPrompt()
  await Promise.all([firstIdle, secondIdle])

  assert.equal(prompts.length, 2)
  assert.match(prompts[0]!, /^\[loop iteration 1\/10\]/)
  assert.match(prompts[1]!, /^\[loop iteration 2\/10\]/)
})

test("stale same-session handler cannot overwrite a restarted loop", async () => {
  let releaseMessages!: () => void
  const messagesBlocked = new Promise<void>((resolve) => {
    releaseMessages = resolve
  })
  const { hooks, prompts } = await makeHooks({
    messages: async () => {
      await messagesBlocked
      return [assistant("not done")]
    },
  })

  await startLoop(hooks, "ses_a", 10, "DONE-A")
  const firstIdle = hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_a", status: { type: "idle" } } } })
  await tick()
  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 0 iteration(s).")
  await startLoop(hooks, "ses_a", 10, "DONE-B")
  releaseMessages()
  await firstIdle

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 0 iteration(s).")
})

test("loop-start refuses child sessions before writing state", async () => {
  const { hooks, prompts } = await makeHooks({ parentID: "ses_parent", messages: [assistant("not done")] })

  const result = await startLoop(hooks, "ses_child")

  assert.match(result, /refused -- session ses_child is a child\/subagent session/)
  await idle(hooks, "ses_child")

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("loop-start refuses session lookup failures before writing state", async () => {
  const { hooks, prompts } = await makeHooks({ getError: new Error("network down"), messages: [assistant("not done")] })

  const result = await startLoop(hooks, "ses_a")

  assert.match(result, /refused -- could not verify session ses_a is a root operator session/)
  await idle(hooks, "ses_a")

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("loop-start refuses missing sessions before writing state", async () => {
  const notFound = Object.assign(new Error("session not found"), { status: 404 })
  const { hooks, prompts } = await makeHooks({ getError: notFound, messages: [assistant("not done")] })

  const result = await startLoop(hooks, "ses_missing")

  assert.match(result, /refused -- session ses_missing does not exist/)
  await idle(hooks, "ses_missing")

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("loop-start rejects whitespace-wrapped and multi-line sentinels", async () => {
  const { hooks } = await makeHooks({ messages: [assistant("not done")] })

  assert.match(await startLoop(hooks, "ses_a", 10, " DONE"), /refusing invalid sentinel/)
  assert.match(await startLoop(hooks, "ses_a", 10, "DONE\nNEXT"), /refusing invalid sentinel/)

  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("subagent idles are suppressed for pre-existing state", async () => {
  const directory = makeWorkspace()
  writeLoopState(directory, activeLoopState({ sessionID: "ses_child" }))
  const { hooks, prompts } = await makeHooks({ directory, parentID: "ses_parent", messages: [assistant("not done")] })

  await idle(hooks, "ses_child")

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 0 iteration(s).")
})

test("deprecated session.idle events are ignored", async () => {
  const { hooks, prompts } = await makeHooks({ messages: [assistant("not done")] })

  await startLoop(hooks)
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_a" } } })

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 0 iteration(s).")
})

test("invalid durable state is cleared instead of defaulted", async () => {
  const directory = makeWorkspace()
  writeLoopState(directory, activeLoopState({ iteration: "0" }))
  const { hooks } = await makeHooks({ directory, messages: [assistant("not done")] })

  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("persisted impossible sentinels are cleared instead of tolerated", async () => {
  const directory = makeWorkspace()
  writeLoopState(directory, activeLoopState({ sentinel: "DONE\nNEXT" }))
  const { hooks } = await makeHooks({ directory, messages: [assistant("not done")] })

  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("plugin init checks current session status and continues idle active state", async () => {
  const directory = makeWorkspace()
  writeLoopState(directory, activeLoopState())
  const { prompts } = await makeHooks({ directory, messages: [assistant("not done")], status: {} })

  for (let i = 0; i < 20 && prompts.length === 0; i++) await tick()

  assert.equal(prompts.length, 1)
  assert.match(prompts[0]!, /^\[loop iteration 1\/10\]/)
})

test("plugin init clears durable state for a deleted session", async () => {
  const directory = makeWorkspace()
  const notFound = Object.assign(new Error("session not found"), { status: 404 })
  writeLoopState(directory, activeLoopState({ sessionID: "ses_deleted" }))
  const { hooks, prompts } = await makeHooks({ directory, getError: notFound, messages: [assistant("not done")], status: {} })

  await tick()

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("plugin init fails closed when root lookup fails", async () => {
  const directory = makeWorkspace()
  writeLoopState(directory, activeLoopState())
  const { hooks, prompts } = await makeHooks({ directory, getError: new Error("lookup failed"), messages: [assistant("not done")], status: {} })

  await tick()

  assert.equal(prompts.length, 0)
  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 0 iteration(s).")
})

test("stale messages failure cannot resurrect stopped loop state", async () => {
  let releaseMessages!: () => void
  const messagesBlocked = new Promise<void>((resolve) => {
    releaseMessages = resolve
  })
  const { hooks } = await makeHooks({
    messages: async () => {
      await messagesBlocked
      throw new Error("messages failed")
    },
  })

  await startLoop(hooks, "ses_a", 10, "DONE")
  const idleEvent = hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_a", status: { type: "idle" } } } })
  await tick()
  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 0 iteration(s).")
  releaseMessages()
  await idleEvent

  assert.equal(await stopLoop(hooks), "loop-stop: no active loop.")
})

test("stale prompt failure cannot overwrite restarted loop state", async () => {
  let releasePrompt!: () => void
  const promptBlocked = new Promise<void>((resolve) => {
    releasePrompt = resolve
  })
  const { hooks, prompts } = await makeHooks({
    messages: [assistant("not done")],
    async prompt() {
      await promptBlocked
      throw new Error("prompt failed")
    },
  })

  await startLoop(hooks, "ses_a", 10, "DONE-A")
  const idleEvent = hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_a", status: { type: "idle" } } } })
  while (prompts.length === 0) await tick()
  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 1 iteration(s).")
  await startLoop(hooks, "ses_a", 10, "DONE-B")
  releasePrompt()
  await idleEvent

  assert.equal(await stopLoop(hooks), "loop-stop: cancelled after 0 iteration(s).")
})
