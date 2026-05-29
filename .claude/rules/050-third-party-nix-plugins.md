# Third-party opencode plugins packaged through Nix (plugins/<name>/ carriers)
<!-- third-party-plugins -- carriers, packaging, bumping, smoke check -->

## Layout

Third-party opencode plugins kfactory ships live under `plugins/<name>/`
alongside kfactory's own plugins, but with a different shape:

```
plugins/
  opencode-pty/                   third-party carrier: NO upstream source
                                  in our tree. Just the manifest pair
                                  buildNpmPackage needs.
    package.json                  declares the third-party package as
                                  a dep at the desired version
    package-lock.json             machine-generated; locks every
                                  transitive version + integrity hash
```

The distinguishing feature is the directory's contents:
- kfactory-owned plugin -> has `src/`, `tsconfig.json`, real package.json
- third-party carrier -> ONLY `package.json` + `package-lock.json`

The actual third-party source comes from npm at `buildNpmPackage` time
and lands in `$out` of an internal package. See `flake.nix`'s
`mkThirdPartyPlugin` helper for the canonical wiring + the
`docs/spec.md` decision-log entry for the structural rationale (why a
carrier vs. fetchurl-closure vs. opencode-auto-install + why it lives
in `plugins/` next to kfactory-owned plugins).

Use this pattern when:
- An opencode plugin maintained by someone else solves a problem
  kfactory needs.
- The upstream is on npm under MIT-or-compatible.
- Vendoring source into a kfactory-owned `plugins/<name>/` would mean
  either taking on their build chain or carrying upstream diffs.

Do NOT use this pattern when:
- The plugin is small enough that a carve-out (in the style of
  `plugins/ntfy/`'s vendored MIT subset) is cleaner.
- The plugin is something kfactory itself maintains -- those go in
  `plugins/<name>/` with `src/` per `.claude/rules/010-plugin.md`.

## Adding a new third-party plugin

The shape is auto-registered: a single entry in `thirdPartyPluginSrcs`
creates an internal package, a generic `factory-<name>-smoke` flake check,
and the regression-tests opencode.json plugin-list entry. The only per-plugin
manual work is generating the carrier + lockfile (which needs network egress
and so happens out-of-sandbox).

1. Pick the npm package name + version. Confirm MIT (or
   AGPLv3-compatible) license; combining MIT-into-AGPLv3 is fine.
2. Make a carrier under `plugins/<name>/`:
   ```bash
   mkdir -p plugins/<name>
   cat > plugins/<name>/package.json <<EOF
   {
     "name": "kfactory-<name>-carrier",
     "version": "0.0.0",
     "private": true,
     "dependencies": {
       "<npm-package-name>": "<pinned-version>"
     }
   }
   EOF
   ```
3. Generate the lockfile (NON-SANDBOXED step -- requires network):
   ```bash
   cd plugins/<name>
   nix shell nixpkgs#nodejs_22 -c npm install --omit=dev --no-audit --ignore-scripts
   rm -rf node_modules        # we never commit node_modules
   ```
4. Compute the npm deps hash:
   ```bash
   nix shell nixpkgs#prefetch-npm-deps -c prefetch-npm-deps package-lock.json
   ```
5. Add the entry to `thirdPartyPluginSrcs` in `flake.nix` with the
   version, src path (`./plugins/<name>`), and npmDepsHash. If the npm
   package name differs from the local Nix attr name, set `packageName`
   too (for example `packageName = "@scope/pkg"`). Done -- the rest
   auto-registers:
   - internal package (via `mkThirdPartyPlugin`)
   - `factory-<name>-smoke` flake check (via `mkThirdPartyPluginSmoke` --
     a generic "import resolves + exposes >=1 export" gate; tightens
     to specific-export assertions can be added per-plugin as opt-in)
   - regression image and unified runtime default config pick it up from
     `thirdPartyPluginSrcs`
6. Document the addition in `docs/spec.md`'s decisions log (rationale
   + the runtime requirements -- prebuilt native binaries, install
   scripts, etc.).

## Bumping a third-party plugin

```bash
cd plugins/<name>
# Update the version in package.json.
nix shell nixpkgs#nodejs_22 -c bash -c 'rm -rf node_modules package-lock.json && npm install --omit=dev --no-audit --ignore-scripts && rm -rf node_modules'
nix shell nixpkgs#prefetch-npm-deps -c prefetch-npm-deps package-lock.json
# Paste the new sha256-... into thirdPartyPluginSrcs.<name>.npmDepsHash in flake.nix
nix build .#checks.x86_64-linux.<name>                 # confirms install
nix build .#checks.x86_64-linux.factory-<name>-smoke    # confirms layout
```

If `nix flake check` fails after a bump with runtime errors:
- Smoke-check failure = upstream changed `exports`, the entry point
  shape, or the dist layout. Read the upstream changelog before
  patching the installPhase.
- Install failure = a new transitive dep added an install script
  that needed network. Verify `npmInstallFlags = ["--ignore-scripts"]`
  is still set on the block.

Do NOT pin backwards to silence a smoke-check failure; either fix
the wiring or stay on the older version on purpose with a note.

## Install scripts and `--ignore-scripts`

`buildNpmPackage`'s `npmConfigHook` already passes `--ignore-scripts`
to its internal `npm ci` (nixpkgs `build-support/node/build-npm-package/
hooks/npm-config-hook.sh`). We pass it again explicitly via
`npmInstallFlags` for greppability. What this actually suppresses
depends on the dep tree -- for `@josxa/opencode-pty` it's
`msgpackr-extract`'s `node-gyp-build-optional-packages` resolver
(benign; runs again at runtime). It does NOT suppress `prepare`
hooks (those don't fire for tarball installs from the npm registry).

When introducing a new third-party plugin, check the lockfile for
`hasInstallScript: true` entries and note in the flake block which
scripts are being skipped + why that's safe.
