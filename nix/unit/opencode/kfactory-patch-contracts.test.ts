import { afterEach, describe, expect } from "bun:test"
import { eq } from "drizzle-orm"
import { Effect, Exit, Layer } from "effect"
import { FetchHttpClient } from "effect/unstable/http"
import { mkdir } from "node:fs/promises"
import path from "node:path"
import { getAdapter, registerAdapter } from "../../src/control-plane/adapters"
import type { WorkspaceAdapter } from "../../src/control-plane/types"
import { Workspace } from "../../src/control-plane/workspace"
import { WorkspaceTable } from "@opencode-ai/core/control-plane/workspace.sql"
import { RuntimeFlags } from "../../src/effect/runtime-flags"
import { ProjectV2 } from "@opencode-ai/core/project"
import { Project } from "../../src/project/project"
import { Server } from "../../src/server/server"
import { Session } from "@/session/session"
import { SessionTable } from "@opencode-ai/core/session/sql"
import { Database } from "@opencode-ai/core/database/database"
import { Ripgrep } from "@opencode-ai/core/ripgrep"
import { resetDatabase } from "../fixture/db"
import { disposeAllInstances, requireInstance, tmpdirScoped } from "../fixture/fixture"
import { workspaceLayerWithRuntimeFlags } from "../fixture/workspace"
import { testEffectShared } from "../lib/effect"

const it = testEffectShared(
  Layer.mergeAll(
    Project.defaultLayer,
    Session.defaultLayer,
    workspaceLayerWithRuntimeFlags({ experimentalWorkspaces: true }),
    FetchHttpClient.layer,
    RuntimeFlags.layer({ experimentalWorkspaces: true }),
    Database.defaultLayer,
  ).pipe(Layer.provide(Ripgrep.defaultLayer)),
)

function unique(prefix: string): string {
  return `${prefix}-${Math.random().toString(36).slice(2)}`
}

function localAdapter(
  directory: string,
  name = path.basename(directory),
  remove: WorkspaceAdapter["remove"] = async () => {},
  create: WorkspaceAdapter["create"] = async () => {
    await mkdir(directory, { recursive: true })
  },
): WorkspaceAdapter {
  return {
    name: "kfactory contract local",
    description: "kfactory contract local",
    configure: (info) => ({ ...info, name, directory }),
    create,
    remove,
    target: () => ({ type: "local", directory }),
  }
}

async function cleanup() {
  await disposeAllInstances()
  await resetDatabase()
}

afterEach(cleanup)

