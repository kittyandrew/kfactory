import { afterEach, describe, expect } from "bun:test"
import { $ } from "bun"
import * as Http from "node:http"
import * as fs from "node:fs/promises"
import path from "node:path"
import { FSUtil } from "@opencode-ai/core/fs-util"
import { CrossSpawnSpawner } from "@opencode-ai/core/cross-spawn-spawner"
import { Effect, Layer } from "effect"
import { FetchHttpClient } from "effect/unstable/http"
import { EffectFlock } from "@opencode-ai/core/util/effect-flock"
import { EventV2Bridge } from "../../src/event-v2-bridge"
import { SessionStatus } from "../../src/session/status"
import { Permission } from "../../src/permission"
import { PermissionV1 } from "@opencode-ai/core/v1/permission"
import { SessionID } from "../../src/session/schema"
import { Config } from "../../src/config/config"
import { Env } from "../../src/env"
import { RuntimeFlags } from "../../src/effect/runtime-flags"
import { Plugin } from "../../src/plugin/index"
import { Server } from "../../src/server/server"
import { disposeAllInstances, provideTmpdirInstance } from "../fixture/fixture"
import { testEffectShared } from "../lib/effect"
import { AccountTest } from "../fake/account"
import { AuthTest } from "../fake/auth"
import { NpmTest } from "../fake/npm"

const configLayer = Config.layer.pipe(Layer.provide(EffectFlock.defaultLayer), Layer.provide(FSUtil.defaultLayer), Layer.provide(Env.defaultLayer), Layer.provide(AuthTest.empty), Layer.provide(AccountTest.empty), Layer.provide(NpmTest.noop), Layer.provide(FetchHttpClient.layer))

const it = testEffectShared(
  Layer.mergeAll(
    Plugin.layer.pipe(
      Layer.provideMerge(EventV2Bridge.defaultLayer),
      Layer.provideMerge(configLayer),
      Layer.provideMerge(RuntimeFlags.layer({ disableDefaultPlugins: true })),
    ),
    CrossSpawnSpawner.defaultLayer,
  ),
)

type Collector = {
  url: string
  messages: Array<{ headers: Http.IncomingHttpHeaders; body: string }>
  waitForCount(count: number, timeoutMs: number): Promise<void>
  close(): Promise<void>
}

async function makeCollector(): Promise<Collector> {
  const messages: Collector["messages"] = []
  const waiters: Array<() => void> = []
  const server = Http.createServer((req, res) => {
    const chunks: Buffer[] = []
    req.on("data", (chunk) => chunks.push(Buffer.from(chunk)))
    req.on("end", () => {
      messages.push({ headers: req.headers, body: Buffer.concat(chunks).toString("utf8") })
      for (const waiter of waiters.splice(0)) waiter()
      res.writeHead(200, { "content-type": "text/plain" })
      res.end("ok")
    })
  })

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => resolve())
  })
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("collector did not bind a TCP port")

  return {
    url: `http://127.0.0.1:${address.port}`,
    messages,
    waitForCount(count, timeoutMs) {
      if (messages.length >= count) return Promise.resolve()
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          const idx = waiters.indexOf(done)
          if (idx >= 0) waiters.splice(idx, 1)
          reject(new Error(`timed out waiting for ${count} ntfy POST(s); saw ${messages.length}`))
        }, timeoutMs)
        const done = () => {
          if (messages.length < count) return
          clearTimeout(timer)
          resolve()
        }
        waiters.push(done)
      })
    },
    close() {
      return new Promise((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()))
      })
    },
  }
}

async function createSession(directory: string): Promise<string> {
  const response = await Server.Default().app.request("/session", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-opencode-directory": directory,
    },
    body: JSON.stringify({ title: "ntfy integration" }),
  })
  expect(response.status).toBe(200)
  const body = (await response.json()) as { id?: string }
  if (!body.id) throw new Error("session.create response did not include id")
  return body.id
}

