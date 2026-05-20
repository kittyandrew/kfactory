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

      # opencode-kfactory: opencode with both patches applied + the
      # experimental-workspaces env var baked into the wrapper, so the
      # workspace-routing middleware (added by the patches) is actually
      # exercised at runtime. Consumers using the raw `patches.*` exports
      # are responsible for setting OPENCODE_EXPERIMENTAL_WORKSPACES
      # themselves.
      opencode-kfactory = opencode.packages.${system}.default.overrideAttrs (old: {
        # @WARNING: DO NOT REORDER. opencode-kfactory-refresh.patch is
        #   line-pinned against opencode-bearer-and-routing.patch's
        #   post-apply hashes; its hunks have context lines that include
        #   the first patch's additions. Reordering will make `patch`
        #   reject loudly or fuzzy-apply at the wrong offset.
        patches =
          (old.patches or [])
          ++ [
            ./patches/opencode-bearer-and-routing.patch
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
    #     patches = (old.patches or []) ++ [
    #       inputs.kfactory.patches.opencode-bearer-and-routing
    #       inputs.kfactory.patches.opencode-kfactory-refresh  # optional
    #     ];
    #   });
    #
    # @WARNING: DO NOT REORDER the two opencode patches. opencode-kfactory-refresh
    #   is line-pinned against opencode-bearer-and-routing's post-apply hashes;
    #   its hunks have context lines that include the first patch's additions.
    #   Apply in the order shown above or `patch` will reject loudly (or worse,
    #   fuzzy-apply at the wrong offset). Consumers who only want the
    #   upstreamable subset may include just opencode-bearer-and-routing.
    patches = {
      opencode-bearer-and-routing = ./patches/opencode-bearer-and-routing.patch;
      opencode-kfactory-refresh = ./patches/opencode-kfactory-refresh.patch;
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
            patch1 = ./patches/opencode-bearer-and-routing.patch;
            patch2 = ./patches/opencode-kfactory-refresh.patch;
            nativeBuildInputs = [pkgs.patch];
          } ''
            cp -R "$src" ./opencode
            chmod -R +w ./opencode
            cd ./opencode
            # Apply BOTH patches for real in sequence -- mirrors how
            # opencode-kfactory's configurePhase applies them, and
            # catches cases where patch2 dry-runs cleanly but real
            # apply fails (e.g., overlapping hunks at the same offset).
            # The resulting tree is discarded; only the success/failure
            # of patch -p1 matters.
            patch -p1 < "$patch1"
            patch -p1 < "$patch2"
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

        # factory-plugin-token-discipline -- enforces the constants-block
        # rule from `.claude/rules/010-plugin.md`: `pkgs.replaceVars`'s
        # checkPhase fails on ANY leftover `@xxx@` pattern at build time,
        # so placeholders may only appear in the dedicated constants block
        # near the top of factory-adapter.ts. This check catches violations
        # earlier (CI fails on the cheap grep instead of the more expensive
        # build that would fail anyway).
        factory-plugin-token-discipline =
          pkgs.runCommand "factory-plugin-token-discipline" {
            adapter = ./plugin/factory-adapter.ts;
          } ''
            # The constants block lives between the `// ---- Nix-substituted`
            # marker comment and the next `// ----` section header. Anything
            # `@[A-Z_]+@` outside that range is forbidden.
            awk '
              /^\/\/ ---- Nix-substituted/ { inblock=1; next }
              inblock && /^\/\/ ----/      { inblock=0 }
              !inblock && /@[A-Z_]+@/      { print FILENAME":"NR": forbidden placeholder: "$0; bad=1 }
              END { exit bad }
            ' "$adapter"
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
        # type-semantic drift inside the bearer-auth + refresh patches
        # was not caught by CI (bun's bundler strips types without
        # checking).
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
