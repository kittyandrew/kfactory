// KfactoryAdapter -- opencode workspace adapter for kfactory.
//
// Returns `type: "local"` so opencode dispatches each workspace via
// `InstanceStore.provide({directory}, effect)` in-process (no per-
// workspace spawn / port / scope). Adapter responsibilities:
//   configure(): mint or preserve `<owner>--<repo>--<4hex>` slug; set
//                workspace `directory` to absolute path.
//   create():    mkdir + `git clone` the repo.
//   remove():    rm -rf workspace dir. Operator-initiated only (DELETE
//                /experimental/workspace/<id>); no auto-delete.
//   target():    `{type: "local", directory}`; opencode does the rest.
//
// Env (all optional):
//   KFACTORY_ADAPTER_GIT             path to git ("git")
//   KFACTORY_ADAPTER_OPENSSH_SSH     path to ssh ("ssh")
//   KFACTORY_ADAPTER_WORKSPACES_DIR  workspaces root ("/var/lib/factory/workspaces")
//
// @WARNING: the PATH-resolved defaults FAIL under systemd User= units
//   (sanitized PATH). Set absolute paths via env vars; the
//   `opencode-kfactory` wrapper in flake.nix does this automatically.
//
// @WARNING: opencode's WorkspaceAdapter API is experimental (gated by
//   OPENCODE_EXPERIMENTAL_WORKSPACES). Watch upstream for breaking
//   changes; factory-opencode-patch-applies + the plugin typecheck
//   catch drift.
import type { Plugin, WorkspaceInfo } from "@opencode-ai/plugin"
import { spawn } from "node:child_process"
import { randomBytes } from "node:crypto"
import { mkdir, realpath, rm } from "node:fs/promises"

// ---- Runtime configuration ----

const GIT = process.env.KFACTORY_ADAPTER_GIT ?? "git"
const OPENSSH_SSH = process.env.KFACTORY_ADAPTER_OPENSSH_SSH ?? "ssh"
const WORKSPACES_DIR =
  process.env.KFACTORY_ADAPTER_WORKSPACES_DIR ?? "/var/lib/factory/workspaces"

// ---- URL + slug helpers ----

// Slug shape: `<owner>--<repo>--<4hex>`. Suffix is either random
// (`randomBytes(2)`, 16-bit space) or a deterministic 4-hex task-id
// from `extra.slugSuffix` (used by `kfactory tick` so scheduled-task
// workspaces survive opencode restarts; cmd/kfactory/tick.go +
// modules/scheduled-tasks.nix gate the input). Segments are
// [A-Za-z0-9._] only (no hyphens -- `--` is the delimiter). isValidSlug
// is the load-bearing defense against path traversal; asserted at
// every boundary that concatenates the slug into a path (configure,
// create, target, remove).
const SLUG_RE = /^[A-Za-z0-9._]+--[A-Za-z0-9._]+--[a-f0-9]{4}$/

function isValidSlug(name: string): boolean {
  return SLUG_RE.test(name)
}

// Parse owner + repo from a git URL. Handles https://, git@host:, and
// file:// forms; nested paths (GitLab subgroups, Gitea orgs-with-paths)
// join intermediate segments into `owner` with `_` so distinct parent
// orgs sharing a subgroup name still produce distinct slugs. `..` and
// empty segments dropped; remaining segments routed through
// sanitizeSlugSegment to stay regex-clean. Throws if it can't reduce
// to ≥2 segments.
function parseOwnerRepo(repoUrl: string): {owner: string; repo: string} {
  const path = repoUrl
    .replace(/\.git$/, "")
    .replace(/^[a-z][a-z0-9+.-]*:\/\/[^/]*\/?/i, "") // strip scheme + host
    .replace(/^[^@/:]+@[^:/]+:/, "") // strip ssh user@host:
  const segments = path
    .split("/")
    .map((s) => s.trim())
    .filter((s) => s.length > 0 && s !== "..")
  if (segments.length < 2) {
    throw new Error(`kfactory: cannot parse owner/repo from: ${repoUrl}`)
  }
  const repo = sanitizeSlugSegment(segments[segments.length - 1]!)
  const owner = segments
    .slice(0, -1)
    .map(sanitizeSlugSegment)
    .filter((s) => s.length > 0)
    .join("_")
  if (owner.length === 0 || repo.length === 0) {
    throw new Error(`kfactory: cannot parse owner/repo from: ${repoUrl}`)
  }
  return {owner, repo}
}

