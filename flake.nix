{
  description = "kfactory -- opencode factory deployment toolkit: kfactory CLI + factory-adapter plugin + opencode/oauth2-proxy patches";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Patches under patches/ are line-number-pinned against this exact
    # opencode tag. To bump: change the tag, run `nix flake check` to
    # see if the patch still applies (factory-opencode-patch-applies
    # check). If hunks drift, re-diff against the new source -- the
    # workflow is documented in .claude/rules/020-patches.md.
    opencode.url = "github:sst/opencode/v1.15.4";
  };

  outputs = {
    self,
    nixpkgs,
    opencode,
  }: let
    forAllSystems = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"];
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
          # TypeScript plugin (dep-bump workflow per .claude/rules/010-plugin.md)
          nodejs_22
          prefetch-npm-deps
          # Patch re-diff workflow per .claude/rules/020-patches.md
          patch
          git
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
    #   - opencode-kfactory: bundle-time errors from the patched TS, missing
    #     imports introduced by the patch, etc. (does NOT catch type-level
    #     drift -- bun's bundler doesn't typecheck; see docs/spec.md §7).
    #   - oauth2-proxy-kfactory: Go compile catches everything for that
    #     package.
    #
    # Consumers may prefer the raw `patches.*` exports for stacking with
    # their own patches or bumping opencode/oauth2-proxy independently of
    # kfactory's pin. Both paths are supported.
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      kfactory = pkgs.callPackage ./. {};
      default = self.packages.${system}.kfactory;

      opencode-kfactory = opencode.packages.${system}.default.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./patches/opencode-bearer-auth.patch];
      });

      oauth2-proxy-kfactory = pkgs.oauth2-proxy.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./patches/oauth2-proxy-pkce-no-secret.patch];
      });
    });

    # `lib.mkFactoryAdapter` substitutes the at-signed placeholders in
    # plugin/factory-adapter.ts with deployment-specific absolute paths
    # and returns the resulting store path. Consumer's opencode.jsonc
    # references it via the `plugin` array:
    #
    #   let
    #     adapter = inputs.kfactory.lib.mkFactoryAdapter {
    #       inherit pkgs;
    #       gitBin = "${pkgs.git}/bin/git";
    #       openSSHBin = "${pkgs.openssh}/bin/ssh";
    #       workspacesDir = "/var/lib/factory/workspaces";
    #     };
    #   in {
    #     environment.etc."opencode/plugin/factory-adapter.ts".source = adapter;
    #   }
    lib = {
      mkFactoryAdapter = {
        pkgs,
        gitBin,
        openSSHBin,
        workspacesDir,
      }:
        pkgs.replaceVars ./plugin/factory-adapter.ts {
          GIT = gitBin;
          OPENSSH_SSH = openSSHBin;
          WORKSPACES_DIR = workspacesDir;
        };
    };

    # Patch file paths for consumers to apply via overrideAttrs.
    #
    #   opencodePkg = inputs.opencode.packages.${system}.default.overrideAttrs (old: {
    #     patches = (old.patches or []) ++ [inputs.kfactory.patches.opencode-bearer-auth];
    #   });
    patches = {
      opencode-bearer-auth = ./patches/opencode-bearer-auth.patch;
      oauth2-proxy-pkce-no-secret = ./patches/oauth2-proxy-pkce-no-secret.patch;
    };

    # CI: `nix flake check` builds:
    #   - every `packages.${system}.*` output (except `default`, which
    #     is an alias for `kfactory`) -- so adding a new package to
    #     `packages` automatically registers it as a CI gate, no
    #     workflow editing needed;
    #   - factory-plugin-typecheck -- `tsc --noEmit` against the
    #     published @opencode-ai/plugin types. Catches WorkspaceAdapter
    #     SHAPE drift on every opencode plugin SDK release;
    #   - factory-opencode-patch-applies -- `patch -p1 --dry-run` of
    #     the bearer-auth patch against the locked opencode source.
    #     Redundant with `opencode-kfactory` building, but several
    #     orders of magnitude faster -- gives fast-fail feedback when
    #     the patch line-numbers drift after a `nix flake update opencode`.
    #   - factory-oauth2-proxy-patch-applies -- same shape against
    #     nixpkgs' oauth2-proxy src. Catches drift when nixpkgs bumps
    #     oauth2-proxy past where PR #3168's patch geometry holds.
    checks = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      packageChecks = nixpkgs.lib.filterAttrs (name: _: name != "default") self.packages.${system};
    in
      packageChecks
      // {
        factory-plugin-typecheck = pkgs.buildNpmPackage {
          pname = "factory-plugin-typecheck";
          version = "0";
          src = ./plugin;
          # To refresh: cd plugin && rm -rf node_modules package-lock.json
          # && nix shell nixpkgs#nodejs_22 -c npm install --omit=dev --no-audit
          # && nix shell nixpkgs#prefetch-npm-deps -c prefetch-npm-deps package-lock.json
          # Paste the new sha256-... below.
          npmDepsHash = "sha256-eHMridW/wDnCGiazw1vWt9vTfl57I4khxHLnGPREcq0=";
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

        factory-opencode-patch-applies =
          pkgs.runCommand "factory-opencode-patch-applies" {
            src = opencode.outPath;
            patch = ./patches/opencode-bearer-auth.patch;
            nativeBuildInputs = [pkgs.patch];
          } ''
            cp -R "$src" ./opencode
            chmod -R +w ./opencode
            cd ./opencode
            patch -p1 --dry-run < "$patch"
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

        # factory-opencode-typecheck -- runs tsc --noEmit against the
        # patched opencode source. Closes the spec.md §7 gap where
        # type-semantic drift inside opencode-bearer-auth.patch was not
        # caught by CI (bun's bundler strips types without checking).
        #
        # Builds on top of `opencode-kfactory` -- its configurePhase
        # already applies our patch and copies the upstream-prepared
        # node_modules into the source tree. We override buildPhase to
        # run `tsc --noEmit` (NOT tsgo: opencode's `typecheck` script
        # uses tsgo, which needs a postinstall-downloaded native binary
        # that opencode's `bun install --ignore-scripts` skips). Standard
        # tsc ships as a JS-only binary in node_modules/.bin/tsc and
        # produces equivalent diagnostics.
        #
        # Scope: only `packages/opencode/` -- where 5 of the patch's 6
        # touched files live. opencode's node_modules.nix filters out
        # most other workspaces (no tsc available in core's .bin), and
        # tsc-in-opencode transitively resolves @opencode-ai/core types
        # via workspace references anyway, so the single hunk in
        # packages/core/src/flag/flag.ts is still indirectly covered.
        factory-opencode-typecheck = self.packages.${system}.opencode-kfactory.overrideAttrs (old: {
          pname = "factory-opencode-typecheck";
          buildPhase = ''
            runHook preBuild
            cd packages/opencode
            # tsc exits non-zero on any TS error; capture and post-filter
            # the known opencode-upstream noise so only patch-induced
            # errors fail the check.
            log=$(./node_modules/.bin/tsc --noEmit 2>&1 || true)
            echo "$log"
            # Known upstream issue: opencode's packages/core/src/filesystem.ts
            # imports `mime-types` without an @types/mime-types dep declared,
            # so tsc reports TS7016 every time. Not our patch; filter it.
            # If THIS pattern stops appearing in upstream (they add the types
            # package), the grep will be a no-op -- no harm.
            patch_errs=$(echo "$log" | grep "error TS" | grep -v "filesystem.ts.*mime-types" || true)
            if [ -n "$patch_errs" ]; then
              echo "factory-opencode-typecheck: patch-induced type errors:" >&2
              echo "$patch_errs" >&2
              exit 1
            fi
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            touch $out
            runHook postInstall
          '';
          postInstall = "";
          doInstallCheck = false;
        });
      });
  };
}
