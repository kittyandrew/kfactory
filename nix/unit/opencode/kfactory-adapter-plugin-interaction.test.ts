import { $ } from "bun"
import { afterEach, describe, expect } from "bun:test"
import { NodeServices } from "@effect/platform-node"
import { AppFileSystem } from "@opencode-ai/core/filesystem"
import { CrossSpawnSpawner } from "@opencode-ai/core/cross-spawn-spawner"
import { Effect, Layer } from "effect"
import { FetchHttpClient } from "effect/unstable/http"
import { EffectFlock } from "@opencode-ai/core/util/effect-flock"
import * as Log from "@opencode-ai/core/util/log"
import fs from "node:fs/promises"
import path from "node:path"
import { Auth } from "../../src/auth"
import { Bus } from "../../src/bus"
import { Config } from "../../src/config/config"
import { getAdapter } from "../../src/control-plane/adapters"
import { Workspace } from "../../src/control-plane/workspace"
import { Env } from "../../src/env"
import { RuntimeFlags } from "../../src/effect/runtime-flags"
import { Plugin } from "../../src/plugin/index"
import { InstanceBootstrap } from "../../src/project/bootstrap"
import { InstanceStore } from "../../src/project/instance-store"
import { Project } from "../../src/project/project"
import { Vcs } from "../../src/project/vcs"
import { Server } from "../../src/server/server"
import { SessionPrompt } from "../../src/session/prompt"
import { Session } from "../../src/session/session"
import { Database } from "../../src/storage/db"
import { SyncEvent } from "../../src/sync"
import { AccountTest } from "../fake/account"
import { AuthTest } from "../fake/auth"
import { NpmTest } from "../fake/npm"
import { disposeAllInstances, provideTmpdirInstance, requireInstance } from "../fixture/fixture"
import { testEffect } from "../lib/effect"

void Log.init({ print: false })

const configLayer = Config.layer.pipe(
  Layer.provide(EffectFlock.defaultLayer),
  Layer.provide(AppFileSystem.defaultLayer),
  Layer.provide(Env.defaultLayer),
  Layer.provide(AuthTest.empty),
  Layer.provide(AccountTest.empty),
  Layer.provide(NpmTest.noop),
  Layer.provide(FetchHttpClient.layer),
)

const workspaceLayer = (experimentalWorkspaces: boolean) =>
  Workspace.layer.pipe(
    Layer.provide(Auth.defaultLayer),
    Layer.provide(Session.defaultLayer),
    Layer.provide(SyncEvent.defaultLayer),
    Layer.provide(SessionPrompt.defaultLayer),
    Layer.provide(Project.defaultLayer),
    Layer.provide(Vcs.defaultLayer),
    Layer.provide(FetchHttpClient.layer),
    Layer.provide(AppFileSystem.defaultLayer),
    Layer.provide(RuntimeFlags.layer({ experimentalWorkspaces })),
    Layer.provide(InstanceStore.defaultLayer.pipe(Layer.provide(InstanceBootstrap.defaultLayer))),
  )

const it = testEffect(
  Layer.mergeAll(
    NodeServices.layer,
    Plugin.layer.pipe(
      Layer.provide(Bus.layer),
      Layer.provide(configLayer),
      Layer.provide(RuntimeFlags.layer({ disableDefaultPlugins: true })),
    ),
    workspaceLayer(true),
    CrossSpawnSpawner.defaultLayer,
  ),
)

type WorkspaceInfo = { id: string; name: string; directory: string; type: string }

function requiredEnv(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is required`)
  return value
}

function asFileUrl(filePath: string): string {
  return `file://${filePath}`
}

async function makeRepo(root: string): Promise<string> {
  const repo = path.join(root, "owner", "repo")
  await fs.mkdir(repo, { recursive: true })
  await $`git init`.cwd(repo).quiet()
  await $`git config core.fsmonitor false`.cwd(repo).quiet()
  await $`git config commit.gpgsign false`.cwd(repo).quiet()
  await $`git config user.email test@kfactory.invalid`.cwd(repo).quiet()
  await $`git config user.name "Kfactory Test"`.cwd(repo).quiet()
  await Bun.write(path.join(repo, "README.md"), "# kfactory adapter contract\n")
  await $`git add README.md`.cwd(repo).quiet()
  await $`git commit -m initial`.cwd(repo).quiet()
  return repo
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await fs.access(p)
    return true
  } catch {
    return false
  }
}

async function requestJson<T>(input: string, init?: RequestInit): Promise<T> {
  const response = await Server.Default().app.request(input, init)
  const text = await response.text()
  if (response.status !== 200) throw new Error(`${input} returned ${response.status}: ${text}`)
  return JSON.parse(text) as T
}

