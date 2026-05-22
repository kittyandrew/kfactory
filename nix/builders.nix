# Plugin + third-party-plugin Nix builders.
#
# Extracted from flake.nix to keep the top-level outputs block under
# the 1k-line rule. These helpers are pure: they take a `pkgs` arg
# plus a spec attrset and return a derivation. No reference to `self`
# or `inputs` -- consume them by passing `pkgs` from the caller.
#
# Usage:
#   let builders = import ./nix/builders.nix;
#       pkg      = builders.mkPlugin pkgs { name = "x"; src = ./...; npmDepsHash = "..."; };
{
  # mkPlugin -- buildNpmPackage wrapper for kfactory plugins. Plugins
  # under plugins/<name>/ each have:
  #   - package.json + package-lock.json (typecheck deps; no runtime deps
  #     today since opencode supplies @opencode-ai/plugin at load time)
  #   - tsconfig.json (typecheck config)
  #   - src/*.ts (loaded directly by opencode via Bun's TS runtime)
  #   - optional LICENSE-MIT for vendored upstream code
  #
  # The result store path contains the full package tree (src/, node_modules/,
  # package.json) so consumers can either point opencode at the directory
  # (Bun resolves `exports["./server"]`) or at a specific file inside.
  mkPlugin = pkgs: {
    name,
    src,
    npmDepsHash,
  }:
    pkgs.buildNpmPackage {
      pname = "kfactory-plugin-${name}";
      version = "0.0.1";
      inherit src npmDepsHash;
      # No compile step: plugins ship as .ts and Bun loads them directly.
      # See research note in docs/spec.md decisions log re: opencode's
      # PluginLoader -- it `await import()`s the entrypoint, and Bun's
      # runtime transpiles TS on the fly.
      dontNpmBuild = true;
      # `npm ci` (which buildNpmPackage runs in install) populates
      # node_modules/. We copy the whole package tree to $out so consumers
      # can either reference $out/src/<entrypoint>.ts directly or point
      # opencode at $out (which resolves via package.json's exports).
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -r . $out/
        # Drop nix-specific files that the operator doesn't need at runtime
        rm -rf $out/node_modules/.package-lock.json
        runHook postInstall
      '';
    };

  # mkPluginTypecheck -- same wrapper, but runs `tsc --noEmit` and emits
  # only a marker file. Separate from mkPlugin so the plugin build itself
  # is fast (no tsc compile time) and the typecheck is its own gated check.
  mkPluginTypecheck = pkgs: {
    name,
    src,
    npmDepsHash,
  }:
    pkgs.buildNpmPackage {
      pname = "kfactory-plugin-${name}-typecheck";
      version = "0";
      inherit src npmDepsHash;
      dontNpmBuild = true;
      buildPhase = ''
        runHook preBuild
        npx tsc --noEmit
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        touch $out
        runHook postInstall
      '';
    };

  # mkThirdPartyPlugin -- buildNpmPackage wrapper for third-party
  # opencode plugins pinned through a `plugins/<name>/` carrier
  # (manifest-only: package.json + package-lock.json, no src/).
  # Unlike mkPlugin (which packages kfactory's own plugin source
  # under plugins/<name>/src/), this builder installs from an npm
  # registry tarball via the carrier's lockfile, promotes the
  # third-party package itself to $out, and hoists its runtime
  # deps into $out/node_modules so opencode's PluginLoader can
  # resolve them. Both flavours of plugin live under plugins/;
  # which helper builds them is decided by which registry
  # (pluginSrcs vs. thirdPartyPluginSrcs) holds the entry.
  #
  # See .claude/rules/050-third-party-nix-plugins.md for the bump
  # workflow and docs/spec.md's decisions-log entry for the
  # structural rationale (carrier vs. fetchurl-closure vs.
  # opencode-auto-install).
  #
  # `npmInstallFlags = ["--ignore-scripts"]` is redundant with
  # buildNpmPackage's `npmConfigHook` (which already hardcodes
  # --ignore-scripts into its internal `npm ci`) but kept explicit
  # for greppability. The script it actually suppresses depends on
  # the dep tree -- for opencode-pty it's msgpackr-extract's
  # node-gyp-build-optional-packages resolver (benign; runs again
  # at runtime). It does NOT suppress `prepare` hooks (those don't
  # fire for tarball installs from the npm registry).
  mkThirdPartyPlugin = pkgs: {
    name,
    version,
    src,
    npmDepsHash,
  }:
    pkgs.buildNpmPackage {
      pname = name;
      inherit version src npmDepsHash;
      npmInstallFlags = ["--ignore-scripts"];
      dontNpmBuild = true;
      # Promote the third-party package's own files to $out, hoist
      # its sibling deps to $out/node_modules. `shopt -s dotglob` so
      # any dotfiles the upstream tarball ships move with the
      # non-dotfiles -- a separate `.[!.]*` glob would exit 1 under
      # `set -eu` if there are no dotfiles, breaking installs for
      # packages that ship none.
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        mv node_modules/${name} $out-tmp
        mv node_modules $out/node_modules
        shopt -s dotglob
        mv $out-tmp/* $out/
        shopt -u dotglob
        rmdir $out-tmp
        rm -f $out/node_modules/.package-lock.json
        runHook postInstall
      '';
    };

  # mkThirdPartyPluginSmoke -- generic smoke check for any third-party
  # plugin produced by mkThirdPartyPlugin. Mirrors opencode's
  # PluginLoader resolution algorithm (per
  # packages/opencode/src/plugin/shared.ts:resolvePackageEntrypoint):
  #
  #   1. Read package.json
  #   2. If `exports["./server"]` is present, use it (resolving the
  #      `default` / `import` condition if it's an object).
  #   3. Otherwise, fall back to `main`.
  #   4. Import that exact file relative to the package root.
  #   5. Assert the module exposes at least one named export.
  #
  # Catches the silent classes:
  #   - installPhase hoisted the wrong directory (no package.json)
  #   - upstream removed exports["./server"] AND main (no entrypoint)
  #   - upstream changed exports["./server"] to point at a
  #     non-existent or empty file
  #
  # The check does NOT assert a specific export NAME (e.g.
  # "PTYPlugin"). A specific-export assertion would need per-plugin
  # smoke checks; the generic shape auto-registers for every
  # third-party plugin in the registry, which is the tradeoff that
  # keeps the bump workflow short. Per-plugin tightening can be added
  # later via an opt-in registry field if a specific plugin warrants
  # it.
  mkThirdPartyPluginSmoke = pkgs: {
    name,
    pkg,
  }:
    pkgs.runCommand "factory-${name}-smoke" {
      nativeBuildInputs = [pkgs.bun];
    } ''
      cat > smoke.ts <<EOF
      // Resolve the entry the same way opencode's PluginLoader does:
      // exports["./server"] first, then main. Hardcoding a sub-path
      // like /dist/index.js would silently miss exports-map
      // regressions; bare-directory imports go through exports["."]
      // which opencode never reads. Reading package.json + applying
      // opencode's algorithm faithfully is what makes the gate
      // meaningful.
      const pkgJson = await Bun.file("${pkg}/package.json").json()
      const serverExport = pkgJson?.exports?.["./server"]
      let entry: string | undefined
      if (typeof serverExport === "string") {
        entry = serverExport
      } else if (serverExport && typeof serverExport === "object") {
        entry = serverExport.default ?? serverExport.import
      }
      if (!entry && typeof pkgJson?.main === "string") {
        entry = pkgJson.main
      }
      if (!entry) {
        console.error("smoke: ${name} has neither exports['./server'] nor main")
        process.exit(1)
      }
      const fullPath = "${pkg}/" + entry.replace(/^\.\//, "")
      const mod = await import(fullPath)
      const exportNames = Object.keys(mod)
      if (exportNames.length === 0) {
        console.error("smoke: ${name} entry " + entry + " has no exports")
        process.exit(1)
      }
      console.log("smoke: ${name} loaded via " + entry + ", exports:", exportNames.join(", "))
      EOF
      export HOME=$TMPDIR
      bun run smoke.ts
      touch $out
    '';
}
