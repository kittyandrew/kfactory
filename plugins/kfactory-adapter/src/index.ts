// KfactoryAdapter -- opencode workspace adapter for kfactory.
//
// Returns `type: "local"` so opencode dispatches each workspace via
// `InstanceStore.provide({directory}, effect)` in-process (no per-
// workspace spawn / port / scope). Adapter responsibilities:
//   configure(): mint `<owner>--<repo>--<4hex>` slug from explicit
//                producer inputs; set workspace `directory` to absolute path.
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
//   unified runtime wrapper in flake.nix does this automatically.
//
// @WARNING: opencode's WorkspaceAdapter API is experimental (gated by
//   OPENCODE_EXPERIMENTAL_WORKSPACES). Watch upstream for breaking
//   changes; factory-opencode-patch-applies + the plugin typecheck
//   catch drift.
import type { Plugin, WorkspaceInfo } from "@opencode-ai/plugin"
import { spawn } from "node:child_process"
import { randomBytes } from "node:crypto"
import { mkdir, realpath, rename, rm } from "node:fs/promises"
import path from "node:path"

// ---- Runtime configuration ----

const GIT = process.env.KFACTORY_ADAPTER_GIT ?? "git"
const OPENSSH_SSH = process.env.KFACTORY_ADAPTER_OPENSSH_SSH ?? "ssh"
function requireAbsoluteWorkspacesDir(value: string): string {
  if (!path.isAbsolute(value)) {
    throw new Error(`kfactory: KFACTORY_ADAPTER_WORKSPACES_DIR must be absolute: ${value}`)
  }
  return value
}

function workspacesDir(): string {
  return requireAbsoluteWorkspacesDir(
    process.env.KFACTORY_ADAPTER_WORKSPACES_DIR ?? "/var/lib/factory/workspaces",
  )
}

// ---- URL + slug helpers ----

// Slug shape: `<owner>--<repo>--<4hex>`. Suffix is either random
// (`randomBytes(2)`, 16-bit space) or a caller-supplied 4-hex naming
// hint from `extra.slugSuffix`. Segments use the git-forge name alphabet
// [A-Za-z0-9._] plus single hyphens, but a literal `--` inside a segment
// is rejected (assertSlugSafeSegment) so `--` is exclusively the
// delimiter -- which keeps both the grammar injective and the identity
// check exact. isValidSlug is the load-bearing path-traversal defense
// (no `/` in the alphabet => a slug is always one path component);
// rationale + decision in docs/spec.md's slug entry.
const SLUG_RE = /^[A-Za-z0-9._-]+--[A-Za-z0-9._-]+--[a-f0-9]{4}$/

function isValidSlug(name: string): boolean {
  return SLUG_RE.test(name)
}

// Parse owner + repo from a git URL. Handles https://, git@host:, and
// file:// forms. Hosted URLs must be exactly /owner/repo(.git); file://
// test fixtures use the final two path segments.
function parseOwnerRepo(repoUrl: string): {owner: string; repo: string} {
  const isFileURL = /^file:\/\//i.test(repoUrl)
  const rawPath = repoUrl
    .replace(/\.git$/, "")
    .replace(/^[a-z][a-z0-9+.-]*:\/\/[^/]*\/?/i, "") // strip scheme + host
    .replace(/^[^@/:]+@[^:/]+:/, "") // strip ssh user@host:
  const segments = path
    .normalize(rawPath)
    .split("/")
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
  if (segments.length < 2) {
    throw new Error(`kfactory: cannot parse owner/repo from: ${repoUrl}`)
  }
  if (!isFileURL && segments.length !== 2) {
    throw new Error(`kfactory: repo URL path must be exactly owner/repo: ${repoUrl}`)
  }
  const [owner, repo] = segments.slice(-2)
  assertSlugSafeSegment(owner!, "owner", repoUrl)
  assertSlugSafeSegment(repo!, "repo", repoUrl)
  return {owner, repo}
}

function assertSlugSafeSegment(segment: string, label: "owner" | "repo", repoUrl: string): void {
  // Single hyphens are fine; a literal `--` would alias the delimiter
  // and break the injective `<owner>--<repo>--<4hex>` decomposition.
  if (!/^[A-Za-z0-9._-]+$/.test(segment) || segment.includes("--")) {
    throw new Error(
      `kfactory: ${label} segment not representable in the slug grammar [A-Za-z0-9._-], no '--': ${repoUrl}`,
    )
  }
}

