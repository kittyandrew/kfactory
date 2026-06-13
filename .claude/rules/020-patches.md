# Opencode patch stack
<!-- patches -- opencode patch stack, picking which patch to edit -->

Four opencode patches are line-number-pinned against the
`inputs.opencode` flake input (the exact tag pinned in `flake.nix`).
Stack order is mandatory:

0. `patches/opencode-bun-version-relax.patch` -- build workaround.
   Single-file (`packages/script/src/index.ts`) one-line change
   relaxing the bun-version range from `^${packageManager}` to
   `>=1.3.13` so nixpkgs's bun 1.3.13 can build opencode (upstream
   pins bun 1.3.14). Drop when nixpkgs#519796 (bun 1.3.13 -> 1.3.14)
   merges. Keep first for easy removal; no later patch depends on its
   touched file.
1. `patches/opencode-static-bearer.patch` -- env-only client Bearer
   plumbing: `OPENCODE_SERVER_BEARER` makes `ServerAuth.header()` emit
   Bearer instead of Basic. No CLI flag. Server-side opencode still
   does not validate Bearer.
2. `patches/opencode-workspace-routing.patch` -- upstreamable workspace
   correctness subset: `--workspace` plumbing (attach command +
   packages/tui providers), workspace-routing header fallback (v1 + v2
   path), `Session.list` + service `listGlobal` workspaceID filter
   (workspace_id supersedes project_id when set), `/sync/start?workspace=`,
   plugin-adapter `ProjectV2.ID.global` registration/fallback, and
   workspace lifecycle correctness (create-failure row cleanup,
   remove() fail-closed ordering).
3. `patches/opencode-kfactory-refresh.patch` -- kfactory-specific glue,
   applied on top: cache file, subprocess refresh, schema-versioned
   auth.json read, toast subscription. Adds the NEW module
   `packages/core/src/kfactory-bearer-refresh.ts` (placement rationale
   in the module header). Line-pinned against patches 1+2's post-apply
   hashes.

`patches/oauth2-proxy-pkce-no-secret.patch` is verbatim
[oauth2-proxy#3168](https://github.com/oauth2-proxy/oauth2-proxy/pull/3168);
typically untouched.

Editing any opencode patch by hand is fragile because every addition or
removal shifts hunk offsets; the safe path is to **always re-diff
against a fresh opencode source**.

## Picking which patch to edit

A change is in **static-bearer** if it is generic client-side Bearer
plumbing: `OPENCODE_SERVER_BEARER` or `ServerAuth.header()` returning
`Bearer ...`.

A change is in **workspace-routing** if it is workspace correctness
opencode upstream would plausibly accept: CLI flags on `opencode attach`,
workspace-id plumbing through `packages/tui` providers, header-routing
semantics, session list filtering by workspace_id, sync-start workspace
targeting, plugin-adapter project scope, workspace create/remove
lifecycle ordering, and the routing middleware in
`server/routes/instance/httpapi/middleware/`.

A change is in **kfactory-refresh** if it's kfactory-specific: anything
touching `OPENCODE_SERVER_BEARER_CACHE_PATH`,
`packages/core/src/kfactory-bearer-refresh.ts` (createBearerRefreshFetch,
spawnKfactoryRefresh, AuthFile, KFACTORY_EXIT_*, onBearerRefreshHint),
or `bearerFromCache` in `packages/opencode/src/server/auth.ts`.

When in doubt: edit the refresh patch. Keeping static-bearer and
workspace-routing clean of kfactory specifics is what makes them easier
to upstream or delete independently.

Patches are NOT the place for migration carve-outs or other
deployment-transition shims -- policy + precedent in docs/spec.md's
v1.17.4 bump decisions entry.

## Related rules

- **Re-diff workflow** (HARD; always re-diff, never hand-edit hunk
  headers): `.claude/rules/021-patches-rediff.md`.
- **Bumping the opencode pin** (incl. the hashes.json history):
  `.claude/rules/022-patches-bump.md`.

When adding a NEW patch to the stack, update this file's stack
description AND `021-patches-rediff.md`'s `TREES=`/`PATCHES=` arrays
together -- the names match by convention.
