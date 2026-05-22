// KfactoryAdapter — opencode workspace adapter for the kfactory deployment.
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
// Configuration (env vars, all optional with sane defaults):
//   - KFACTORY_ADAPTER_GIT             path to git   (default: "git", PATH-resolved)
//   - KFACTORY_ADAPTER_OPENSSH_SSH     path to ssh   (default: "ssh", PATH-resolved)
//   - KFACTORY_ADAPTER_WORKSPACES_DIR  workspaces root
//                                      (default: "/var/lib/factory/workspaces")
//
// @WARNING: the PATH-resolved defaults work in interactive shells but
//    FAIL under systemd User= units, which sanitize PATH down to a
//    minimal coreutils/findutils/grep set. If you're running opencode
//    under systemd, ALWAYS set KFACTORY_ADAPTER_GIT and
//    KFACTORY_ADAPTER_OPENSSH_SSH to absolute Nix store paths -- the
//    OPENCODE_SERVE wrapper in flake.nix's `opencode-kfactory` does
//    this automatically; bare consumers must do it themselves.
//
// Consumers using Nix typically wrap opencode with these env vars set to
// absolute store paths (`${pkgs.git}/bin/git`, `${pkgs.openssh}/bin/ssh`,
// etc.) so the adapter never relies on the runtime PATH.
//
// @WARNING: opencode's WorkspaceAdapter API is EXPERIMENTAL (gated by
//    OPENCODE_EXPERIMENTAL_WORKSPACES). Pin opencode version in flake.nix;
//    watch upstream for breaking changes to control-plane/types.ts
//    WorkspaceAdapter signature. The `factory-opencode-patch-applies` flake
//    check catches patch-against-source drift; the per-plugin typecheck
//    check catches type-shape drift.
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

// The plugin passes repoUrl verbatim to `git clone`. Auth + URL form are
// the consumer's responsibility: whatever URL `kfactory dispatch` accepts
// must be resolvable by the running host's ssh-agent / ~/.ssh/config /
// git credential helper. SSH, https, and any git-supported scheme are
// fine; the plugin does not canonicalize or filter by hosting service.

// Slug shape: `<owner>--<repo>--<4hex>`. Asserted at every boundary
// that concatenates the slug into a filesystem path (configure mints,
// create uses, target dispatches, remove deletes) so a malformed
// `info.name` -- DB corruption, a future migration bug, a path-
// injection in extra.repoUrl that slipped through parseOwnerRepo --
// can't escape workspaces dir.
//
// The 4-hex suffix is either:
//   - random via `randomBytes(2).toString("hex")` for ad-hoc dispatches
//     (16-bit collision space, plenty at ~10 workspaces);
//   - or a deterministic task-id from `extra.slugSuffix`, used by
//     `kfactory tick <task-id>` so scheduled-task workspaces have a
//     predictable slug that survives across opencode restarts. The CLI
//     constrains task-ids to `[a-f0-9]{4}` (cmd/kfactory/tick.go +
//     modules/scheduled-tasks.nix) so the tight invariant holds end-
//     to-end -- the regex below is the load-bearing assertion that
//     catches any drift.
//
// Segments use only [A-Za-z0-9._] -- no hyphens within a segment, so
// the `--` delimiter is unambiguous. Hyphens were previously permitted
// via `[^/]+`, which silently accepted slugs like `foo--bar--baz--abcd`
// (4 segments separated by `--`) whose round-trip semantics were
// undefined. sanitizeSlugSegment now collapses hyphens to underscores,
// matching the regex below.
const SLUG_RE = /^[A-Za-z0-9._]+--[A-Za-z0-9._]+--[a-f0-9]{4}$/

function isValidSlug(name: string): boolean {
  return SLUG_RE.test(name)
}