describe("kfactory opencode patch contracts", () => {
  it.effect("global adapter registration is a fallback, not an override", () =>
    Effect.gen(function* () {
      const type = unique("global-adapter")
      const projectID = ProjectV2.ID.make(unique("project"))
      const global = localAdapter("/tmp/global-adapter")
      const local = localAdapter("/tmp/local-adapter")

      registerAdapter(ProjectV2.ID.global, type, global)
      expect(getAdapter(projectID, type)).toBe(global)

      registerAdapter(projectID, type, local)
      expect(getAdapter(projectID, type)).toBe(local)
    }),
  )

  it.instance(
    "malformed explicit workspace selectors fail instead of routing to default workspace",
    () =>
      Effect.gen(function* () {
        const dir = yield* tmpdirScoped({ git: true })

        const query = yield* Effect.promise(() =>
          Server.Default().app.request("/vcs?workspace=not-a-workspace", {
            headers: { "x-opencode-directory": dir },
          }),
        )
        expect(query.status).toBe(400)

        const header = yield* Effect.promise(() =>
          Server.Default().app.request("/session", {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "x-opencode-directory": dir,
              "x-opencode-workspace": "not-a-workspace",
            },
            body: JSON.stringify({ title: "must not route to default" }),
          }),
        )
        expect(header.status).toBe(400)
      }),
    { git: true },
    30_000,
  )

  it.instance(
    "POST /session routes by valid x-opencode-workspace header",
    () =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const workspace = yield* Workspace.Service
        const dir = yield* tmpdirScoped({ git: true })
        const type = unique("session-header")
        registerAdapter(instance.project.id, type, localAdapter(path.join(dir, "target"), "session-header-contract"))
        const info = yield* workspace.create({ type, branch: null, projectID: instance.project.id, extra: null })

        const response = yield* Effect.promise(() =>
          Server.Default().app.request("/session", {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "x-opencode-directory": dir,
              "x-opencode-workspace": info.id,
            },
            body: JSON.stringify({ title: "header-routed" }),
          }),
        )
        expect(response.status).toBe(200)
        const created = (yield* Effect.promise(() => response.json())) as { id: string }
        const row = yield* Database.Service.use(({ db }) => db.select().from(SessionTable).where(eq(SessionTable.id, created.id)).get())
        expect(row?.workspace_id).toBe(info.id)
      }),
    { git: true },
    30_000,
  )

  it.instance(
    "session list with workspaceID ignores mismatched project_id",
    () =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const sessions = yield* Session.Service
        const workspace = yield* Workspace.Service
        const dir = yield* tmpdirScoped({ git: true })
        const otherDir = yield* tmpdirScoped({ git: true })
        const otherProject = yield* Project.use.fromDirectory(otherDir)
        const typeA = unique("session-a")
        const typeB = unique("session-b")
        registerAdapter(instance.project.id, typeA, localAdapter(path.join(dir, "a"), "contract-a"))
        registerAdapter(instance.project.id, typeB, localAdapter(path.join(dir, "b"), "contract-b"))
        const wsA = yield* workspace.create({ type: typeA, branch: null, projectID: instance.project.id, extra: null })
        const wsB = yield* workspace.create({ type: typeB, branch: null, projectID: instance.project.id, extra: null })

        const a = yield* sessions.create({ title: "a", workspaceID: wsA.id })
        const b = yield* sessions.create({ title: "b", workspaceID: wsB.id })

        yield* Database.Service.use(({ db }) =>
          db
            .update(SessionTable)
            .set({ project_id: otherProject.project.id })
            .where(eq(SessionTable.id, b.id))
            .run(),
        )

        const listed = yield* sessions.list({ workspaceID: wsB.id, roots: true, limit: 10 })
        expect(listed.map((item) => item.id)).toEqual([b.id])
        expect(listed.some((item) => item.id === a.id)).toBe(false)
        expect(instance.project.id).not.toBe(otherProject.project.id)
      }),
    { git: true },
    30_000,
  )

  it.instance(
    "GET /experimental/session routes by workspace query instead of project_id",
    () =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const sessions = yield* Session.Service
        const workspace = yield* Workspace.Service
        const dir = yield* tmpdirScoped({ git: true })
        const otherDir = yield* tmpdirScoped({ git: true })
        const otherProject = yield* Project.use.fromDirectory(otherDir)
        const typeA = unique("session-http-a")
        const typeB = unique("session-http-b")
        registerAdapter(instance.project.id, typeA, localAdapter(path.join(dir, "http-a"), "contract-http-a"))
        registerAdapter(instance.project.id, typeB, localAdapter(path.join(dir, "http-b"), "contract-http-b"))
        const wsA = yield* workspace.create({ type: typeA, branch: null, projectID: instance.project.id, extra: null })
        const wsB = yield* workspace.create({ type: typeB, branch: null, projectID: instance.project.id, extra: null })
        const a = yield* sessions.create({ title: "a", workspaceID: wsA.id })
        const b = yield* sessions.create({ title: "b", workspaceID: wsB.id })
        yield* Database.Service.use(({ db }) =>
          db.update(SessionTable).set({ project_id: otherProject.project.id }).where(eq(SessionTable.id, b.id)).run(),
        )

        const response = yield* Effect.promise(() =>
          Server.Default().app.request(`/experimental/session?workspace=${encodeURIComponent(wsB.id)}&roots=true`, {
            headers: { "x-opencode-directory": dir },
          }),
        )
        expect(response.status).toBe(200)
        const listed = (yield* Effect.promise(() => response.json())) as Array<{ id: string }>
        expect(listed.map((item) => item.id)).toEqual([b.id])
        expect(listed.some((item) => item.id === a.id)).toBe(false)
      }),
    { git: true },
    30_000,
  )

  it.instance(
    "workspace create rolls back DB row when adapter create fails",
    () =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const workspace = yield* Workspace.Service
        const dir = yield* tmpdirScoped({ git: true })
        const type = unique("create-fail")
        registerAdapter(
          instance.project.id,
          type,
          localAdapter(path.join(dir, "target"), "create-fail-contract", async () => {}, async () => {
            throw new Error("clone failed")
          }),
        )

        const exit = yield* workspace.create({ type, branch: null, projectID: instance.project.id, extra: null }).pipe(Effect.exit)
        expect(Exit.isFailure(exit)).toBe(true)

        const rows = yield* Database.Service.use(({ db }) => db.select().from(WorkspaceTable).where(eq(WorkspaceTable.type, type)).all())
        expect(rows).toHaveLength(0)
      }),
    { git: true },
    30_000,
  )

  it.instance(
    "workspace remove preserves DB row when adapter cleanup fails",
    () =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const sessions = yield* Session.Service
        const workspace = yield* Workspace.Service
        const dir = yield* tmpdirScoped({ git: true })
        const type = unique("remove-fail")
        registerAdapter(
          instance.project.id,
          type,
          localAdapter(path.join(dir, "target"), "remove-fail-contract", async () => {
            throw new Error("rm failed")
          }),
        )
        const info = yield* workspace.create({ type, branch: null, projectID: instance.project.id, extra: null })
        const sessionInfo = yield* sessions.create({ title: "keep me until cleanup succeeds", workspaceID: info.id })

        const exit = yield* workspace.remove(info.id).pipe(Effect.exit)
        expect(Exit.isFailure(exit)).toBe(true)

        const row = yield* Database.Service.use(({ db }) => db.select().from(WorkspaceTable).where(eq(WorkspaceTable.id, info.id)).get())
        expect(row?.id).toBe(info.id)
        const sessionRow = yield* Database.Service.use(({ db }) => db.select().from(SessionTable).where(eq(SessionTable.id, sessionInfo.id)).get())
        expect(sessionRow?.id).toBe(sessionInfo.id)
      }),
    { git: true },
    30_000,
  )

  it.instance(
    "startWorkspaceSyncing can target a workspace whose project_id differs from caller project",
    () =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const dir = yield* tmpdirScoped({ git: true })
        const otherDir = yield* tmpdirScoped({ git: true })
        const otherProject = yield* Project.use.fromDirectory(otherDir)
        const workspace = yield* Workspace.Service
        const type = unique("sync-start")
        const target = path.join(dir, "target")

        registerAdapter(instance.project.id, type, localAdapter(target, "sync-start-contract"))
        const info = yield* workspace.create({ type, branch: null, projectID: instance.project.id, extra: null })
        yield* Database.Service.use(({ db }) =>
          db.update(WorkspaceTable).set({ project_id: otherProject.project.id }).where(eq(WorkspaceTable.id, info.id)).run(),
        )

        yield* workspace.startWorkspaceSyncing(instance.project.id, { workspaceID: info.id })

        const status = yield* workspace.status()
        expect(status.find((item) => item.workspaceID === info.id)?.status).toBe("connected")
      }),
    { git: true },
    30_000,
  )

  it.instance(
    "POST /sync/start routes by explicit workspace query",
    () =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const dir = yield* tmpdirScoped({ git: true })
        const otherDir = yield* tmpdirScoped({ git: true })
        const otherProject = yield* Project.use.fromDirectory(otherDir)
        const workspace = yield* Workspace.Service
        const type = unique("sync-http-query")
        const target = path.join(dir, "sync-http-query-target")

        registerAdapter(instance.project.id, type, localAdapter(target, "sync-http-query-contract"))
        const info = yield* workspace.create({ type, branch: null, projectID: instance.project.id, extra: null })
        yield* Database.Service.use(({ db }) =>
          db.update(WorkspaceTable).set({ project_id: otherProject.project.id }).where(eq(WorkspaceTable.id, info.id)).run(),
        )

        const response = yield* Effect.promise(() =>
          Server.Default().app.request(`/sync/start?workspace=${encodeURIComponent(info.id)}`, {
            method: "POST",
            headers: { "content-type": "application/json", "x-opencode-directory": dir },
            body: JSON.stringify({}),
          }),
        )
        if (![200, 204].includes(response.status)) {
          throw new Error(`sync/start query returned ${response.status}: ${yield* Effect.promise(() => response.text())}`)
        }
        const status = yield* workspace.status()
        expect(status.find((item) => item.workspaceID === info.id)?.status).toBe("connected")
      }),
    { git: true },
    30_000,
  )

  it.instance(
    "POST /sync/start routes by x-opencode-workspace header",
    () =>
      Effect.gen(function* () {
        const instance = yield* requireInstance
        const dir = yield* tmpdirScoped({ git: true })
        const otherDir = yield* tmpdirScoped({ git: true })
        const otherProject = yield* Project.use.fromDirectory(otherDir)
        const workspace = yield* Workspace.Service
        const type = unique("sync-http-header")
        const target = path.join(dir, "sync-http-header-target")

        registerAdapter(instance.project.id, type, localAdapter(target, "sync-http-header-contract"))
        const info = yield* workspace.create({ type, branch: null, projectID: instance.project.id, extra: null })
        yield* Database.Service.use(({ db }) =>
          db.update(WorkspaceTable).set({ project_id: otherProject.project.id }).where(eq(WorkspaceTable.id, info.id)).run(),
        )

        const response = yield* Effect.promise(() =>
          Server.Default().app.request("/sync/start", {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "x-opencode-directory": dir,
              "x-opencode-workspace": info.id,
            },
            body: JSON.stringify({}),
          }),
        )
        if (![200, 204].includes(response.status)) {
          throw new Error(`sync/start header returned ${response.status}: ${yield* Effect.promise(() => response.text())}`)
        }
        const status = yield* workspace.status()
        expect(status.find((item) => item.workspaceID === info.id)?.status).toBe("connected")
      }),
    { git: true },
    30_000,
  )

})
