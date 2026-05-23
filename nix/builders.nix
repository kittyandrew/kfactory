# Plugin + third-party-plugin Nix builders. Pure: take a `pkgs` arg
# plus a spec attrset, return a derivation. No `self` / `inputs`.
#
# Usage:
#   let builders = import ./nix/builders.nix;
#       pkg      = builders.mkPlugin pkgs { name = "x"; src = ./...; npmDepsHash = "..."; };
{
  # buildNpmPackage wrapper for kfactory-owned plugins (plugins/<name>/
  # with src/, tsconfig.json, package.json + lockfile for typecheck deps;
  # no runtime deps today -- opencode supplies @opencode-ai/plugin at load).
  # $out contains the full tree so consumers can point opencode at the
  # directory (Bun resolves `exports["./server"]`) or at a specific file.
  mkPlugin = pkgs: {
    name,
    src,
    npmDepsHash,
  }:
    pkgs.buildNpmPackage {
      pname = "kfactory-plugin-${name}";
      version = "0.0.1";
      inherit src npmDepsHash;
      # No compile step: opencode's PluginLoader `await import()`s the
      # entrypoint and Bun's runtime transpiles TS on the fly.
      dontNpmBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp -r . $out/
        rm -rf $out/node_modules/.package-lock.json
        runHook postInstall
      '';
    };

  # Same plugin wrapper but runs `tsc --noEmit`, emits marker only.
  # Separate from mkPlugin so the plugin build stays fast.
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

  # Third-party plugins from `plugins/<name>/` carriers (package.json
  # + lockfile, no src/). Installs from the npm registry, promotes the
  # third-party package to $out, hoists deps to $out/node_modules.
  # Bump workflow: .claude/rules/050-third-party-nix-plugins.md;
  # carrier-vs-alternatives rationale: docs/spec.md decisions log.
  #
  # `npmInstallFlags = ["--ignore-scripts"]` is redundant with
  # buildNpmPackage's npmConfigHook (already passes --ignore-scripts)
  # but kept for greppability. Suppressed scripts depend on the dep
  # tree (opencode-pty: msgpackr-extract's node-gyp-build resolver,
  # benign -- runs at runtime). Does NOT suppress `prepare` hooks
  # (those don't fire for registry tarball installs).
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
      # `shopt -s dotglob` moves any dotfiles the upstream tarball
      # ships -- a separate `.[!.]*` glob would exit 1 under `set -eu`
      # for packages without dotfiles.
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

  # Generic smoke check for any mkThirdPartyPlugin output. Mirrors
  # opencode's PluginLoader resolution (packages/opencode/src/plugin/
  # shared.ts:resolvePackageEntrypoint): read package.json,
  # exports["./server"] first (string OR object → default/import),
  # fall back to main, import the entry, assert ≥1 named export.
  #
  # Catches: wrong directory hoisted (no package.json), upstream
  # dropped both exports["./server"] AND main, exports["./server"]
  # pointing at a non-existent / empty file.
  #
  # Does NOT assert a specific export name -- generic so auto-registers
  # for every entry in thirdPartyPluginSrcs. Per-plugin tightening can
  # be added via an opt-in registry field.
  mkThirdPartyPluginSmoke = pkgs: {
    name,
    pkg,
  }:
    pkgs.runCommand "factory-${name}-smoke" {
      nativeBuildInputs = [pkgs.bun];
    } ''
      cat > smoke.ts <<EOF
      // Mirror PluginLoader resolution: exports["./server"] (string or
      // object→default/import) then main. Hardcoding /dist/index.js
      // would miss exports-map regressions; bare-dir imports go through
      // exports["."] which opencode never reads.
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
