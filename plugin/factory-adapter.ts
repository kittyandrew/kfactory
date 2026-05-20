// FactoryAdapter — opencode workspace adapter for the kfactory deployment.
//
// v2: single-process design. opencode runs ONE `serve` per VM; this adapter
// returns `type: "local"` so opencode's native control-plane dispatches each
// workspace via `InstanceStore.provide({directory}, effect)` in-process. No
// per-workspace process spawning, no port pool, no scope lifecycle, no
// reconcile-on-load. v1 carried ~600 LOC of that complexity because we
// modeled workspaces as remote workers; we don't anymore.
//
// What this adapter actually does:
//   - configure(): mint or preserve a `<owner>--<repo>--<4hex>` slug;
//     set the workspace `directory` to the absolute path opencode should
//     open in-process.
//   - create(): `mkdir` the workspace dir + `git clone` the repo.
//   - remove(): `rm -rf` the workspace dir. Persistence contract: data is
//     never AUTO-deleted; opencode reaches remove() only via DELETE
//     /experimental/workspace/<id> -- explicitly operator-initiated.
//   - target(): `{type: "local", directory}`. opencode handles the rest.
//
// Processed by `pkgs.replaceVars` in the consumer's NixOS config (via
// `lib.mkFactoryAdapter`): literal at-signed names inside the constants
// block (see below) get replaced with absolute store paths. The output
// is what opencode loads via opencode.jsonc's `plugin` array. Editing
// workflow: .claude/rules/010-plugin.md.
//
// @WARNING: opencode's WorkspaceAdapter API is EXPERIMENTAL (gated by
//    OPENCODE_EXPERIMENTAL_WORKSPACES). Pin opencode version in flake.nix;
//    watch upstream for breaking changes to control-plane/types.ts
//    WorkspaceAdapter signature. The `factory-opencode-patch-applies` flake
//    check catches patch-against-source drift; the `factory-plugin-typecheck`
//    check catches type-shape drift.
import type { Plugin, WorkspaceInfo } from "@opencode-ai/plugin"
import { spawn } from "node:child_process"
import { randomBytes } from "node:crypto"
import { mkdir, rm } from "node:fs/promises"

// ---- Nix-substituted constants ----
// Placeholder values filled in by pkgs.replaceVars at build time.

const GIT = "@GIT@"
const OPENSSH_SSH = "@OPENSSH_SSH@"
const WORKSPACES_DIR = "@WORKSPACES_DIR@"

// ---- Types ----

type WorkspaceExtra = { repoUrl: string }

// ---- URL + slug helpers ----

// The plugin passes repoUrl verbatim to `git clone`. Auth + URL form are
// the consumer's responsibility: whatever URL `kfactory dispatch` accepts
// must be resolvable by the running host's ssh-agent / ~/.ssh/config /
// git credential helper. SSH, https, and any git-supported scheme are
// fine; the plugin does not canonicalize or filter by hosting service.

function parseOwnerRepo(repoUrl: string): {owner: string; repo: string} {
  const m = repoUrl.match(/[/:]([^/:]+)\/([^/]+?)(?:\.git)?$/)
  if (!m) throw new Error(`factory: cannot parse owner/repo from: ${repoUrl}`)
  return {owner: m[1]!, repo: m[2]!}
}

function parseExtra(info: Pick<WorkspaceInfo, "extra">): {repoUrl: string} {
  const extra = (info.extra ?? {}) as Partial<WorkspaceExtra>
  return {repoUrl: extra.repoUrl ?? ""}
}

// Slug shape: `<owner>--<repo>--<4hex>`. Random suffix lets the operator
// stand up multiple workspaces against the same repo without specifying a
// branch up-front (the worker `git checkout`s any branch once cloned).
// 16-bit collision space is plenty at ≤10 workspaces.
//
// Durability: opencode persists configure()'s returned `info.name` and
// passes it back on subsequent adapter calls. Detect "this is our slug
// already" by structure; otherwise mint a fresh suffix.
function buildWorkspaceSlug(info: Pick<WorkspaceInfo, "name" | "extra">): string {
  const {repoUrl} = parseExtra(info)
  const {owner, repo} = parseOwnerRepo(repoUrl)
  const prefix = `${owner}--${repo}--`
  if (info.name?.startsWith(prefix) && /^[a-f0-9]{4}$/.test(info.name.slice(prefix.length))) {
    return info.name
  }
  return `${prefix}${randomBytes(2).toString("hex")}`
}