// Extract owner + repo from a git URL. Handles:
//   - https://host/owner/repo(.git)?
//   - git@host:owner/repo(.git)?
//   - file:///path/to/repo(.git)?
//   - https://host/group/subgroup/repo(.git)?  (GitLab subgroups)
//   - git@host:group/subgroup/.../repo(.git)?
//
// For nested-path forms (GitLab subgroups, Gitea orgs-with-paths) the
// intermediate segments collapse into the `owner` field, joined with `_`
// to keep slug shape `<owner>--<repo>--<4hex>` intact. So:
//   gitlab.com/group/subgroup/repo  ->  owner="group_subgroup", repo="repo"
// Two dispatches against different parent orgs sharing a subgroup name
// still produce distinct slugs.
//
// Path-traversal segments (`..`) and empty segments are dropped.
// Remaining segments are sanitized to keep the slug regex-clean: any
// run of `--` collapses to `_` (preserves our delimiter), and
// non-[a-zA-Z0-9._-] becomes `_`.
//
// Throws on input that can't be reduced to at least two path segments
// (no owner OR no repo). E.g. `https://host/` rejects cleanly.
function parseOwnerRepo(repoUrl: string): {owner: string; repo: string} {
  // Normalize to a path string. Strip:
  //   - any scheme (`https://`, `file://`, etc.)
  //   - the SSH `user@host:` prefix
  //   - a trailing `.git`
  // Anything that survives is the path part.
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

// Keep slug segments clean: drop any character outside [A-Za-z0-9._] to
// `_`. Hyphens included -- the SLUG_RE delimiter is `--`, so allowing
// hyphens inside segments would create ambiguity (e.g. `foo-bar--baz`
// could be parsed as one segment or two). Strip them.
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
  // Optional caller-supplied slug suffix (used by `kfactory tick` to
  // mint deterministic slugs that survive across opencode restarts).
  // Must match the EXACT shape of the random-mint suffix: 4 hex chars.
  // Anything else is silently dropped -- the random-suffix fallback
  // in buildWorkspaceSlug kicks in. The CLI rejects malformed task-
  // ids loudly before we ever see them; this regex is the boundary
  // defense for direct API callers / future migrations.
  if (typeof extra.slugSuffix === "string" && /^[a-f0-9]{4}$/.test(extra.slugSuffix)) {
    out.slugSuffix = extra.slugSuffix
  }
  return out
}

// Slug shape: `<owner>--<repo>--<4hex>`. Random suffix lets the operator
// stand up multiple workspaces against the same repo without specifying a
// branch up-front (the worker `git checkout`s any branch once cloned).
// 16-bit collision space is plenty at ≤10 workspaces.
//
// Durability: opencode persists configure()'s returned `info.name` and
// passes it back on subsequent adapter calls. If `info.name` already
// matches our slug shape we short-circuit -- the slug carries identity,
// extra.repoUrl is only required for the FIRST mint and for create().
// This matters because configure() re-runs on every adapter call; if a
// later call sees `extra` nulled (DB round-trip dropped it, schema
// change, etc.) we still must return the existing slug or workspace
// identity would re-mint and target() would point at a fresh empty dir.
function buildWorkspaceSlug(info: Pick<WorkspaceInfo, "name" | "extra">): string {
  // Short-circuit MUST use the SAME predicate as every downstream
  // boundary (target / create / remove). An earlier shape used a looser
  // regex here ([^/]+--[^/]+--[a-f0-9]{4}) which admitted hyphens,
  // spaces, `..`, etc. -- those persisted into the DB row, then died
  // at the next dispatch when isValidSlug rejected them, leaving the
  // workspace permanently un-dispatch-able. Routing the short-circuit
  // through isValidSlug closes that asymmetry.
  if (info.name && isValidSlug(info.name)) {
    return info.name
  }
  const {repoUrl, slugSuffix} = parseExtra(info)
  const {owner, repo} = parseOwnerRepo(repoUrl)
  // `slugSuffix` lets the caller (typically `kfactory tick` for a
  // scheduled task) mint a deterministic slug so the workspace is
  // discoverable by suffix across opencode restarts. Without it,
  // randomBytes(2).toString("hex") gives a 4-hex random suffix (16-bit
  // collision space; plenty at <=10 workspaces per repo). When
  // supplied, the SLUG_RE assert at every downstream boundary (the
  // top-of-file invariant) catches a malformed suffix here -- but
  // parseExtra already gates on the regex character class, so this
  // path is the suffix-shape-correct branch by construction.
  const suffix = slugSuffix ?? randomBytes(2).toString("hex")
  return `${owner}--${repo}--${suffix}`
}

function workspaceDir(slug: string): string {
  return `${WORKSPACES_DIR}/${slug}`
}