// Hyphens included in the strip-list -- SLUG_RE's delimiter is `--`, so
// hyphens inside segments would create ambiguity.
function sanitizeSlugSegment(s: string): string {
  return s.replace(/[^a-zA-Z0-9._]/g, "_")
}

function parseExtra(
  info: Pick<WorkspaceInfo, "extra">,
): {repoUrl: string; slugSuffix?: string} {
  const extra = (info.extra ?? {}) as {
    repoUrl?: unknown
    slugSuffix?: unknown
  }
  const out: {repoUrl: string; slugSuffix?: string} = {
    repoUrl: typeof extra.repoUrl === "string" ? extra.repoUrl : "",
  }
  // Caller-supplied slug suffix must match the random-mint shape (4 hex).
  // CLI gates this upstream; regex here is boundary defense for direct
  // API callers / future migrations.
  if (typeof extra.slugSuffix === "string" && /^[a-f0-9]{4}$/.test(extra.slugSuffix)) {
    out.slugSuffix = extra.slugSuffix
  }
  return out
}

// Durability: configure() re-runs on every adapter call; opencode passes
// the persisted `info.name` back. Short-circuit on a valid slug so a
// later call with `extra` nulled (DB round-trip, schema change) still
// returns the existing slug rather than re-minting against an empty
// repoUrl. Short-circuit predicate MUST be isValidSlug (same as every
// downstream boundary) so a loosely-accepted slug can't pollute the DB
// and die at the next dispatch.
function buildWorkspaceSlug(info: Pick<WorkspaceInfo, "name" | "extra">): string {
  if (info.name && isValidSlug(info.name)) {
    return info.name
  }
  const {repoUrl, slugSuffix} = parseExtra(info)
  const {owner, repo} = parseOwnerRepo(repoUrl)
  const suffix = slugSuffix ?? randomBytes(2).toString("hex")
  return `${owner}--${repo}--${suffix}`
}

function workspaceDir(slug: string): string {
  return `${WORKSPACES_DIR}/${slug}`
}

// Symlink-escape defense: resolves both `dir` and WORKSPACES_DIR, then
// verifies the prefix. The slug regex (isValidSlug) is the load-bearing
// defense against path traversal -- both must hold. ENOENT fallback to
// literal-prefix compare exists for fresh deployments (workspaces dir
// doesn't exist yet); it's NOT an independent path-traversal defense.
async function assertWithinWorkspaces(dir: string): Promise<void> {
  let realDir: string | null = null
  try {
    realDir = await realpath(dir)
  } catch {
    // Fall through to literal-prefix below.
  }
  let realRoot: string
  try {
    realRoot = await realpath(WORKSPACES_DIR)
  } catch {
    realRoot = WORKSPACES_DIR
  }
  const probe = realDir ?? dir
  // Trailing slash so /a/b-other isn't accepted under /a/b.
  if (probe !== realRoot && !probe.startsWith(realRoot + "/")) {
    throw new Error(
      `kfactory: refusing to operate on ${dir} (resolved: ${probe}) -- outside ${realRoot}`,
    )
  }
}

// ---- Clone ----