function workspaceDir(slug: string): string {
  return `${WORKSPACES_DIR}/${slug}`
}

// ---- Clone ----

async function cloneRepoInto(slug: string, repoUrl: string): Promise<void> {
  // Auth + host config are the consumer's responsibility: whatever git URL
  // is passed in must be resolvable by the running process's ssh-agent /
  // ~/.ssh/config / git credential helper. The plugin only invokes
  // `git clone <url> .` and inherits the host environment.
  //
  // StrictHostKeyChecking=accept-new: silent TOFU on first clone (writes
  // the host's key to ~/.ssh/known_hosts; refuses if it ever changes).
  // Without this, the first clone on a fresh host fails with "Host key
  // verification failed". Auth is bounded by whatever key the SSH agent
  // exposes; host identity TOFU is acceptable for the trusted-agent
  // threat model (see docs/spec.md §1).
  const dir = workspaceDir(slug)
  await mkdir(dir, {recursive: true})
  try {
    await new Promise<void>((resolve, reject) => {
      const p = spawn(GIT, ["clone", repoUrl, "."], {
        cwd: dir,
        env: {
          ...process.env,
          GIT_TERMINAL_PROMPT: "0",
          GIT_SSH_COMMAND: `${OPENSSH_SSH} -o StrictHostKeyChecking=accept-new`,
        },
      })
      let stderr = ""
      p.stderr.on("data", (c) => (stderr += c))
      p.on("close", (code) => {
        if (code === 0) resolve()
        else reject(new Error(`git clone exit ${code}: ${stderr}`))
      })
    })
  } catch (err) {
    // Clean up an empty/partial dir so a retry doesn't hit
    // "destination path '.' already exists and is not an empty directory".
    // The persistence contract applies to SUCCESSFUL workspaces; a never-
    // cloned slug isn't yet a workspace.
    await rm(dir, {recursive: true, force: true}).catch(() => {})
    throw err
  }
}

// ---- WorkspaceAdapter ----

export const FactoryAdapter: Plugin = async ({experimental_workspace}) => {
  experimental_workspace.register("factory", {
    name: "factory",
    description: "factory: per-repo workspaces, in-process via InstanceStore",

    // `info.name` round-trips: opencode generates a random `Slug.create()`
    // value BEFORE configure() (workspace.ts) and then persists what we
    // return as `name` into the DB row. Subsequent configure() calls
    // restore that persisted name. buildWorkspaceSlug preserves an
    // existing slug if it matches our shape; mints fresh otherwise.
    configure(info) {
      const slug = buildWorkspaceSlug(info)
      return {
        ...info,
        name: slug,
        // @WARNING: `directory` is opencode's source of truth for where
        //    to root the workspace's `InstanceContext`. It's an absolute
        //    path INSIDE the factory VM; any future surface that exposes
        //    `info.directory` outside the VM (e.g., a federation listing)
        //    will see a path that doesn't exist there. Acceptable for v1
        //    since `directory` is internal to the VM.
        directory: workspaceDir(slug),
      }
    },

    async create(info) {
      const slug = info.name
      const {repoUrl} = parseExtra(info)
      if (!repoUrl) throw new Error(`factory: extra.repoUrl is required`)
      await cloneRepoInto(slug, repoUrl)
    },

    async remove(info) {
      // Persistence contract (factory.md §5): workspace data is never
      // AUTO-deleted by agents or boot paths; only the operator can
      // delete. opencode reaches remove() only via DELETE
      // /experimental/workspace/<id> -- explicitly operator-initiated
      // (today, via `kfactory delete <id|slug|#>`), so wiping the on-disk
      // clone here matches the contract.
      const dir = info.directory ?? workspaceDir(info.name)
      await rm(dir, {recursive: true, force: true}).catch(() => {})
    },

    target(info) {
      // `local`: opencode dispatches the request via
      // `InstanceStore.provide({directory}, effect)` in the SAME process.
      // No HTTP proxy. No worker process. No port allocation. The path
      // workspace-routing.ts:planRequest takes for `local` targets.
      return {type: "local", directory: workspaceDir(info.name)}
    },
  })
  return {}
}
