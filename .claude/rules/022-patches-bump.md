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
   times). kfactory routes around it via a `.override { node_modules =
   ... }` block in `flake.nix`'s patched opencode construction. Refresh the
   embedded hash literal:
   ```bash
   nix build .#checks.x86_64-linux.factory-opencode-kfactory 2>&1 | awk '/got:/ {print $2}'
   ```
   Paste the resulting `sha256-...` into the `hash = "...";` argument
   of the `node_modules_updater.override` call. The override is
   **single-platform** (x86_64-linux only); if kfactory ever ships
   aarch64-linux or darwin builds, expand to a platform-keyed attrset
   matching `hashes.json`'s shape.
   When upstream eventually publishes a release with correct hashes,
   remove the entire `.override { node_modules = ... }` block. Verify
   by deleting the override locally, re-running
   `nix build .#checks.x86_64-linux.factory-opencode-kfactory`, and confirming
   it succeeds without a hash error.
5. The plugin typechecks use the published `@opencode-ai/plugin` types,
   not the source, so they're independent of this bump.
6. `factory-opencode-typecheck` catches type-semantic drift across any
   of the kfactory opencode patches against the bumped source.

## What to verify on every edit

- `nix flake check` -- in particular the kfactory opencode patches
  must all pass `factory-opencode-patch-applies` AND the resulting
  tree must pass `factory-opencode-typecheck`.
- For changes to the subprocess-refresh logic in `attach.ts`: verify
  the spawned binary name still matches the binary you ship (today:
  `spawn("kfactory", ["auth", "refresh"])`) and that the exit-code
  constants stay in sync with `cmd/kfactory/exit.go`.