async function cloneRepoInto(slug: string, repoUrl: string): Promise<void> {
  // Auth + host config are the consumer's responsibility (ssh-agent /
  // ~/.ssh/config / git credential helper). StrictHostKeyChecking=accept-new
  // is silent TOFU -- acceptable under the trusted-agent threat model
  // (docs/spec.md §1); without it first clone on a fresh host fails.
  if (!isValidSlug(slug)) {
    throw new Error(`kfactory: refusing to clone with invalid slug: ${slug}`)
  }
  const dir = workspaceDir(slug)
  // mkdir(recursive:false) is the atomic ownership claim: EEXIST = someone
  // else owns this slug. Persistence contract (docs/spec.md §5): only a
  // slug created by THIS invocation can be rolled back on clone failure.
  await mkdir(WORKSPACES_DIR, {recursive: true})
  let createdHere = false
  try {
    await mkdir(dir, {recursive: false})
    createdHere = true
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err
    throw new Error(
      `kfactory: slug collision -- workspace dir ${dir} already exists. ` +
        `Re-run dispatch to mint a fresh slug.`,
    )
  }
  try {
    await new Promise<void>((resolve, reject) => {
      // `--` end-of-options sentinel: hygiene against URLs starting with
      // `-` (the operator is trusted, this isn't a security boundary).
      const p = spawn(GIT, ["clone", "--", repoUrl, "."], {
        cwd: dir,
        env: {
          ...process.env,
          GIT_TERMINAL_PROMPT: "0",
          GIT_SSH_COMMAND: `${OPENSSH_SSH} -o StrictHostKeyChecking=accept-new`,
        },
      })
      let stderr = ""
      // `error` fires when spawn itself fails (e.g. ENOENT under
      // systemd User= PATH sanitization). Without this listener `close`
      // never fires and the caller hangs forever.
      p.on("error", reject)
      p.stderr.on("data", (c) => (stderr += c))
      p.on("close", (code) => {
        if (code === 0) resolve()
        else reject(new Error(`git clone exit ${code}: ${stderr}`))
      })
    })
  } catch (err) {
    if (createdHere) {
      // Re-validate before rm: defense in depth against `dir` mutation.
      try {
        await assertWithinWorkspaces(dir)
        await rm(dir, {recursive: true, force: true})
      } catch (rmErr) {
        console.warn(
          `kfactory: cleanup of partial clone ${dir} failed:`,
          rmErr instanceof Error ? rmErr.message : rmErr,
        )
      }
    }
    throw err
  }
}

// ---- WorkspaceAdapter ----

export const KfactoryAdapter: Plugin = async ({experimental_workspace}) => {
  experimental_workspace.register("kfactory", {
    name: "kfactory",
    description: "kfactory: per-repo workspaces, in-process via InstanceStore",

    // `info.name` round-trips: opencode persists what we return and
    // restores it on subsequent calls. buildWorkspaceSlug preserves
    // valid slugs / mints fresh otherwise. isValidSlug here is the
    // first slug-boundary check; catches any future bug in the mint
    // path before it pollutes the DB.
    configure(info) {
      const slug = buildWorkspaceSlug(info)
      if (!isValidSlug(slug)) {
        throw new Error(
          `kfactory: configure() produced invalid slug: ${slug}`,
        )
      }
      return {
        ...info,
        name: slug,
        // `directory` is an absolute path INSIDE the factory VM; any
        // future federation surface that exposes it externally would
        // see a path that doesn't exist there.
        directory: workspaceDir(slug),
      }
    },

    async create(info) {
      const slug = info.name
      const {repoUrl} = parseExtra(info)
      if (!repoUrl) throw new Error(`kfactory: extra.repoUrl is required`)
      await cloneRepoInto(slug, repoUrl)
    },

    async remove(info) {
      // Derive the path from `info.name` (the slug, source of identity),
      // NOT `info.directory` (looser sibling field, can drift across DB
      // mutations). assertWithinWorkspaces is belt-and-suspenders.
      // Propagate rm failures: opencode deletes the DB row AFTER remove()
      // resolves, so a swallowed error orphans the clone silently.
      if (!isValidSlug(info.name)) {
        throw new Error(
          `kfactory: refusing to remove workspace with invalid slug: ${info.name}`,
        )
      }
      const dir = workspaceDir(info.name)
      await assertWithinWorkspaces(dir)
      try {
        await rm(dir, {recursive: true, force: true})
      } catch (err) {
        console.warn(
          `kfactory: remove(${info.name}): rm failed:`,
          err instanceof Error ? err.message : err,
        )
        throw err
      }
    },

    target(info) {
      // `local`: opencode dispatches via InstanceStore.provide() in the
      // same process (workspace-routing.ts:planRequest's local path).
      // Re-validate -- target() runs on EVERY request, so a corrupted
      // info.name would otherwise root an in-process context at an
      // attacker-influenced path.
      if (!isValidSlug(info.name)) {
        throw new Error(
          `kfactory: refusing to dispatch workspace with invalid slug: ${info.name}`,
        )
      }
      return {type: "local", directory: workspaceDir(info.name)}
    },
  })
  return {}
}

export default KfactoryAdapter