async function openEventStream(directory: string): Promise<ReadableStreamDefaultReader<Uint8Array>> {
  const response = await Server.Default().app.request("/event", {
    headers: { "x-opencode-directory": directory },
  })
  expect(response.status).toBe(200)
  if (!response.body) throw new Error("missing event stream body")
  const reader = response.body.getReader()
  const first = await Promise.race([reader.read(), new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timed out waiting for SSE connect")), 1000))])
  const text = new TextDecoder().decode(first.value)
  expect(text).toContain("server.connected")
  return reader
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function withNtfyProject<A, E, R>(collector: Collector, self: (directory: string) => Effect.Effect<A, E, R>) {
  const pluginPath = process.env.KFACTORY_NTFY_PLUGIN_PATH
  if (!pluginPath) throw new Error("KFACTORY_NTFY_PLUGIN_PATH is required")

  return provideTmpdirInstance(
    (directory) =>
      Effect.gen(function* () {
        const xdg = path.join(directory, ".test-xdg")
        const previousXdg = process.env.XDG_CONFIG_HOME
        process.env.XDG_CONFIG_HOME = xdg
        yield* Effect.addFinalizer(() =>
          Effect.sync(() => {
            if (previousXdg === undefined) delete process.env.XDG_CONFIG_HOME
            else process.env.XDG_CONFIG_HOME = previousXdg
          }),
        )

        yield* Effect.promise(() => fs.mkdir(path.join(xdg, "opencode"), { recursive: true }))
        yield* Effect.promise(() =>
          fs.writeFile(
            path.join(xdg, "opencode", "notification-ntfy.json"),
            JSON.stringify({
              enabled: true,
              backend: {
                server: collector.url,
                topic: "test-topic",
                fetchTimeout: "1s",
              },
              events: {
                "session.idle": { enabled: true, notifyAfter: "0.05s" },
                "session.error": { enabled: true, notifyAfter: "0.05s" },
                "permission.asked": { enabled: true, notifyAfter: "0.05s" },
              },
            }),
          ),
        )
        yield* Effect.promise(() =>
          fs.writeFile(
            path.join(directory, "opencode.json"),
            JSON.stringify({
              $schema: "https://opencode.ai/config.json",
              formatter: false,
              lsp: false,
              plugin: [pluginPath],
            }),
          ),
        )

        yield* Plugin.Service.use((plugin) => plugin.init())
        return yield* self(directory)
      }),
    { git: true },
  )
}

afterEach(async () => {
  await disposeAllInstances()
})

describe("kfactory ntfy plugin inside opencode", () => {
  it.live("sends idle while one or more real /event subscribers are attached", () =>
    Effect.acquireRelease(Effect.promise(makeCollector), (collector) => Effect.promise(() => collector.close())).pipe(
      Effect.flatMap((collector) =>
        withNtfyProject(collector, (directory) =>
          Effect.gen(function* () {
            yield* Effect.promise(() => $`git commit --allow-empty -m test`.cwd(directory).quiet().nothrow())
            const sessionID = yield* Effect.promise(() => createSession(directory))

            yield* EventV2Bridge.Service.use((events) =>
              events.publish(SessionStatus.Event.Status, { sessionID: SessionID.make(sessionID), status: { type: "idle" } }),
            )
            yield* Effect.promise(() => collector.waitForCount(1, 1000))
            expect(collector.messages[0].headers.title).toBe("Agent Idle")
            expect(collector.messages[0].body).toContain(path.basename(directory))

            yield* Effect.acquireRelease(
              Effect.promise(() => openEventStream(directory)),
              (reader) => Effect.promise(() => reader.cancel().catch(() => undefined)),
            )

            yield* EventV2Bridge.Service.use((events) =>
              events.publish(SessionStatus.Event.Status, { sessionID: SessionID.make(sessionID), status: { type: "idle" } }),
            )
            yield* Effect.promise(() => collector.waitForCount(2, 1000))

            yield* Effect.acquireRelease(
              Effect.promise(() => openEventStream(directory)),
              (reader) => Effect.promise(() => reader.cancel().catch(() => undefined)),
            )

            yield* EventV2Bridge.Service.use((events) =>
              events.publish(SessionStatus.Event.Status, { sessionID: SessionID.make(sessionID), status: { type: "idle" } }),
            )
            yield* Effect.promise(() => collector.waitForCount(3, 1000))
          }),
        ),
      ),
    ),
  )

  it.live("does not cancel pending idle when a real /event subscriber attaches during notifyAfter", () =>
    Effect.acquireRelease(Effect.promise(makeCollector), (collector) => Effect.promise(() => collector.close())).pipe(
      Effect.flatMap((collector) =>
        withNtfyProject(collector, (directory) =>
          Effect.gen(function* () {
            yield* Effect.promise(() => $`git commit --allow-empty -m test`.cwd(directory).quiet().nothrow())
            const sessionID = yield* Effect.promise(() => createSession(directory))

            yield* EventV2Bridge.Service.use((events) =>
              events.publish(SessionStatus.Event.Status, { sessionID: SessionID.make(sessionID), status: { type: "idle" } }),
            )
            yield* Effect.acquireRelease(
              Effect.promise(() => openEventStream(directory)),
              (reader) => Effect.promise(() => reader.cancel().catch(() => undefined)),
            ).pipe(Effect.flatMap(() => Effect.promise(() => sleep(150))))
            expect(collector.messages).toHaveLength(1)
          }),
        ),
      ),
    ),
  )
  it.live("sends permission.asked with the permission type in the body", () =>
    Effect.acquireRelease(Effect.promise(makeCollector), (collector) => Effect.promise(() => collector.close())).pipe(
      Effect.flatMap((collector) =>
        withNtfyProject(collector, (directory) =>
          Effect.gen(function* () {
            yield* Effect.promise(() => $`git commit --allow-empty -m test`.cwd(directory).quiet().nothrow())
            const sessionID = yield* Effect.promise(() => createSession(directory))

            yield* EventV2Bridge.Service.use((events) =>
              events.publish(Permission.Event.Asked, {
                id: PermissionV1.ID.ascending(),
                sessionID: SessionID.make(sessionID),
                permission: "webfetch",
                patterns: ["https://example.com"],
                metadata: {},
                always: [],
              }),
            )
            yield* Effect.promise(() => collector.waitForCount(1, 1000))
            expect(collector.messages[0].headers.title).toBe("Permission Asked")
            expect(collector.messages[0].body).toContain("webfetch")
          }),
        ),
      ),
    ),
  )

})
