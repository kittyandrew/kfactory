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

    # Pure-function plugin builders extracted to keep flake.nix under
    # the 1k-line rule. mkPlugin / mkPluginTypecheck /
    # mkThirdPartyPlugin / mkThirdPartyPluginSmoke -- see comments in
    # nix/builders.nix for what each does.
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
    #   - opencode.json plugin-list entry inside the e2e tests image
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

    # `nix develop` -- toolchain for CI + local hacking. All linters
    # invoked from .github/workflows/check.yml live here so CI and
    # local runs use the same versions.
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

    # `nix build .#kfactory` builds the CLI binary with EMPTY endpoint
    # defaults. Consumers either:
    #   - override via `kfactory.overrideAttrs (old: { ldflags = old.ldflags
    #     ++ ["-X main.defaultServer=..." "-X main.defaultIssuer=..."
    #     "-X main.defaultClientID=..." "-X main.defaultAudience=..."]; })`
    #     to bake defaults into the binary;
    #   - or have operators pass all four flags on first `kfactory auth login`.
    #
    # `nix build .#opencode-kfactory` + `.#oauth2-proxy-kfactory` are
    # CONVENIENCE wrappers: kfactory's pinned upstream sources with our
    # patches applied. Building them here means CI exercises the FULL
    # build (not just `patch --dry-run`), which catches more failure
    # modes:
    #   - opencode-kfactory: bundle-time errors from the patched TS,
    #     missing imports introduced by the patches, etc. (does NOT
    #     catch type-level drift -- bun's bundler doesn't typecheck;
    #     see docs/spec.md §7).
    #   - oauth2-proxy-kfactory: Go compile catches everything for that
    #     package.
    #
    # Consumers may prefer the raw `patches.*` exports for stacking with
    # their own patches or bumping opencode/oauth2-proxy independently of
    # kfactory's pin. Both paths are supported.
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

        # opencode-kfactory: opencode with the full patch stack applied +
        # the experimental-workspaces env var baked into the wrapper, so
        # the workspace-routing middleware (added by the patches) is
        # actually exercised at runtime. Consumers using the raw
        # `patches.*` exports are responsible for setting
        # OPENCODE_EXPERIMENTAL_WORKSPACES themselves.
        #
        # @WARNING (hashes.json): opencode v1.15.9 ships an incorrect `nix/hashes.json`:
        # the committed x86_64-linux nodeModules hash does not match the
        # hash nix actually computes from v1.15.9's bun.lock. A recurring
        # upstream CI race -- anomalyco/opencode#18227 has been fixed and
        # re-broken across multiple releases. We sidestep by building our
        # own `node_modules` via .override on
        # `opencode.packages.${system}.node_modules_updater` (which is
        # `node_modules.override { hash = fakeHash; }` -- a hook for
        # exactly this re-override). Re-derive the correct hash on every
        # opencode bump:
        #   nix build .#opencode-kfactory 2>&1 | awk '/got:/ {print $2}'
        # The override is x86_64-linux only -- expand to a platform-keyed
        # attrset matching hashes.json's shape if kfactory grows
        # aarch64-linux / darwin support. Drop the entire .override block
        # when upstream publishes a release with correct hashes.json;
        # verify by deleting the override locally and re-running
        # `nix build .#opencode-kfactory` to confirm it succeeds.
        opencode-kfactory =
          (opencode.packages.${system}.default.override {
            node_modules = opencode.packages.${system}.node_modules_updater.override {
              hash = "sha256-pbVW7cOLT76Q7f++xaYYrwuN7eS6FRen80xoaVog3M4=";
            };
          }).overrideAttrs (old: {
            # @WARNING (patch order): DO NOT REORDER. The four opencode patches must
            #   apply in this exact order:
            #     1. opencode-bearer-and-routing   (upstreamable surface:
            #        bearer flag, --workspace plumbing, workspace routing
            #        + listByProject workspace_id filter)
            #     2. opencode-workspace-branch     (upstreamable surface:
            #        per-row .git/HEAD branch enrichment in
            #        /experimental/workspace response)
            #     3. opencode-session-subscribers  (kfactory.subscribers.changed
            #        bus event used by plugins/ntfy)
            #     4. opencode-kfactory-refresh     (kfactory-specific
            #        deployment glue; line-pinned against patches 1-3)
            #   Reordering will make `patch` reject loudly or fuzzy-apply
            #   at the wrong offset. See .claude/rules/021-patches-rediff.md.
            patches =
              (old.patches or [])
              ++ [
                # Temporary: relax opencode v1.15.9's bun-version check so
                # the build accepts the bun 1.3.13 nixpkgs currently ships.
                # See the patch header for the full chain (nixpkgs#519796
                # is in DRAFT because bun 1.3.14 segfaults downstream builds;
                # opencode's bun bump was purely metadata/future-proofing,
                # no API delta). Drop when nixpkgs ships bun 1.3.14+.
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

        # ---- Opencode lifecycle glue ----
        #
        # Two small shell apps consumers wire into their opencode
        # systemd unit (or equivalent). Both are opencode-internal-API-
        # coupled (DB schema for heal, HTTP routes for sync-kick),
        # which is exactly why they live in kfactory: kfactory's
        # patches already own this surface. See `services.kfactory.recovery`
        # NixOS module for the canonical wiring that pairs them.

        # opencode-heal + opencode-sync-kick: script source lives at
        # modules/scripts/*.sh next to the recovery module that's their
        # only consumer. Keeping the script bodies out of flake.nix
        # means SQL and jq syntax don't need Nix string-escaping, the
        # files are individually grep-able, and shellcheck still gates
        # them via writeShellApplication's build-time check.
        opencode-heal = pkgs.writeShellApplication {
          name = "opencode-heal";
          # gnugrep + coreutils (printf, wc, sort, mkdir, dirname) +
          # sqlite + jq cover every external the script calls.
          # writeShellApplication's PATH is locked to runtimeInputs;
          # missing `grep` was silently masking heal in earlier test
          # runs (queue ended up empty because `grep -v '^$' | sort -u`
          # in a `|| true` chain swallowed the error).
          runtimeInputs = [pkgs.sqlite pkgs.jq pkgs.coreutils pkgs.gnugrep];
          text = builtins.readFile ./modules/scripts/opencode-heal.sh;
        };

        opencode-sync-kick = pkgs.writeShellApplication {
          name = "opencode-sync-kick";
          runtimeInputs = [pkgs.curl pkgs.jq pkgs.coreutils];
          text = builtins.readFile ./modules/scripts/opencode-sync-kick.sh;
        };

        # ---- E2E test OCI images (see tests/e2e/README.md) ----
        #
        # These are dev-only images for the end-to-end Docker-based
        # tests. They are NOT meant for production -- they bake in a
        # fake OIDC bearer (kfactory-cli) and run opencode unauthenticated
        # (opencode-image). The e2e tests exist so the `kfactory attach`
        # path can be debugged against a known-good opencode + plugin
        # config without bringing up the full OIDC stack.
        opencode-image = pkgs.callPackage ./tests/e2e/opencode-image.nix {
          opencode-kfactory = self.packages.${system}.opencode-kfactory;
          opencode-heal = self.packages.${system}.opencode-heal;
          opencode-sync-kick = self.packages.${system}.opencode-sync-kick;
          plugins = self.plugins.${system};
          # Third-party plugins are derived from the auto-generated
          # packages by name-matching against thirdPartyPluginSrcs.
          # Adding a new third-party plugin to thirdPartyPluginSrcs
          # surfaces it here automatically; no edit required.
          #
          # `genAttrs` (not `intersectAttrs`) is deliberate: it reads
          # ONLY names declared in thirdPartyPluginSrcs and fails
          # loudly at evaluation if a name doesn't exist in
          # self.packages. An earlier shape used intersectAttrs, which
          # would silently pick up any kfactory-owned `packages.<x>`
          # whose name happened to collide with a future third-party
          # plugin entry -- misrouting it into the opencode.json
          # plugin list without a build error.
          thirdPartyPlugins =
            nixpkgs.lib.genAttrs
            (builtins.attrNames thirdPartyPluginSrcs)
            (n: self.packages.${system}.${n});
          testRepo = pkgs.callPackage ./tests/e2e/test-repo.nix {};
        };
        kfactory-cli-image = pkgs.callPackage ./tests/e2e/kfactory-cli-image.nix {
          kfactory = self.packages.${system}.kfactory;
          opencode-kfactory = self.packages.${system}.opencode-kfactory;
          testRepo = pkgs.callPackage ./tests/e2e/test-repo.nix {};
        };
      });

    # `nix run .#dev-up` / `.#dev-down` / `.#dev-clean` / `.#dev-test` --
    # lifecycle scripts for the Docker-based E2E test environment. See
    # tests/e2e/README.md for the manual test workflow.
    apps = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      scripts = import ./tests/e2e/scripts {inherit pkgs;};
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

    # `nix build .#plugins.<system>.<name>` builds a single plugin and
    # returns its store path (containing the package's full tree: src/,
    # node_modules/, package.json). Consumers reference the store path
    # DIRECTLY in opencode.jsonc -- no `/etc/opencode/plugins/...` symlink
    # detour. opencode's PluginLoader accepts absolute paths; when given
    # a directory it resolves the package.json `exports["./server"]`
    # field to find the entrypoint.
    #
    # Generate opencode.jsonc from NixOS config so the store paths are
    # interpolated at evaluation time:
    #
    #   environment.etc."opencode/opencode.json".text = builtins.toJSON {
    #     plugin = [
    #       "${kfactory.plugins.${system}.kfactory-adapter}"
    #       "${kfactory.plugins.${system}.ntfy}"
    #       "${kfactory.plugins.${system}.loop}"
    #     ];
    #     # ... other opencode config
    #   };
    #
    # All plugins are added to checks automatically (see `checks` below),
    # so adding a new plugin to `pluginSrcs` registers it as a CI gate.
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
    # @WARNING (hashes.json): opencode v1.15.9 (and possibly later) ships
    #   an incorrect `nix/hashes.json` -- a recurring upstream CI race
    #   (anomalyco/opencode#18227, fixed and re-broken several times).
    #   The snippet above will fail with `hash mismatch in fixed-output
    #   derivation 'opencode-node_modules-<version>'`. Until upstream
    #   stabilises, wrap with `.override { node_modules = ...; }` BEFORE
    #   the `.overrideAttrs`:
    #
    #     opencodePkg = (inputs.opencode.packages.${system}.default.override {
    #       node_modules = inputs.opencode.packages.${system}.node_modules_updater.override {
    #         hash = "sha256-pbVW7cOLT76Q7f++xaYYrwuN7eS6FRen80xoaVog3M4=";  # x86_64-linux only
    #       };
    #     }).overrideAttrs (old: { patches = ...; });
    #
    #   The hash literal above is specific to opencode v1.15.9's bun.lock.
    #   Consumers pinning a different opencode tag MUST re-derive their own
    #   via `nix build .#<their-opencode-package> 2>&1 | awk '/got:/ {print $2}'`
    #   -- copying our hash will simply move the mismatch error inside the
    #   workaround. The recipe also assumes the consumer's `inputs.opencode`
    #   exposes `packages.<system>.node_modules_updater`; this is a public
    #   export of anomalyco/opencode's flake (and forks that preserve it),
    #   not a general nix idiom -- pinning an unrelated opencode flake
    #   will surface as an "attribute not found" evaluation error rather
    #   than a hash mismatch.
    #
    #   See the `opencode-kfactory` block above for the canonical
    #   pattern + the hash-refresh recipe + per-platform caveat. Drop
    #   the `.override` wrapper when upstream publishes a release with
    #   correct hashes.json.
    #
    # @WARNING (patch order): DO NOT REORDER the opencode patches. Apply in the order
    #   shown above or `patch` will reject loudly (or worse, fuzzy-apply
    #   at the wrong offset). Consumers who only want the upstreamable
    #   subset may include the bearer-and-routing + workspace-branch +
    #   session-subscribers patches and skip kfactory-refresh.
    #   Authoritative stack documentation lives in
    #   .claude/rules/020-patches.md; this block must match.
    patches = {
      opencode-bun-version-relax = ./patches/opencode-bun-version-relax.patch;
      opencode-bearer-and-routing = ./patches/opencode-bearer-and-routing.patch;
      opencode-workspace-branch = ./patches/opencode-workspace-branch.patch;
      opencode-session-subscribers = ./patches/opencode-session-subscribers.patch;
      opencode-kfactory-refresh = ./patches/opencode-kfactory-refresh.patch;
      oauth2-proxy-pkce-no-secret = ./patches/oauth2-proxy-pkce-no-secret.patch;
    };

    # NixOS modules. kfactory ships these for the parts of the
    # deployment surface that are intrinsically NixOS-shaped --
    # per-task systemd timer generation, opencode-serve lifecycle
    # hooks. The rest of kfactory stays module-free (operators wire
    # opencode-kfactory + oauth2-proxy-kfactory + the patches into
    # their own configs).
    #
    # Both modules default their `package` / `packages` option to
    # kfactory's own `packages.${system}` so a consumer that just
    # wants the in-tree CLI gets zero-config behavior:
    #
    #   imports = [ inputs.kfactory.nixosModules.scheduledTasks ];
    #   services.kfactory.scheduledTasks = { enable = true; user = "..."; tasks = { ... }; };
    #
    # Overriding (e.g. for endpoint-ldflag-baked CLIs) is still one
    # line: set `services.kfactory.scheduledTasks.package =
    # pkgs.kfactory.overrideAttrs ...;` and NixOS's mkDefault is
    # superseded.
    nixosModules = {
      scheduledTasks = {pkgs, ...}: {
        imports = [./modules/scheduled-tasks.nix];
        services.kfactory.scheduledTasks.package =
          nixpkgs.lib.mkDefault self.packages.${pkgs.system}.kfactory;
      };
      recovery = {pkgs, ...}: {
        imports = [./modules/recovery.nix];
        services.kfactory.recovery.packages =
          nixpkgs.lib.mkDefault self.packages.${pkgs.system};
      };
    };

    # CI: `nix flake check` builds:
    #   - every `packages.${system}.*` output (except `default`, an alias);
    #   - every `plugins.${system}.*` output (each plugin builds via
    #     buildNpmPackage, so this catches lockfile drift + missing deps);
    #   - per-plugin typecheck (`<name>-typecheck`) running `tsc --noEmit`
    #     against the published @opencode-ai/plugin types. Catches plugin
    #     API SHAPE drift on every opencode plugin SDK release;
    #   - factory-opencode-patch-applies -- `patch -p1` of all three
    #     opencode patches in stack order against the locked opencode
    #     source. Redundant with `opencode-kfactory` building, but several
    #     orders of magnitude faster -- gives fast-fail feedback when
    #     patch line-numbers drift after a `nix flake update opencode`;
    #   - factory-oauth2-proxy-patch-applies -- same shape against nixpkgs'
    #     oauth2-proxy src. Catches drift when nixpkgs bumps oauth2-proxy
    #     past where PR #3168's patch geometry holds;
    #   - factory-opencode-typecheck -- `tsc --noEmit` against the patched
    #     opencode source; catches type-semantic drift inside the patches
    #     that the bun bundler silently strips;
    #   - per-plugin integration typecheck (`<name>-integration-typecheck`)
    #     -- stages each plugin's src inside opencode-kfactory's workspace
    #     tree, writes a tsconfig with `paths` mapping `@opencode-ai/plugin`
    #     and `@opencode-ai/sdk` to opencode's WORKSPACE source packages
    #     (not the published npm types), and runs `tsc --noEmit`. Catches
    #     drift between what a plugin imports/calls (e.g.
    #     `input.client.session.messages(...)`) and what the patched
    #     opencode actually provides. The per-plugin standalone typecheck
    #     uses the npm-published types and CAN'T see this.
    #   - factory-completion-loads -- parse-time zsh completion sanity.
    #
    # Adding a new package, plugin, or patch automatically becomes a CI
    # gate via the auto-register pattern below.
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

      # E2E lifecycle scripts are writeShellApplication-based, which
      # bakes shellcheck into the build. Adding them as checks
      # promotes the shellcheck gate into `nix flake check` (so CI
      # catches shell regressions on every PR, not only when an
      # operator runs `nix run .#dev-*`).
      devScripts = import ./tests/e2e/scripts {inherit pkgs;};
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
            # Apply all four patches for real in sequence -- mirrors
            # how opencode-kfactory's configurePhase applies them, and
            # catches cases where a later patch dry-runs cleanly but
            # real-apply fails (e.g., overlapping hunks at the same
            # offset). The resulting tree is discarded; only success/
            # failure matters.
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

        # factory-completion-loads -- sanity-checks the zsh completion
        # file by force-parsing the function body in a sandboxed zsh
        # and asserting no parse/load errors. Future flag additions or
        # syntax slips in `_arguments` specs surface here instead of
        # only when an operator's shell explodes mid-tab.
        #
        # `autoload -U` alone only marks a function as autoloadable
        # without parsing the body until first call -- syntax errors
        # inside `case` branches would slip past such a check. `autoload
        # +X` forces the body to be parsed now, but its exit code is
        # always 0 even when parsing emits diagnostics to stderr -- so
        # we capture stderr separately and fail if it's non-empty.
        #
        # The check does NOT simulate completion against the actual CLI
        # flag set; for that, see `kfactory --help` and grep
        # cross-reference.
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
              # +X forces parse-time evaluation; any diagnostics
              # (unmatched quote, bad _arguments spec, etc.) print to
              # stderr but do NOT change the exit code -- so we
              # consult stderr below.
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

        # factory-opencode-typecheck -- runs tsc --noEmit against the
        # patched opencode source. Closes the spec.md §7 gap where
        # type-semantic drift inside the kfactory opencode patches was
        # not caught by CI (bun's bundler strips types without
        # checking).
        #
        # Builds on top of `opencode-kfactory` -- its configurePhase
        # already applies our patches and copies the upstream-prepared
        # node_modules into the source tree. We override buildPhase to
        # run `tsc --noEmit` (NOT tsgo: opencode's `typecheck` script
        # uses tsgo, which needs a postinstall-downloaded native binary
        # that opencode's `bun install --ignore-scripts` skips). Standard
        # tsc ships as a JS-only binary in node_modules/.bin/tsc and
        # produces equivalent diagnostics.
        #
        # Scope: only `packages/opencode/` -- where the patches' touched
        # files live. opencode's node_modules.nix filters out most other
        # workspaces (no tsc available in core's .bin), and tsc-in-
        # opencode transitively resolves @opencode-ai/core types via
        # workspace references anyway.
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
          # opencode-kfactory adds postInstall (shell completion) and
          # postFixup (env-var wrap) that operate on $out/bin/opencode --
          # which the typecheck never produces. Clear both, plus the
          # install-check that exercises the binary.
          postInstall = "";
          postFixup = "";
          doInstallCheck = false;
        });
      });
  };
}
