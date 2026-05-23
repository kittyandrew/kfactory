{
  description = "kfactory -- opencode factory deployment toolkit: kfactory CLI + kfactory-adapter & ntfy plugins + opencode/oauth2-proxy patches";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Patches under patches/ are line-number-pinned against this exact
    # opencode tag. To bump: change the tag, run `nix flake check` to
    # see if the patches still apply (factory-opencode-patch-applies
    # check). If hunks drift, re-diff against the new source -- the
    # bump playbook is documented in .claude/rules/022-patches-bump.md;
    # the re-diff workflow itself is in .claude/rules/021-patches-rediff.md.
    opencode.url = "github:anomalyco/opencode/v1.15.9";
  };

  outputs = {
    self,
    nixpkgs,
    opencode,
  }: let
    forAllSystems = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"];

    # Plugin builders: see nix/builders.nix for docs on each.
    builders = import ./nix/builders.nix;
    inherit (builders) mkPlugin mkPluginTypecheck mkThirdPartyPlugin mkThirdPartyPluginSmoke;

    # Per-plugin source + npm deps hash. To refresh the hash after a
    # package-lock.json change:
    #   nix shell nixpkgs#prefetch-npm-deps -c prefetch-npm-deps \
    #     plugins/<name>/package-lock.json
    pluginSrcs = {
      kfactory-adapter = {
        src = ./plugins/kfactory-adapter;
        npmDepsHash = "sha256-yfmTlJxns5IspiKhy/Q8z0WbPKCLSXMN/3LKcZz11w4=";
      };
      ntfy = {
        src = ./plugins/ntfy;
        npmDepsHash = "sha256-awaMDsw5DpycXJLGFMFBgYSB33Y8Lax3jbXQqvhZj3E=";
      };
      loop = {
        src = ./plugins/loop;
        npmDepsHash = "sha256-FuWKV8HBa6mKB5xUaxRZ8GHI2j7ZlxKW/1sOacSNDxs=";
      };
    };

    # Per-third-party-plugin source + npm deps hash. Carriers live
    # under plugins/<name>/ (manifest-only; no src/). Adding an entry
    # here auto-registers:
    #   - `packages.<name>` flake output (via mkThirdPartyPlugin)
    #   - `factory-<name>-smoke` flake check (via mkThirdPartyPluginSmoke)
    #   - opencode.json plugin-list entry inside the regression tests image
    # Bumping any of these follows .claude/rules/050-third-party-nix-plugins.md.
    thirdPartyPluginSrcs = {
      opencode-pty = {
        version = "0.3.4";
        src = ./plugins/opencode-pty;
        npmDepsHash = "sha256-NyRu/yDS3+sDcG4UrbBLg9IBgiE5Qb73jKomZGyyO4Q=";
      };
    };
  in {
    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);

    # `nix develop` -- CI and local hacking share the same toolchain
    # versions; .github/workflows/check.yml invokes everything via
    # `nix develop -c`.
    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        packages = with pkgs; [
          # Nix
          alejandra
          deadnix
          # GitHub Actions
          actionlint
          zizmor
          # Go (kfactory CLI)
          go
          golangci-lint
          # TypeScript plugins (dep-bump workflow per .claude/rules/010-plugin.md)
          nodejs_22
          prefetch-npm-deps
          # Patch re-diff workflow per .claude/rules/021-patches-rediff.md
          patch
          git
          # Secrets scan; same dev-shell + CI surface as the other
          # code-quality linters. Allowlist in .betterleaks.toml.
          betterleaks
        ];
      };
    });

    # `.#kfactory` ships with EMPTY endpoint defaults; consumers either
    # bake them via `overrideAttrs (old: { ldflags = old.ldflags ++ [
    # "-X main.defaultServer=..." "-X main.defaultIssuer=..."
    # "-X main.defaultClientID=..." "-X main.defaultAudience=..." ]; })`
    # or pass all four to first `kfactory auth login`.
    #
    # `.#opencode-kfactory` / `.#oauth2-proxy-kfactory` are convenience
    # wrappers (pinned source + our patches); building them in CI exercises
    # the full build, catching bundle-time errors (NOT type-level drift --
    # bun's bundler strips types; factory-opencode-typecheck closes that
    # gap, see docs/spec.md §7). Consumers stacking their own patches use
    # the raw `patches.*` exports instead.
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      # Auto-generated packages from thirdPartyPluginSrcs. Adding a new
      # entry to that registry exposes `packages.<name>` here without
      # any explicit per-plugin block below. See rule 050.
      thirdPartyPackages =
        nixpkgs.lib.mapAttrs
        (name: spec: mkThirdPartyPlugin pkgs ({inherit name;} // spec))
        thirdPartyPluginSrcs;
    in
      thirdPartyPackages
      // {
        kfactory = pkgs.callPackage ./. {};
        default = self.packages.${system}.kfactory;

        # opencode + the full patch stack + OPENCODE_EXPERIMENTAL_WORKSPACES
        # baked into the wrapper so the patched workspace-routing middleware
        # is live. Consumers using raw `patches.*` set the env themselves.
        #
        # @WARNING (hashes.json): opencode v1.15.9 ships an x86_64-linux
        # nodeModules hash that doesn't match its bun.lock -- recurring
        # upstream CI race (anomalyco/opencode#18227). We .override
        # `node_modules_updater` (upstream's fakeHash hook for exactly
        # this) with the actual computed hash. Re-derive on every bump:
        #   nix build .#opencode-kfactory 2>&1 | awk '/got:/ {print $2}'
        # x86_64-linux only -- expand to a platform-keyed attrset if we
        # grow aarch64/darwin targets. Drop the override when upstream
        # ships correct hashes (delete locally + `nix build` to verify).
        opencode-kfactory =
          (opencode.packages.${system}.default.override {
            node_modules = opencode.packages.${system}.node_modules_updater.override {
              hash = "sha256-pbVW7cOLT76Q7f++xaYYrwuN7eS6FRen80xoaVog3M4=";
            };
          }).overrideAttrs (old: {
            # @WARNING (patch order): DO NOT REORDER. Stack is:
            #   1. bearer-and-routing   (upstreamable: bearer + --workspace +
            #      routing + listByProject/sync.start workspaceID filter)
            #   2. workspace-branch     (upstreamable: live .git/HEAD branch
            #      in /experimental/workspace rows)
            #   3. session-subscribers  (kfactory.subscribers.changed bus
            #      event for plugins/ntfy)
            #   4. kfactory-refresh     (kfactory-specific; line-pinned
            #      against 1-3's post-apply hashes)
            # Reordering = patch rejects or fuzzy-applies wrong.
            # See .claude/rules/021-patches-rediff.md.
            patches =
              (old.patches or [])
              ++ [
                # Temporary: see patch header. Drop when nixpkgs ships bun 1.3.14+.
                ./patches/opencode-bun-version-relax.patch
                ./patches/opencode-bearer-and-routing.patch
                ./patches/opencode-workspace-branch.patch
                ./patches/opencode-session-subscribers.patch
                ./patches/opencode-kfactory-refresh.patch
              ];
            postFixup =
              (old.postFixup or "")
              + ''
                wrapProgram $out/bin/opencode \
                  --set OPENCODE_EXPERIMENTAL_WORKSPACES true
              '';
          });

        oauth2-proxy-kfactory = pkgs.oauth2-proxy.overrideAttrs (old: {
          patches = (old.patches or []) ++ [./patches/oauth2-proxy-pkce-no-secret.patch];
        });

        # Opencode lifecycle glue. Shell apps that consumers wire into
        # opencode-serve's systemd unit (or equivalent); both touch
        # opencode-internal surfaces (heal: DB schema; sync-kick: HTTP
        # routes) the kfactory patches own. See `services.kfactory.recovery`
        # for canonical wiring. Script bodies live in modules/scripts/*.sh
        # to avoid Nix-escaping SQL/jq and keep them grep-able + shellcheck-
        # gated via writeShellApplication.
        opencode-heal = pkgs.writeShellApplication {
          name = "opencode-heal";
          # writeShellApplication locks PATH to runtimeInputs. `grep` is
          # NOT in coreutils -- omitting gnugrep silently empties the
          # heal queue (a `grep -v '^$' | sort -u` step in a `|| true`
          # chain swallows the error).
          runtimeInputs = [pkgs.sqlite pkgs.jq pkgs.coreutils pkgs.gnugrep];
          text = builtins.readFile ./modules/scripts/opencode-heal.sh;
        };

        opencode-sync-kick = pkgs.writeShellApplication {
          name = "opencode-sync-kick";
          runtimeInputs = [pkgs.curl pkgs.jq pkgs.coreutils];
          text = builtins.readFile ./modules/scripts/opencode-sync-kick.sh;
        };

        # Regression test OCI images -- dev-only, NOT production: kfactory-cli
        # bakes a fake OIDC bearer, opencode-image runs unauthenticated.
        # Lets `kfactory attach` etc. be debugged against a known-good
        # config without the full OIDC stack. See tests/regression/README.md.
        opencode-image = pkgs.callPackage ./tests/regression/opencode-image.nix {
          opencode-kfactory = self.packages.${system}.opencode-kfactory;
          opencode-heal = self.packages.${system}.opencode-heal;
          opencode-sync-kick = self.packages.${system}.opencode-sync-kick;
          plugins = self.plugins.${system};
          # `genAttrs` (not `intersectAttrs`): reads only names declared
          # in thirdPartyPluginSrcs and fails loudly if one's missing
          # from self.packages. intersectAttrs would silently swallow a
          # name collision with a future kfactory-owned package and
          # misroute it into opencode.json's plugin list.
          thirdPartyPlugins =
            nixpkgs.lib.genAttrs
            (builtins.attrNames thirdPartyPluginSrcs)
            (n: self.packages.${system}.${n});
          testRepo = pkgs.callPackage ./tests/regression/test-repo.nix {};
        };
        kfactory-cli-image = pkgs.callPackage ./tests/regression/kfactory-cli-image.nix {
          kfactory = self.packages.${system}.kfactory;
          opencode-kfactory = self.packages.${system}.opencode-kfactory;
          testRepo = pkgs.callPackage ./tests/regression/test-repo.nix {};
        };
      });

    # Docker-based regression lifecycle (see tests/regression/README.md).
    apps = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      scripts = import ./tests/regression/scripts {inherit pkgs;};
      mkApp = drv: name: {
        type = "app";
        program = "${drv}/bin/${name}";
      };
    in {
      dev-up = mkApp scripts.dev-up "dev-up";
      dev-down = mkApp scripts.dev-down "dev-down";
      dev-clean = mkApp scripts.dev-clean "dev-clean";
      dev-test = mkApp scripts.dev-test "dev-test";
    });

    # Plugin store paths -- consumers reference them DIRECTLY in
    # opencode.json (no `/etc/opencode/plugins/...` symlink detour);
    # opencode's PluginLoader resolves a directory via its package.json
    # `exports["./server"]`. Interpolate at NixOS evaluation time:
    #
    #   environment.etc."opencode/opencode.json".text = builtins.toJSON {
    #     plugin = [
    #       "${kfactory.plugins.${system}.kfactory-adapter}"
    #       "${kfactory.plugins.${system}.ntfy}"
    #       "${kfactory.plugins.${system}.loop}"
    #     ];
    #     # ...
    #   };
    #
    # Adding to pluginSrcs auto-registers a CI gate (see `checks` below).
    plugins = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in
      nixpkgs.lib.mapAttrs
      (name: spec: mkPlugin pkgs ({inherit name;} // spec))
      pluginSrcs);

    # Patch file paths for consumers to apply via overrideAttrs.
    #
    #   opencodePkg = inputs.opencode.packages.${system}.default.overrideAttrs (old: {
    #     patches = (old.patches or []) ++ [
    #       inputs.kfactory.patches.opencode-bun-version-relax    # temporary; drop when nixpkgs ships bun >=1.3.14
    #       inputs.kfactory.patches.opencode-bearer-and-routing   # upstreamable: bearer + routing + listByProject filter
    #       inputs.kfactory.patches.opencode-workspace-branch     # upstreamable: live .git/HEAD branch in workspace list
    #       inputs.kfactory.patches.opencode-session-subscribers  # optional; needed for plugins/ntfy
    #       inputs.kfactory.patches.opencode-kfactory-refresh     # optional; needed for `kfactory attach`
    #     ];
    #   });
    #
    # @WARNING (hashes.json): the snippet above will fail with `hash
    #   mismatch in fixed-output derivation 'opencode-node_modules-...'`
    #   on opencode v1.15.9+ until upstream's CI race
    #   (anomalyco/opencode#18227) stabilises. Wrap with `.override
    #   { node_modules = ...; }` BEFORE `.overrideAttrs`:
    #
    #     opencodePkg = (inputs.opencode.packages.${system}.default.override {
    #       node_modules = inputs.opencode.packages.${system}.node_modules_updater.override {
    #         hash = "sha256-pbVW7cOLT76Q7f++xaYYrwuN7eS6FRen80xoaVog3M4=";  # x86_64-linux, v1.15.9
    #       };
    #     }).overrideAttrs (old: { patches = ...; });
    #
    #   Hash is opencode-version-specific; consumers on a different tag
    #   MUST re-derive via `nix build .#<pkg> 2>&1 | awk '/got:/ {print $2}'`.
    #   Recipe requires `inputs.opencode` to expose `node_modules_updater`
    #   (public on anomalyco/opencode forks only; arbitrary opencode flakes
    #   surface as "attribute not found"). See `opencode-kfactory` above
    #   for the canonical pattern.
    #
    # @WARNING (patch order): apply patches in the order shown above.
    #   Reordering = `patch` rejects loudly or fuzzy-applies at the wrong
    #   offset. Upstreamable subset = bearer-and-routing + workspace-branch
    #   + session-subscribers; skip kfactory-refresh if not using attach.
    #   Stack authority: .claude/rules/020-patches.md.
    patches = {
      opencode-bun-version-relax = ./patches/opencode-bun-version-relax.patch;
      opencode-bearer-and-routing = ./patches/opencode-bearer-and-routing.patch;
      opencode-workspace-branch = ./patches/opencode-workspace-branch.patch;
      opencode-session-subscribers = ./patches/opencode-session-subscribers.patch;
      opencode-kfactory-refresh = ./patches/opencode-kfactory-refresh.patch;
      oauth2-proxy-pkce-no-secret = ./patches/oauth2-proxy-pkce-no-secret.patch;
    };

    # NixOS modules for the kfactory pieces that are intrinsically
    # NixOS-shaped (per-task systemd timers, opencode-serve lifecycle
    # hooks). The rest of kfactory stays module-free. Both modules
    # default `package` / `packages` to `self.packages.${system}` for
    # zero-config use; override via mkForce when baking endpoint
    # defaults into `kfactory` via overrideAttrs/ldflags.
    nixosModules = {
      scheduledTasks = {pkgs, ...}: {
        imports = [./modules/scheduled-tasks.nix];
        services.kfactory.scheduledTasks.package =
          nixpkgs.lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.kfactory;
      };
      recovery = {pkgs, ...}: {
        imports = [./modules/recovery.nix];
        services.kfactory.recovery.packages =
          nixpkgs.lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system};
      };
    };

    # CI gate. `nix flake check` builds:
    #   - every `packages.${system}.*` (minus `default` alias) and every
    #     `plugins.${system}.*` (buildNpmPackage = catches lockfile drift);
    #   - `<plugin>-typecheck` -- tsc --noEmit against published
    #     @opencode-ai/plugin types (catches SDK API shape drift);
    #   - `<plugin>-integration-typecheck` -- same plugin tsc'd against
    #     opencode's WORKSPACE sources (not npm), catching call-site
    #     drift the published-types check can't see (e.g. a method on
    #     `input.client.session` whose patched signature differs);
    #   - factory-opencode-patch-applies -- patch -p1 in-sequence; orders
    #     of magnitude faster than the full opencode-kfactory build, so
    #     it fast-fails when line-numbers drift after `nix flake update`;
    #   - factory-oauth2-proxy-patch-applies -- same shape for nixpkgs'
    #     oauth2-proxy src; fails when nixpkgs bumps past PR #3168's geometry;
    #   - factory-opencode-typecheck -- tsc --noEmit against the patched
    #     opencode source; bun's bundler strips types, this catches the
    #     semantic drift our patches might introduce (see spec.md §7);
    #   - factory-completion-loads -- parse-time zsh completion sanity.
    # Adding a package, plugin, or patch auto-registers via the pattern below.
    checks = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      packageChecks = nixpkgs.lib.filterAttrs (name: _: name != "default") self.packages.${system};
      pluginChecks = self.plugins.${system};
      pluginTypechecks =
        nixpkgs.lib.mapAttrs'
        (name: spec:
          nixpkgs.lib.nameValuePair
          "${name}-typecheck"
          (mkPluginTypecheck pkgs ({inherit name;} // spec)))
        pluginSrcs;

      # Auto-generated smoke check per third-party plugin. Adding a
      # new entry to thirdPartyPluginSrcs surfaces a corresponding
      # `factory-<name>-smoke` flake check automatically. The check
      # asserts the package store path imports cleanly and exposes
      # at least one named export.
      thirdPartySmokeChecks =
        nixpkgs.lib.mapAttrs'
        (name: _:
          nixpkgs.lib.nameValuePair
          "factory-${name}-smoke"
          (mkThirdPartyPluginSmoke pkgs {
            inherit name;
            pkg = self.packages.${system}.${name};
          }))
        thirdPartyPluginSrcs;

      # Stage one plugin inside opencode-kfactory's workspace and run tsc
      # with paths re-mapped to opencode's source packages (not the npm
      # ones). The tsconfig is generated fresh per plugin so it matches
      # whatever module-resolution opencode happens to use post-patches.
      mkPluginIntegrationCheck = name: spec:
        self.packages.${system}.opencode-kfactory.overrideAttrs (_: {
          pname = "kfactory-plugin-${name}-integration-typecheck";
          # Bring the plugin source in as a build input so Nix copies it
          # to the store; the bash below pulls it via the env var.
          pluginSrc = spec.src;
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
            ../opencode/node_modules/.bin/tsc --noEmit -p .
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

      pluginIntegrationChecks =
        nixpkgs.lib.mapAttrs'
        (name: spec:
          nixpkgs.lib.nameValuePair
          "${name}-integration-typecheck"
          (mkPluginIntegrationCheck name spec))
        pluginSrcs;

      # Regression lifecycle scripts are writeShellApplication-based, which
      # bakes shellcheck into the build. Adding them as checks
      # promotes the shellcheck gate into `nix flake check` (so CI
      # catches shell regressions on every PR, not only when an
      # operator runs `nix run .#dev-*`).
      devScripts = import ./tests/regression/scripts {inherit pkgs;};
      devScriptChecks =
        nixpkgs.lib.mapAttrs'
        (name: drv:
          nixpkgs.lib.nameValuePair "factory-${name}-shellcheck" drv)
        devScripts;
    in
      packageChecks
      // pluginChecks
      // pluginTypechecks
      // pluginIntegrationChecks
      // thirdPartySmokeChecks
      // devScriptChecks
      // {
        factory-opencode-patch-applies =
          pkgs.runCommand "factory-opencode-patch-applies" {
            src = opencode.outPath;
            patch1 = ./patches/opencode-bearer-and-routing.patch;
            patch2 = ./patches/opencode-workspace-branch.patch;
            patch3 = ./patches/opencode-session-subscribers.patch;
            patch4 = ./patches/opencode-kfactory-refresh.patch;
            nativeBuildInputs = [pkgs.patch];
          } ''
            cp -R "$src" ./opencode
            chmod -R +w ./opencode
            cd ./opencode
            # Real (not --dry-run) in-sequence apply mirrors
            # opencode-kfactory's configurePhase -- catches a later
            # patch that dry-runs clean but real-applies wrong (e.g.
            # overlapping hunks at the same offset).
            patch -p1 < "$patch1"
            patch -p1 < "$patch2"
            patch -p1 < "$patch3"
            patch -p1 < "$patch4"
            touch $out
          '';

        factory-oauth2-proxy-patch-applies =
          pkgs.runCommand "factory-oauth2-proxy-patch-applies" {
            inherit (pkgs.oauth2-proxy) src;
            patch = ./patches/oauth2-proxy-pkce-no-secret.patch;
            nativeBuildInputs = [pkgs.patch];
          } ''
            cp -R "$src" ./oauth2-proxy
            chmod -R +w ./oauth2-proxy
            cd ./oauth2-proxy
            patch -p1 --dry-run < "$patch"
            touch $out
          '';

        # Parse-time sanity check on the zsh completion. `autoload +X`
        # forces body parsing now; its exit code stays 0 even when
        # diagnostics print, so we capture stderr separately. Does NOT
        # simulate completion against the actual CLI flag set.
        factory-completion-loads =
          pkgs.runCommand "factory-completion-loads" {
            completion = ./completions/_kfactory;
            nativeBuildInputs = [pkgs.zsh];
          } ''
            mkdir compdir
            cp "$completion" compdir/_kfactory
            export HOME=$TMPDIR
            errlog=$TMPDIR/autoload.err
            zsh -fc '
              fpath=('"$PWD"'/compdir $fpath)
              autoload -Uz compinit
              compinit -u -d '"$PWD"'/zcompdump
              autoload +X _kfactory
            ' 2> $errlog
            if [ -s $errlog ]; then
              echo "factory-completion-loads: zsh emitted diagnostics:" >&2
              cat $errlog >&2
              exit 1
            fi
            echo "_kfactory parsed OK"
            touch $out
          '';

        # Builds on opencode-kfactory's configurePhase (patches + node_modules
        # in place) and runs `tsc --noEmit` (NOT tsgo -- needs a postinstall-
        # downloaded native binary that `bun install --ignore-scripts` skips).
        # Scope: packages/opencode/ only -- where patched files live;
        # @opencode-ai/core types resolve via workspace references anyway.
        factory-opencode-typecheck = self.packages.${system}.opencode-kfactory.overrideAttrs (_: {
          pname = "factory-opencode-typecheck";
          baseline = ./checks/factory-opencode-typecheck.baseline;
          buildPhase = ''
            runHook preBuild
            cd packages/opencode
            # tsc exits non-zero on any TS error; we compare the FULL set
            # of error lines against a checked-in baseline (the known
            # opencode-upstream noise). Any diff fails the check --
            # additions = new patch-induced errors; deletions = baseline
            # noise that upstream has fixed (and should be removed here).
            #
            # Normalization: strip ANSI colors; strip the Nix store
            # /build/source/ prefix so the baseline is build-stable.
            log=$(./node_modules/.bin/tsc --noEmit 2>&1 || true)
            echo "$log"
            # Match only real tsc error lines (file:loc - error TSnnnn:).
            # Avoids picking up prose containing the substring "error TS"
            # in the baseline's header comments.
            errPattern='error TS[0-9]'
            actual=$(printf '%s\n' "$log" \
              | sed -E 's/\x1b\[[0-9;]*m//g' \
              | grep -E "$errPattern" \
              | sed -E 's|/build/source/?||g' \
              | sort -u)
            # Baseline allows leading `# comment` and blank lines.
            expected=$(grep -E "$errPattern" < $baseline | sort -u)
            if [ "$actual" != "$expected" ]; then
              echo "factory-opencode-typecheck: tsc errors differ from baseline" >&2
              echo "--- expected ($baseline) ---" >&2
              printf '%s\n' "$expected" >&2
              echo "--- actual ---" >&2
              printf '%s\n' "$actual" >&2
              echo "--- diff (- removed, + added) ---" >&2
              diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
              exit 1
            fi
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            touch $out
            runHook postInstall
          '';
          # The typecheck never produces $out/bin/opencode; clear the
          # postInstall + postFixup hooks (and the install-check) that
          # opencode-kfactory adds for the binary.
          postInstall = "";
          postFixup = "";
          doInstallCheck = false;
        });
      });
  };
}
