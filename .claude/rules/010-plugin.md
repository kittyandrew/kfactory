# Plugin editing (plugins/<name>/)
<!-- plugins -- editing, env vars, typecheck, lockfile bumps -->

## Layout

```
plugins/
  kfactory-adapter/             opencode WorkspaceAdapter (kfactory's own)
    package.json                @kfactory/kfactory-adapter; sets main +
                                exports["./server"] -> src/index.ts
    package-lock.json           typecheck-only deps (no runtime deps)
    tsconfig.json               typecheck config; include: src/**/*.ts
    src/index.ts                plugin source (KfactoryAdapter export)

  ntfy/                         ntfy.sh notification plugin
    package.json                @kfactory/ntfy; main + exports["./server"]
                                -> src/index.ts
    package-lock.json
    tsconfig.json
    src/index.ts                Plugin entry: event dispatch + wait + skip-on-connect
    src/backend.ts              ntfy HTTP send + content defaults
    src/config.ts               config parsing + shorthand-duration parser ("3s", "5m", "1h30m")
```

Each plugin is a self-contained npm package shape. Opencode's `PluginLoader`
resolves entries either as npm package names OR as file paths -- for our
deployment it sees an absolute store path (one of `plugins.<system>.<name>`
in `flake.nix`) and reads `package.json`'s `exports["./server"]` to find
the entrypoint. opencode runs Bun under the hood, so TS source is loaded
directly -- no compile step required.

## No `@VAR@` placeholders anymore

Earlier plugins used `pkgs.replaceVars` to substitute `@GIT@` etc. with
absolute Nix store paths at build time. That's gone. Plugins now read
config from `process.env.*` with sensible defaults (PATH-resolved binaries
where applicable). Consumers wrap opencode with the env vars they need:

```nix
opencode-kfactory.overrideAttrs (old: {
  postFixup = (old.postFixup or "") + ''
    wrapProgram $out/bin/opencode \
      --set KFACTORY_ADAPTER_GIT "${pkgs.git}/bin/git" \
      --set KFACTORY_ADAPTER_OPENSSH_SSH "${pkgs.openssh}/bin/ssh" \
      --set KFACTORY_ADAPTER_WORKSPACES_DIR "/var/lib/factory/workspaces"
  '';
})
```

If you find yourself reaching for `@VAR@` substitution again, push back:
env vars + sensible defaults are the kfactory convention.

## Editing rule (HARD)

After editing any plugin source, run `nix flake check` (or specifically
`nix build .#checks.x86_64-linux.<name>-typecheck`) before declaring the
change done. CI runs the same check on every push.

For changes that touch multiple plugins, run `nix flake check` once at
the end -- it builds every plugin + typecheck in one shot.

## Vendored code (plugins/ntfy/)

`plugins/ntfy/` carves out only the bits needed for ntfy.sh from two
upstream projects (both MIT, both by Anthony Lannutti):

- `opencode-ntfy.sh @ 6a8d93d9` -- ntfy HTTP backend.
- `opencode-notification-sdk @ a5bd684d` -- event routing + subagent
  suppression + config schema.

The full MIT license text + Anthony's copyright notice are inlined at
the top of EVERY vendored source file (MIT's "permission notice shall
be included" requirement). Below that block in each file: SPDX
identifier, upstream commit pins, and the "kfactory modifications"
section. There is NO separate LICENSE-MIT file -- the per-file headers
ARE the notice. Project-level LICENSE stays AGPLv3; the inlined MIT
notices govern only the vendored content. AGPLv3 is more restrictive
than MIT, so combining is fine in this direction.

If you carry an upstream bugfix or feature into this repo, update the
commit pins AND mention the upstream change in the "kfactory
modifications" section so the diff against upstream stays greppable.

## Bumping plugin deps

Plugins have no runtime deps today (opencode supplies `@opencode-ai/plugin`
at runtime). Lockfiles exist for the typecheck only. To bump:

```bash
cd plugins/<name>
rm -rf node_modules package-lock.json
nix shell nixpkgs#nodejs_22 -c npm install --omit=dev --no-audit
nix shell nixpkgs#prefetch-npm-deps -c prefetch-npm-deps package-lock.json
# Paste the resulting sha256-... into pluginSrcs.<name>.npmDepsHash
# in flake.nix and rerun `nix flake check`.
```

If `nix flake check` fails after a bump with type errors, that's the API
drift signal -- fix the plugin to match the new interface, do NOT pin
backwards to silence the failure.

## What we validate against

The typecheck uses `@opencode-ai/plugin@<pinned-version>/dist/index.d.ts`,
fetched from npm into the plugin's `node_modules/` by `buildNpmPackage`.
This is opencode's PUBLIC plugin contract -- the WorkspaceAdapter /
Hooks / PluginInput shape opencode commits to maintaining across minor
versions. Validating against opencode source would couple us to its
internals and break on every minor bump.
