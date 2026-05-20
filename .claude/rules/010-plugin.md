# Plugin editing (factory-adapter.ts)
<!-- .claude/rules/010-plugin.md -- at-signed substitution, typecheck, opencode bump watch -->

## Source layout

- `plugin/factory-adapter.ts` -- the WorkspaceAdapter source. Processed
  by `pkgs.replaceVars` at build time (in the consumer's NixOS config
  via `inputs.kfactory.lib.mkFactoryAdapter`): `@VAR@` literals inside
  the constants block near the top get replaced with absolute Nix store
  paths. checkPhase fails the build on any leftover `@xxx@` pattern, so
  every such pattern in this file must be one of the substituted names.
- `plugin/tsconfig.json` -- typecheck config (bundler module resolution,
  `skipLibCheck`, `noEmit`).
- `plugin/package.json` + `plugin/package-lock.json` -- type-only deps
  (`@types/node`, `@opencode-ai/plugin`) consumed by the
  `factory-plugin-typecheck` flake check. No runtime deps.

## Editing rule (HARD)

After editing `factory-adapter.ts`, run `nix flake check` (or specifically
`nix build .#checks.x86_64-linux.factory-plugin-typecheck`) before
declaring the change done. CI runs the same check on every push.

`@TOKEN@` placeholders are valid TS as-is (they sit inside string literals),
so the file is typecheck-clean without pre-substitution. The dedicated
constants block near the top is the ONLY place `@FOO@` patterns may
appear. Do NOT write `@TOKEN@` patterns anywhere else -- including inside
`@NOTE`/`@WARNING`/`@TODO` tag comments, JSDoc examples, or string
content outside the constants. `pkgs.replaceVars`'s checkPhase fails the
build on any leftover `@xxx@` pattern regardless of context.

## Watch upstream on every opencode bump

The typecheck catches WorkspaceAdapter SHAPE drift (we validate against
the published `@opencode-ai/plugin` types). Behavior changes are NOT
caught. Re-verify on every `flake.lock` bump of `opencode`:

- **`info.name` round-trip**: opencode persists what our `configure()`
  returns as `name` into the DB row, restored on every subsequent adapter
  call. If upstream stops persisting the configure-returned `name`,
  workspace identity gets re-minted on every load.
- **WorkspaceAdapter optional method set**: we don't implement `list?`.
  Typecheck catches added required methods; runtime semantics of
  optional methods need verification.
- **`?workspace=<id>` routing** in `workspace-routing.ts` -- the
  bearer-auth patch widens this to read the header on non-GET. If
  upstream changes the dispatch contract, re-check.

## Bumping deps

`plugin/package-lock.json` pins all type packages. To bump (e.g. follow
a new opencode release):

```bash
cd plugin
rm -rf node_modules package-lock.json
nix shell nixpkgs#nodejs_22 -c npm install --omit=dev --no-audit
nix shell nixpkgs#prefetch-npm-deps -c prefetch-npm-deps package-lock.json
# Paste the resulting sha256-... into flake.nix `npmDepsHash` for
# factory-plugin-typecheck, then `nix flake check` to confirm.
```

If `nix flake check` fails after a bump with type errors, that's the API
drift signal -- fix the adapter to match the new interface, do NOT pin
backwards to silence the failure.

## What we validate against (and why it's the published types)

The typecheck uses `@opencode-ai/plugin@<pinned-version>/dist/index.d.ts`,
fetched from npm into `node_modules/` by `buildNpmPackage`. NOT the
in-repo opencode source under `inputs.opencode`. This is deliberate:
the published `dist/index.d.ts` is opencode's public-API contract --
the WorkspaceAdapter shape opencode commits to maintaining for external
plugins. Source has additional internal fields (`list?`, `context?`
args on some methods, etc.) that aren't exposed publicly because
opencode reserves the right to change them between minor versions.
Validating against source would couple us to opencode's internals and
break on every minor bump.