async function createWorkspace(directory: string, repoUrl: string, extra: Record<string, unknown>): Promise<WorkspaceInfo> {
  return requestJson<WorkspaceInfo>("/experimental/workspace", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-opencode-directory": directory,
    },
    body: JSON.stringify({
      type: "kfactory",
      branch: null,
      extra: { repoUrl, ...extra },
    }),
  })
}

function withKfactoryAdapterProject<A, E, R>(self: (directory: string, workspaces: string) => Effect.Effect<A, E, R>) {
  const pluginPath = requiredEnv("KFACTORY_ADAPTER_PLUGIN_PATH")
  return provideTmpdirInstance(
    (directory) =>
      Effect.gen(function* () {
        const workspaces = path.join(directory, "workspaces")
        const previousWorkspaces = process.env.KFACTORY_ADAPTER_WORKSPACES_DIR
        process.env.KFACTORY_ADAPTER_WORKSPACES_DIR = workspaces
        yield* Effect.addFinalizer(() =>
          Effect.sync(() => {
            if (previousWorkspaces === undefined) delete process.env.KFACTORY_ADAPTER_WORKSPACES_DIR
            else process.env.KFACTORY_ADAPTER_WORKSPACES_DIR = previousWorkspaces
          }),
        )

        yield* Effect.promise(() =>
          Bun.write(
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
        yield* Effect.promise(() =>
          Bun.write(
            path.join(directory, "opencode.json"),
            JSON.stringify({
              $schema: "https://opencode.ai/config.json",
              formatter: false,
              lsp: false,
            }),
          ),
        )
        return yield* self(directory, workspaces)
      }),
    { git: true },
  )
}

afterEach(async () => {
  await disposeAllInstances()
  Database.close()
})

describe("kfactory adapter plugin interaction", () => {
  it.live("loads the real plugin and creates workspaces through opencode's HTTP API", () =>
    withKfactoryAdapterProject((directory, workspaces) =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const adapter = getAdapter(instance.project.id, "kfactory")
        expect(adapter).toBeDefined()

        const adapters = yield* Effect.promise(() =>
          requestJson<Array<{ type: string; name: string }>>("/experimental/workspace/adapter", {
            headers: { "x-opencode-directory": directory },
          }),
        )
        expect(adapters.some((adapter) => adapter.type === "kfactory" && adapter.name === "kfactory")).toBe(true)

        const repo = yield* Effect.promise(() => makeRepo(directory))
        const repoUrl = asFileUrl(repo)
        const first = yield* Effect.promise(() => createWorkspace(directory, repoUrl, { slugSuffix: "beef" }))

        expect(first.type).toBe("kfactory")
        expect(first.name.endsWith("--repo--beef")).toBe(true)
        expect(first.directory).toBe(path.join(workspaces, first.name))
        const readme = yield* Effect.promise(() => Bun.file(path.join(first.directory, "README.md")).text())
        expect(readme).toContain("kfactory adapter contract")

        const rows = yield* Effect.promise(() =>
          requestJson<WorkspaceInfo[]>("/experimental/workspace", { headers: { "x-opencode-directory": directory } }),
        )
        expect(rows.filter((row) => row.id === first.id)).toHaveLength(1)
      }),
    ),
  )

  it.live("rejects present-but-invalid slugSuffix instead of minting a fallback name", () =>
    withKfactoryAdapterProject((directory) =>
      Effect.gen(function* () {
        const repo = yield* Effect.promise(() => makeRepo(directory))
        const repoUrl = asFileUrl(repo)

        const response = yield* Effect.promise(() =>
          Server.Default().app.request("/experimental/workspace", {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "x-opencode-directory": directory,
            },
            body: JSON.stringify({
              type: "kfactory",
              branch: null,
              extra: { repoUrl, slugSuffix: "not-hex" },
            }),
          }),
        )
        expect(response.status).toBe(500)

        const rows = yield* Effect.promise(() =>
          requestJson<WorkspaceInfo[]>("/experimental/workspace", { headers: { "x-opencode-directory": directory } }),
        )
        expect(rows).toHaveLength(0)
      }),
    ),
  )

  it.live("rejects lossy repo slug segments before persisting a workspace", () =>
    withKfactoryAdapterProject((directory) =>
      Effect.gen(function* () {
        const response = yield* Effect.promise(() =>
          Server.Default().app.request("/experimental/workspace", {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "x-opencode-directory": directory,
            },
            body: JSON.stringify({
              type: "kfactory",
              branch: null,
              extra: { repoUrl: "https://example.invalid/owner/re-po", slugSuffix: "beef" },
            }),
          }),
        )
        expect(response.status).toBe(500)

        const rows = yield* Effect.promise(() =>
          requestJson<WorkspaceInfo[]>("/experimental/workspace", { headers: { "x-opencode-directory": directory } }),
        )
        expect(rows).toHaveLength(0)
      }),
    ),
  )

  it.live("rejects name/repo identity mismatches before clone", () =>
    withKfactoryAdapterProject((directory, workspaces) =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const adapter = getAdapter(instance.project.id, "kfactory")
        expect(adapter).toBeDefined()
        const repo = yield* Effect.promise(() => makeRepo(directory))
        const mismatchedDir = path.join(workspaces, "other--repo--beef")

        yield* Effect.promise(async () => {
          await expect(
            adapter!.create({
              id: "wrk_mismatch",
              type: "kfactory",
              name: "other--repo--beef",
              branch: null,
              directory: mismatchedDir,
              projectID: instance.project.id,
              extra: { repoUrl: asFileUrl(repo) },
              time: { created: Date.now(), updated: Date.now() },
            }),
          ).rejects.toThrow(/does not match repo owner\/repo/)
        })
        expect(yield* Effect.promise(() => pathExists(mismatchedDir))).toBe(false)
      }),
    ),
  )

  it.live("rejects directory witness mismatches in create target and remove", () =>
    withKfactoryAdapterProject((directory, workspaces) =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const adapter = getAdapter(instance.project.id, "kfactory")
        expect(adapter).toBeDefined()
        const repo = yield* Effect.promise(() => makeRepo(directory))
        const info = {
          id: "wrk_bad_directory",
          type: "kfactory",
          name: "owner--repo--beef",
          branch: null,
          directory: path.join(workspaces, "owner--repo--cafe"),
          projectID: instance.project.id,
          extra: { repoUrl: asFileUrl(repo) },
          time: { created: Date.now(), updated: Date.now() },
        }

        expect(() => adapter!.target(info)).toThrow(/workspace directory mismatch/)
        yield* Effect.promise(async () => {
          await expect(adapter!.create(info)).rejects.toThrow(/workspace directory mismatch/)
          await expect(adapter!.remove(info)).rejects.toThrow(/workspace directory mismatch/)
        })
      }),
    ),
  )

  it.live("clone failure leaves no final slug directory", () =>
    withKfactoryAdapterProject((directory, workspaces) =>
      Effect.gen(function* () {
        const repoUrl = asFileUrl(path.join(directory, "missing-owner", "missing-repo"))
        const finalDir = path.join(workspaces, "missing-owner--missing-repo--beef")
        const response = yield* Effect.promise(() =>
          Server.Default().app.request("/experimental/workspace", {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "x-opencode-directory": directory,
            },
            body: JSON.stringify({
              type: "kfactory",
              branch: null,
              extra: { repoUrl, slugSuffix: "beef" },
            }),
          }),
        )
        expect(response.status).toBe(500)
        expect(yield* Effect.promise(() => pathExists(finalDir))).toBe(false)

        const rows = yield* Effect.promise(() =>
          requestJson<WorkspaceInfo[]>("/experimental/workspace", { headers: { "x-opencode-directory": directory } }),
        )
        expect(rows).toHaveLength(0)
      }),
    ),
  )

  it.live("rejects a relative workspaces root before persisting a workspace", () =>
    provideTmpdirInstance(
      (directory) =>
        Effect.gen(function* () {
          const pluginPath = requiredEnv("KFACTORY_ADAPTER_PLUGIN_PATH")
          const previousWorkspaces = process.env.KFACTORY_ADAPTER_WORKSPACES_DIR
          process.env.KFACTORY_ADAPTER_WORKSPACES_DIR = "relative-workspaces"
          yield* Effect.addFinalizer(() =>
            Effect.sync(() => {
              if (previousWorkspaces === undefined) delete process.env.KFACTORY_ADAPTER_WORKSPACES_DIR
              else process.env.KFACTORY_ADAPTER_WORKSPACES_DIR = previousWorkspaces
            }),
          )

          yield* Effect.promise(() =>
            Bun.write(
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
          const instance = yield* requireInstance
          const adapter = getAdapter(instance.project.id, "kfactory")
          expect(adapter).toBeDefined()
          expect(() =>
            adapter!.configure({
              id: "wrk_relative_root",
              type: "kfactory",
              name: "",
              branch: null,
              directory: "",
              projectID: instance.project.id,
              extra: { repoUrl: "file:///owner/repo" },
              time: { created: Date.now(), updated: Date.now() },
            }),
          ).toThrow(/WORKSPACES_DIR must be absolute/)
        }),
      { git: true },
    ),
  )
})
