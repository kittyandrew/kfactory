# Plugin + third-party-plugin Nix builders. Pure: take a `pkgs` arg
# plus a spec attrset, return a derivation. No `self` / `inputs`.
#
# Usage:
#   let builders = import ./nix/shared/builders.nix;
#       pkg      = builders.mkPlugin pkgs { name = "x"; src = ./...; npmDepsHash = "..."; };
let
  pluginEntrypointSmokeScript = {
    name,
    pkg,
    assertExports ? false,
    command ? "bun --no-install smoke.ts",
  }: ''
    cat > smoke.ts <<'EOF'
    // Mirror PluginLoader resolution: exports["./server"] (string or
    // object→import/default) then main. Hardcoding /dist/index.js would
    // miss exports-map regressions; bare-dir imports go through exports["."]
    // which opencode never reads.
    const pluginPath = ${builtins.toJSON "${pkg}"}
    const pkgJson = await Bun.file(pluginPath + "/package.json").json()
    const serverExport = pkgJson?.exports?.["./server"]
    let entry: string | undefined
    if (typeof serverExport === "string") {
      entry = serverExport
    } else if (serverExport && typeof serverExport === "object") {
      entry = serverExport.import ?? serverExport.default
    }
    if (!entry && typeof pkgJson?.main === "string") {
      entry = pkgJson.main
    }
    if (!entry) {
      console.error("smoke: ${name} has neither exports['./server'] nor main")
      process.exit(1)
    }
    const fullPath = pluginPath + "/" + entry.replace(/^\.\//, "")
    const mod = await import(fullPath)
    ${
      if assertExports
      then ''
        const exportNames = Object.keys(mod)
        if (exportNames.length === 0) {
          console.error("smoke: ${name} entry " + entry + " has no exports")
          process.exit(1)
        }
        console.log("smoke: ${name} loaded via " + entry + ", exports:", exportNames.join(", "))
      ''
      else ''
        void mod
      ''
    }
    EOF
    export HOME=$TMPDIR
    ${command}
  '';
in {
  # buildNpmPackage wrapper for kfactory-owned plugins (plugins/<name>/
  # with src/, tsconfig.json, package.json + lockfile for typecheck deps;
  # no runtime deps today -- opencode supplies @opencode-ai/plugin at load).
  # $out contains the runtime tree so consumers can point opencode at
  # the directory (Bun resolves `exports["./server"]`) or at a specific
  # file. Test files/dev deps stay in test-only derivations.
  mkPlugin = pkgs: {
    name,
    src,
    npmDepsHash,
    keepNodeModules ? false,
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
        npm prune --omit=dev --ignore-scripts
        mkdir -p $out
        cp -r . $out/
        rm -rf $out/test
        ${pkgs.lib.optionalString (!keepNodeModules) "rm -rf $out/node_modules"}
        runHook postInstall
      '';
    };

  # Same plugin wrapper but runs `tsc --noEmit`, emits marker only.
  # Separate from mkPlugin so the plugin build stays fast.
  mkPluginTypecheck = pkgs: {
    name,
    src,
    npmDepsHash,
    ...
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

  # Stage one kfactory-owned plugin inside patched opencode's workspace
  # and run tsc with paths re-mapped to opencode's source packages (not
  # the npm ones). The tsconfig is generated fresh per plugin so it
  # matches whatever module-resolution opencode happens to use post-patches.
  mkPluginIntegrationCheck = pkgs: {
    name,
    spec,
    opencodePackage,
  }:
    opencodePackage.overrideAttrs (_: {
      pname = "kfactory-plugin-${name}-integration-typecheck";
      # Bring the plugin source in as a build input so Nix copies it
      # to the store; the bash below pulls it via the env var.
      pluginSrc = spec.src;
      configurePhase = ''
        runHook preConfigure
        ln -s ${opencodePackage.node_modules}/node_modules node_modules
        for package in opencode plugin; do
          mkdir -p "packages/$package"
          ln -s ${opencodePackage.node_modules}/packages/$package/node_modules "packages/$package/node_modules"
        done
        mkdir -p packages/sdk/js
        ln -s ${opencodePackage.node_modules}/packages/sdk/js/node_modules packages/sdk/js/node_modules
        runHook postConfigure
      '';
      buildPhase = ''
        runHook preBuild
        dest="packages/kfactory-${name}"
        cp -r "$pluginSrc" "$dest"
        chmod -R +w "$dest"
        # Custom tsconfig: bundler resolution + explicit `paths` to
        # opencode's workspace sources for @opencode-ai/plugin and
        # @opencode-ai/sdk. baseUrl is the plugin dir so workspace
        # walks find @types/node in the root node_modules / sibling
        # workspaces hoisted by bun.
        cat > "$dest/tsconfig.json" <<'EOF'
        {
          "compilerOptions": {
            "target": "ES2022",
            "module": "ESNext",
            "moduleResolution": "bundler",
            "strict": true,
            "noEmit": true,
            "skipLibCheck": true,
            "esModuleInterop": true,
            "lib": ["ES2022", "DOM", "DOM.Iterable"],
            "types": ["node"],
            "baseUrl": ".",
            "typeRoots": ["../plugin/node_modules/@types"],
            "paths": {
              "@opencode-ai/plugin": ["../plugin/src/index.ts"],
              "@opencode-ai/plugin/*": ["../plugin/src/*"],
              "@opencode-ai/sdk": ["../sdk/js/src/index.ts"],
              "@opencode-ai/sdk/*": ["../sdk/js/src/*"]
            }
          },
          "include": ["src/**/*.ts"]
        }
        EOF
        echo "--- integration typecheck: ${name} ---"
        cd "$dest"
        ${pkgs.nodejs}/bin/node ../opencode/node_modules/typescript/bin/tsc --noEmit -p .
        cd ../..
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        touch $out
        runHook postInstall
      '';
      postInstall = "";
      postFixup = "";
      doInstallCheck = false;
    });

  # Runtime artifact guard for kfactory-owned plugins. The builder may
  # need node_modules for real runtime value imports (loop), but tests
  # and dev-only dependency trees must not leak into source-only plugins.
  mkPluginRuntimeArtifactCheck = pkgs: {
    name,
    pkg,
    keepNodeModules ? false,
  }:
    pkgs.runCommand "factory-${name}-runtime-artifact" {
      nativeBuildInputs = [pkgs.bun];
    } ''
      plugin=${pkg}
      if [ -e "$plugin/test" ]; then
        echo "${name} runtime artifact unexpectedly contains test" >&2
        exit 1
      fi
      if ${
        if keepNodeModules
        then "true"
        else "false"
      }; then
        if [ ! -e "$plugin/node_modules" ]; then
          echo "${name} runtime artifact should contain runtime node_modules" >&2
          exit 1
        fi
      else
        if [ -e "$plugin/node_modules" ]; then
          echo "${name} runtime artifact unexpectedly contains node_modules" >&2
          exit 1
        fi
      fi
      ${pluginEntrypointSmokeScript {inherit name pkg;}}
      touch $out
    '';

  # Third-party plugins from `plugins/<name>/` carriers (package.json
  # + lockfile, no src/). Installs from the npm registry, promotes the
  # third-party package to $out, hoists deps to $out/node_modules.
  # Bump workflow: .claude/rules/050-third-party-nix-plugins.md;
  # carrier-vs-alternatives rationale: docs/spec.md decisions log.
  #
  # Keep --ignore-scripts explicit for auditability even though buildNpmPackage
  # already applies it. Registry tarball installs do not run prepare hooks;
  # runtime resolver scripts remain available.
  mkThirdPartyPlugin = pkgs: {
    name,
    packageName ? name,
    version,
    src,
    npmDepsHash,
    postInstallCommands ? "",
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
        mv node_modules/${packageName} $out-tmp
        mv node_modules $out/node_modules
        shopt -s dotglob
        mv $out-tmp/* $out/
        shopt -u dotglob
        rmdir $out-tmp
        rm -f $out/node_modules/.package-lock.json
        ${postInstallCommands}
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
      ${pluginEntrypointSmokeScript {
        inherit name pkg;
        assertExports = true;
        command = "bun run smoke.ts";
      }}
      touch $out
    '';
}
