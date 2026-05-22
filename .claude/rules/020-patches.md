# Opencode patch stack
<!-- patches -- five-patch stack, picking which patch to edit -->

Five opencode patches are line-number-pinned against the
`inputs.opencode` flake input (the exact tag pinned in `flake.nix`).
Stack order is mandatory:

0. `patches/opencode-bun-version-relax.patch` -- **TEMPORARY**.
   Single-file (`packages/script/src/index.ts`) one-line change
   relaxing the bun-version range from `^${packageManager}` to
   `>=1.3.13` so nixpkgs's bun 1.3.13 can build opencode v1.15.5+.
   Drop when nixpkgs#519796 (bun 1.3.13 -> 1.3.14) merges. Lives at
   the top of the stack because it touches a file none of the other
   patches do; ordering doesn't actually matter for this one but it
   stays first by convention to keep the "drop me later" intent
   visible.
1. `patches/opencode-bearer-and-routing.patch` -- upstreamable subset:
   bearer flag, `--workspace` plumbing, workspace-routing header
   fallback (v1 + v2 path), `Session.list` + `Session.listGlobal`
   workspaceID filter (workspace_id supersedes project_id when set),
   plugin-adapter ProjectID.global registration.
2. `patches/opencode-workspace-branch.patch` -- upstreamable subset:
   `WorkspaceHttpApi.list` enriches each row's `branch` field with a
   FRESH `.git/HEAD` read at request time (via Effect.forEach +
   Effect.sync, concurrency unbounded). Independent file
   (handlers/workspace.ts) -- neither neighbour patch touches it.
3. `patches/opencode-session-subscribers.patch` -- publishes
   `kfactory.subscribers.changed` bus events on every SSE attach /
   detach to BOTH the per-instance `/event` AND the front-opencode
   `/global/event` (shared WeakMap exported from handlers/event.ts,
   imported by handlers/global.ts). Used by `plugins/ntfy` to skip /
   cancel notifications when an operator is attached.
4. `patches/opencode-kfactory-refresh.patch` -- kfactory-specific glue,
   applied on top: cache file, subprocess refresh, schema-versioned
   auth.json read, toast subscription. Line-pinned against patches
   1-3's post-apply hashes.

`patches/oauth2-proxy-pkce-no-secret.patch` is verbatim
[oauth2-proxy#3168](https://github.com/oauth2-proxy/oauth2-proxy/pull/3168);
typically untouched.

Editing any opencode patch by hand is fragile because every addition or
removal shifts hunk offsets; the safe path is to **always re-diff
against a fresh opencode source**.

## Picking which patch to edit

A change is in **bearer-and-routing** if it's something opencode upstream
would plausibly accept: env-var flag wiring, CLI flags on
`opencode attach`, workspace-id plumbing, header-routing semantics,
session.list filtering by workspace_id, plugin-adapter project scope.

A change is in **workspace-branch** if it touches
`WorkspaceHttpApi.list` row enrichment (today: live `branch` read
from `.git/HEAD`). Adding e.g. `dirty: bool` or `head: <sha>` to
list rows would belong here. Independent file; safe to edit in
isolation.

A change is in **session-subscribers** if it's about exposing SSE
subscriber lifecycle to plugins (the `kfactory.subscribers.changed`
event + the shared WeakMap counter that handlers/event.ts owns and
handlers/global.ts imports). Adding more plugin surface area for
"what's the server doing" signals belongs here.

A change is in **kfactory-refresh** if it's kfactory-specific: anything
touching `OPENCODE_SERVER_BEARER_CACHE_PATH`, `createBearerRefreshFetch`,
`spawnKfactoryRefresh`, `AuthFile`, `KFACTORY_EXIT_*`, the
`onBearerRefreshHint` toast bus.

When in doubt: edit the refresh patch. Keeping the upstreamable
patches (bearer-and-routing, workspace-branch, session-subscribers)
clean of kfactory specifics is what makes them upstreamable.

## Related rules

- **Re-diff workflow** (HARD; always re-diff, never hand-edit hunk
  headers): `.claude/rules/021-patches-rediff.md`.
- **Bumping the opencode pin** (incl. the hashes.json workaround):
  `.claude/rules/022-patches-bump.md`.

When adding a NEW patch to the stack, update this file's stack
description AND `021-patches-rediff.md`'s `TREES=`/`PATCHES=` arrays
together -- the names match by convention.
