# Bumping the opencode pin
<!-- patches-bump -- bumping playbook, hashes.json workaround, verify -->

Stack identity: `.claude/rules/020-patches.md`. Re-diff workflow:
`.claude/rules/021-patches-rediff.md`.

## Playbook

1. Edit `flake.nix`'s `inputs.opencode.url` to the new tag.
2. `nix flake update opencode` to refresh the lock.
3. `nix flake check`. If `factory-opencode-patch-applies` fails, the
   patches' line numbers drifted -- re-diff per the workflow in
   `021-patches-rediff.md`.
4. If `nix flake check` produces a `hash mismatch in fixed-output
   derivation 'opencode-node_modules-<version>'`, upstream's
   `nix/hashes.json` is stale for this tag -- a recurring upstream CI
   race (anomalyco/opencode#18227 has been fixed and re-broken multiple
   times; it last bit kfactory at v1.15.11 and was fixed upstream by
   v1.17.4). The workaround, if it recurs: wrap the patched opencode's
   base package in `nix/shared/opencode-components.nix` with
   ```nix
   (opencode.packages.${system}.default.override {
     node_modules = opencode.packages.${system}.node_modules_updater.override {
       hash = "sha256-<got-hash>";
     };
   })
   ```
   where `<got-hash>` comes from
   `nix build .#checks.x86_64-linux.factory-opencode-kfactory 2>&1 | awk '/got:/ {print $2}'`.
   The override is **single-platform** (x86_64-linux only); expand to a
   platform-keyed attrset matching `hashes.json`'s shape if kfactory
   ever ships other systems. Remove the override again as soon as a
   later upstream tag publishes correct hashes (verify by deleting it
   and rebuilding `factory-opencode-kfactory`).
5. Bump the `@opencode-ai/plugin` pin in each `plugins/<name>/package.json`
   to the new opencode version, regenerate lockfiles + `npmDepsHash`
   per `.claude/rules/010-plugin.md` -- the published types are
   versioned in lockstep with opencode releases.
6. `factory-opencode-typecheck` catches type-semantic drift across any
   of the kfactory opencode patches against the bumped source. Its
   baseline (`checks/factory-opencode-typecheck.baseline`) holds the
   known upstream noise; expect it to churn on big upstream refactors.
7. The replay fixture gate (`nix/replay/default.nix`) throws on any
   version mismatch BY DESIGN. Re-derive
   `nix/replay/opencode-heal/fixtures/<version>/schema.sql` against the
   new source (`generate-fixtures.sh` validates the cited migrations
   still exist), review consumed-surface drift for the heal tables
   (session/message/part/session_message), rename the fixtures dir,
   and update `fixtureVersion` + the schema path in
   `nix/replay/default.nix`.
8. Read every NEW upstream DB migration in the bump range for
   destructive statements against state kfactory consumes (workspace
   rows, session.workspace_id, v1 message/part tables). The runtime
   executes the TS modules in
   `packages/core/src/database/migration/`; the sibling SQL bodies in
   `packages/core/migration/<name>/migration.sql` mirror them and are
   the easier review surface. Destructive migrations become documented
   operator actions, never carve-out patches -- policy + the v1.16.0
   precedent live in docs/spec.md's v1.17.4 bump decisions entry.

## What to verify on every edit

- `nix flake check` -- in particular the kfactory opencode patches
  must all pass `factory-opencode-patch-applies` AND the resulting
  tree must pass `factory-opencode-typecheck`.
- For changes to the subprocess-refresh logic
  (`packages/core/src/kfactory-bearer-refresh.ts` in the refresh
  patch): verify the spawned binary name still matches the binary you
  ship (today: `spawn("kfactory", ["auth", "refresh"])`) and that the
  exit-code constants stay in sync with `cmd/kfactory/exit.go`.
- Re-audit `ServerAuth.header()` callers in the bumped source:
  `bearerFromCache` throws on a broken cache, so any NEW upstream
  call site reachable with `OPENCODE_SERVER_BEARER_CACHE_PATH` set
  widens the blast radius (the refresh patch header records the
  v1.17.4 caller set).