// Boundary check for any rm-recursive against a workspace path. Resolves
// the symlink chain on `dir` AND on WORKSPACES_DIR, then verifies the
// resolved `dir` lives under the resolved root. Cheap (~2 lstat
// syscalls). What it actually guards against:
//
//   - Symlink escape: if `workspaces/<slug>` is a symlink pointing at
//     /etc, realpath resolves it; the prefix compare then fails. THIS
//     is the protection this function provides.
//
// What it does NOT guard against (and does not need to, given current
// callers): path traversal via `..` or other non-workspace characters
// inside the slug. EVERY caller routes the slug through `isValidSlug`
// FIRST (regex `^[A-Za-z0-9._]+--[A-Za-z0-9._]+--[a-f0-9]{4}$`), which
// rejects `/`, `..`, hyphens, etc. before `dir` is constructed. The
// slug regex is therefore the LOAD-BEARING defense against path
// traversal; assertWithinWorkspaces is the load-bearing defense
// against symlink escape. Don't remove either without checking the
// other.
//
// ENOENT fallback: if realpath fails (dir or some parent doesn't
// exist), we use the literal-prefix compare instead. Given the slug
// regex above, `dir` is always `WORKSPACES_DIR + "/" + <regex-clean>`
// so the literal compare is trivially true -- the fallback exists
// only so a missing workspaces root on first deployment doesn't make
// the whole function throw. It is NOT an independent layer of
// path-traversal defense; that role belongs to the slug regex.
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
    // Workspaces dir doesn't exist yet (fresh deployment) -- fall back to
    // a literal-prefix compare against the configured value. Won't catch
    // symlink-based escape but the workspaces dir itself isn't a symlink
    // until an operator makes it one.
    realRoot = WORKSPACES_DIR
  }
  // If realpath succeeded, use the resolved path (catches symlinks).
  // Otherwise, use the original string -- still catches path traversal
  // via the slug regex check that runs in the caller, plus the
  // literal-prefix comparison below.
  const probe = realDir ?? dir
  // Trailing slash on root prevents /a/b/c being treated as under /a/b
  // when /a/b-other was the real prefix.
  if (probe !== realRoot && !probe.startsWith(realRoot + "/")) {
    throw new Error(
      `kfactory: refusing to operate on ${dir} (resolved: ${probe}) -- outside ${realRoot}`,
    )
  }
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
  if (!isValidSlug(slug)) {
    throw new Error(`kfactory: refusing to clone with invalid slug: ${slug}`)
  }
  const dir = workspaceDir(slug)
  // Ensure WORKSPACES_DIR exists (idempotent); then create the workspace
  // dir itself ATOMICALLY -- with recursive:false, mkdir throws EEXIST
  // when the dir is already there. That's how we tell "we created it"
  // from "someone else owns it" without a TOCTOU race against existsSync.
  // The 4-hex slug suffix gives 16-bit collision space (birthday at
  // ~256); colliding with an existing workspace is a hard error here,
  // not a silent overwrite. Persistence contract (docs/spec.md §5):
  // workspace data is never auto-deleted; only a slug freshly created
  // by this invocation may be removed on failure.
  await mkdir(WORKSPACES_DIR, {recursive: true})
  let createdHere = false
  try {
    await mkdir(dir, {recursive: false})
    createdHere = true
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err
    // EEXIST: another invocation owns this slug. Refuse to clone into
    // it. The caller should re-mint a slug and retry; configure()'s
    // random-suffix path handles this on the next attempt.
    throw new Error(
      `kfactory: slug collision -- workspace dir ${dir} already exists. ` +
        `Re-run dispatch to mint a fresh slug.`,
    )
  }
  try {
    await new Promise<void>((resolve, reject) => {
      // `--` end-of-options sentinel: forces git to treat repoUrl as a
      // positional arg regardless of leading dashes. The operator is
      // trusted under the threat model (docs/spec.md §1), so this isn't
      // a security guard -- it's hygiene against typoed URLs that start
      // with `-`, accidental `--upload-pack=...`-shaped arguments, and
      // future call sites that might pipe less-trusted input through.
      const p = spawn(GIT, ["clone", "--", repoUrl, "."], {
        cwd: dir,
        env: {
          ...process.env,
          GIT_TERMINAL_PROMPT: "0",
          GIT_SSH_COMMAND: `${OPENSSH_SSH} -o StrictHostKeyChecking=accept-new`,
        },
      })
      let stderr = ""
      // `error` fires when spawn itself fails BEFORE the child runs --
      // e.g. ENOENT because GIT isn't on PATH. Without this listener,
      // Node emits the error event into the void, `close` never fires,
      // and the awaiting CLI hangs forever. The systemd-service-PATH
      // sanitization case (typical NixOS deployment: User= service
      // strips PATH down to a minimal set without git) makes this the
      // realistic failure mode.
      p.on("error", reject)
      p.stderr.on("data", (c) => (stderr += c))
      p.on("close", (code) => {
        if (code === 0) resolve()
        else reject(new Error(`git clone exit ${code}: ${stderr}`))
      })
    })
  } catch (err) {
    if (createdHere) {
      // Only roll back the dir if this invocation created it. Re-validate
      // the path is under WORKSPACES_DIR before rm -- defense in depth
      // against future code paths that might mutate `dir` mid-clone.
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

    // `info.name` round-trips: opencode generates a random `Slug.create()`
    // value BEFORE configure() (workspace.ts) and then persists what we
    // return as `name` into the DB row. Subsequent configure() calls
    // restore that persisted name. buildWorkspaceSlug preserves an
    // existing slug if it matches our shape; mints fresh otherwise.
    configure(info) {
      const slug = buildWorkspaceSlug(info)
      // configure() mints (or preserves) the slug that opencode
      // persists into the DB row -- it's the FIRST boundary in the
      // top-of-file "asserted at every boundary that concatenates the
      // slug into a filesystem path" promise. buildWorkspaceSlug is
      // supposed to return a valid slug, but assert here too so any
      // future bug in the mint path (parseOwnerRepo edge case,
      // sanitizeSlugSegment regression, etc.) fails loudly here
      // instead of polluting the DB with a slug that dies at the next
      // dispatch.
      if (!isValidSlug(slug)) {
        throw new Error(
          `kfactory: configure() produced invalid slug: ${slug}`,
        )
      }
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
      if (!repoUrl) throw new Error(`kfactory: extra.repoUrl is required`)
      await cloneRepoInto(slug, repoUrl)
    },

    async remove(info) {
      // Persistence contract (docs/spec.md §5): workspace data is never
      // AUTO-deleted by agents or boot paths; only the operator can
      // delete. opencode reaches remove() only via DELETE
      // /experimental/workspace/<id> -- explicitly operator-initiated
      // (today, via `kfactory delete <id|slug|#>`), so wiping the on-disk
      // clone here matches the contract.
      //
      // Trust boundary: `info.name` is the slug; `info.directory` is a
      // looser sibling field that can drift (DB mutation, future opencode
      // bug, etc.). The slug IS the workspace identity per our design.
      // Derive the path from the slug directly via workspaceDir, ignoring
      // info.directory for the rm path. info.directory is for logging
      // only. assertWithinWorkspaces is belt-and-suspenders against a
      // future change to workspaceDir or WORKSPACES_DIR mid-process.
      if (!isValidSlug(info.name)) {
        throw new Error(
          `kfactory: refusing to remove workspace with invalid slug: ${info.name}`,
        )
      }
      const dir = workspaceDir(info.name)
      await assertWithinWorkspaces(dir)
      // Propagate rm failures: opencode hasn't deleted the DB row yet at
      // this point (its WorkspaceTable.delete fires after remove resolves).
      // A loud throw keeps DB and disk consistent; a swallowed error
      // orphans the clone with no operator-visible signal.
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
      // `local`: opencode dispatches the request via
      // `InstanceStore.provide({directory}, effect)` in the SAME process.
      // No HTTP proxy. No worker process. No port allocation. The path
      // workspace-routing.ts:planRequest takes for `local` targets.
      //
      // Re-validate the slug here too: opencode calls target() on EVERY
      // dispatched request, so a corrupted `info.name` (DB mutation,
      // future migration bug) would otherwise root an in-process
      // InstanceStore context at an attacker-influenced path. The
      // top-of-file comment claims "asserted at every boundary that
      // concatenates the slug into a filesystem path"; target() is one
      // of those boundaries.
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