function assertSlugMatchesRepo(slug: string, repoUrl: string): void {
  const {owner, repo} = parseOwnerRepo(repoUrl)
  // Exact because segments carry no `--`: the prefix is unambiguous and
  // the trailing 4-hex is the mint suffix.
  const prefix = `${owner}--${repo}--`
  if (!slug.startsWith(prefix) || !/^[a-f0-9]{4}$/.test(slug.slice(prefix.length))) {
    throw new Error(
      `kfactory: workspace slug ${slug} does not match repo owner/repo ${owner}/${repo}`,
    )
  }
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
  // Present-but-invalid is a producer bug, not a reason to silently mint
  // a different workspace name.
  if (extra.slugSuffix !== undefined) {
    if (typeof extra.slugSuffix !== "string" || !/^[a-f0-9]{4}$/.test(extra.slugSuffix)) {
      throw new Error(`kfactory: extra.slugSuffix must be 4 lowercase hex characters`)
    }
    out.slugSuffix = extra.slugSuffix
  }
  return out
}

function buildWorkspaceSlug(info: Pick<WorkspaceInfo, "name" | "extra">): string {
  const {repoUrl, slugSuffix} = parseExtra(info)
  const {owner, repo} = parseOwnerRepo(repoUrl)
  const suffix = slugSuffix ?? randomBytes(2).toString("hex")
  return `${owner}--${repo}--${suffix}`
}

function workspaceDir(slug: string): string {
  return `${workspacesDir()}/${slug}`
}

function expectedWorkspaceDir(info: Pick<WorkspaceInfo, "name" | "directory">): string {
  if (!isValidSlug(info.name)) {
    throw new Error(`kfactory: invalid workspace slug: ${info.name}`)
  }
  const expected = workspaceDir(info.name)
  if (info.directory !== expected) {
    throw new Error(
      `kfactory: workspace directory mismatch for ${info.name}: ${info.directory} != ${expected}`,
    )
  }
  return expected
}

// Symlink-escape defense: resolves both `dir` and the configured root, then
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
    realRoot = await realpath(workspacesDir())
  } catch {
    realRoot = workspacesDir()
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
  const tmpDir = `${workspacesDir()}/.kfactory-clone-${slug}-${process.pid}-${randomBytes(4).toString("hex")}`
  await mkdir(workspacesDir(), {recursive: true})
  try {
    await new Promise<void>((resolve, reject) => {
      // `--` end-of-options sentinel: hygiene against URLs starting with
      // `-` (the operator is trusted, this isn't a security boundary).
      const p = spawn(GIT, ["clone", "--", repoUrl, tmpDir], {
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
    try {
      await rename(tmpDir, dir)
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === "EEXIST") {
        throw new Error(
          `kfactory: slug collision -- workspace dir ${dir} already exists. ` +
            `Re-run dispatch to mint a fresh slug.`,
        )
      }
      throw err
    }
  } catch (err) {
    // Re-validate before rm: defense in depth against path mutation.
    try {
      await assertWithinWorkspaces(tmpDir)
      await rm(tmpDir, {recursive: true, force: true})
    } catch (rmErr) {
      console.warn(
        `kfactory: cleanup of partial clone ${tmpDir} failed:`,
        rmErr instanceof Error ? rmErr.message : rmErr,
      )
    }
    throw err
  }
}

// ---- WorkspaceAdapter ----

export const KfactoryAdapter: Plugin = async ({experimental_workspace}) => {
  experimental_workspace.register("kfactory", {
    name: "kfactory",
    description: "kfactory: per-repo workspaces, in-process via InstanceStore",

    // isValidSlug here is the first slug-boundary check; catches any
    // future bug in the mint path before it pollutes the DB.
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
      expectedWorkspaceDir(info)
      assertSlugMatchesRepo(slug, repoUrl)
      await cloneRepoInto(slug, repoUrl)
    },

    async remove(info) {
      // Derive the path from `info.name` (the slug, source of identity),
      // NOT `info.directory` (looser sibling field, can drift across DB
      // mutations). assertWithinWorkspaces is belt-and-suspenders.
      // Propagate rm failures: opencode deletes the DB row AFTER remove()
      // resolves, so a swallowed error orphans the clone silently.
      const dir = expectedWorkspaceDir(info)
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
      return {type: "local", directory: expectedWorkspaceDir(info)}
    },
  })
  return {}
}

export default KfactoryAdapter
