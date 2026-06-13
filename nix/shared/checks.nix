{
  pkgs,
  lib ? pkgs.lib,
  system,
  packageAttrs,
  opencode,
  opencodePatchStack,
  opencodeVersion,
  pluginSrcs,
  thirdPartyPluginSrcs,
  components,
}: let
  sharedAttrs = import ./attrs.nix {inherit lib;};
  inherit (sharedAttrs) mergeDisjointAttrs;

  builders = import ./builders.nix;
  inherit (builders) mkPluginIntegrationCheck mkPluginRuntimeArtifactCheck mkPluginTypecheck mkThirdPartyPluginSmoke;

  packageChecks = lib.filterAttrs (name: _: name != "default") packageAttrs;
  pluginChecks = components.pluginPackages;
  thirdPartyPackageChecks = components.thirdPartyPackages;
  internalComponentChecks = {
    factory-opencode-kfactory = components.opencodePatched;
    factory-opencode-heal = components.opencodeHeal;
    factory-opencode-sync-kick = components.opencodeSyncKick;
    factory-e2e-opencode-image = components.opencodeImage;
    factory-e2e-kfactory-client-image = components.kfactoryClientImage;
  };
  pluginTypechecks =
    lib.mapAttrs'
    (name: spec:
      lib.nameValuePair
      "${name}-typecheck"
      (mkPluginTypecheck pkgs ({inherit name;} // spec)))
    pluginSrcs;

  # Auto-generated smoke check per third-party plugin. Adding a
  # new entry to thirdPartyPluginSrcs surfaces a corresponding
  # `factory-<name>-smoke` flake check automatically. The check
  # asserts the package store path imports cleanly and exposes
  # at least one named export.
  thirdPartySmokeChecks =
    lib.mapAttrs'
    (name: _:
      lib.nameValuePair
      "factory-${name}-smoke"
      (mkThirdPartyPluginSmoke pkgs {
        inherit name;
        pkg = components.thirdPartyPackages.${name};
      }))
    thirdPartyPluginSrcs;

  pluginIntegrationChecks =
    lib.mapAttrs'
    (name: spec:
      lib.nameValuePair
      "${name}-integration-typecheck"
      (mkPluginIntegrationCheck pkgs {
        inherit name spec;
        opencodePackage = components.opencodePatched;
      }))
    pluginSrcs;

  pluginRuntimeArtifactChecks =
    lib.mapAttrs'
    (name: spec:
      lib.nameValuePair
      "factory-${name}-runtime-artifact"
      (mkPluginRuntimeArtifactCheck pkgs {
        inherit name;
        pkg = components.pluginPackages.${name};
        keepNodeModules = spec.keepNodeModules or false;
      }))
    pluginSrcs;

  # Dev lifecycle scripts are writeShellApplication-based, which
  # bakes shellcheck into the build. Adding them as checks
  # promotes the shellcheck gate into `nix flake check` (so CI
  # catches shell regressions on every PR, not only when an
  # operator runs `nix run .#dev-*`).
  devScripts = import ../scripts {
    inherit pkgs;
    opencodeImage = components.opencodeImage;
    clientImage = components.kfactoryClientImage;
  };
  devScriptChecks =
    lib.mapAttrs'
    (name: drv:
      lib.nameValuePair "factory-${name}-shellcheck" drv)
    devScripts;
  methodologyChecks = import ../default.nix {
    inherit pkgs pluginSrcs pluginRuntimeArtifactChecks opencodeVersion;
    pluginPackages = components.pluginPackages;
    opencodeHeal = components.opencodeHeal;
    kfactory = components.unified;
    opencodePackage = components.opencodePatched;
  };
in
  mergeDisjointAttrs "checks.${system}" [
    packageChecks
    internalComponentChecks
    pluginChecks
    thirdPartyPackageChecks
    pluginTypechecks
    pluginIntegrationChecks
    pluginRuntimeArtifactChecks
    thirdPartySmokeChecks
    devScriptChecks
    methodologyChecks
    {
      factory-opencode-patch-applies =
        pkgs.runCommand "factory-opencode-patch-applies" {
          src = opencode.outPath;
          patches = opencodePatchStack;
          nativeBuildInputs = [pkgs.patch];
        } ''
          cp -R "$src" ./opencode
          chmod -R +w ./opencode
          cd ./opencode
          # Real (not --dry-run) in-sequence apply mirrors
          # the patched opencode configurePhase -- catches a later
          # patch that dry-runs clean but real-applies wrong (e.g.
          # overlapping hunks at the same offset).
          for patch in $patches; do
            log="$(mktemp)"
            patch -p1 --fuzz=0 < "$patch" 2>&1 | tee "$log"
            if grep -E 'with fuzz|offset [+-]?[0-9]+' "$log" >/dev/null; then
              echo "patch applied with fuzz/offset drift: $patch" >&2
              exit 1
            fi
          done
          touch $out
        '';

      factory-opencode-bun-relax-still-needed = let
        opencodePackage = builtins.fromJSON (builtins.readFile "${opencode.outPath}/package.json");
        requiredBun = lib.removePrefix "bun@" opencodePackage.packageManager;
      in
        pkgs.runCommand "factory-opencode-bun-relax-still-needed" {} ''
          if [ "${pkgs.bun.version}" = "${requiredBun}" ]; then
            echo "nixpkgs bun ${pkgs.bun.version} matches opencode packageManager bun ${requiredBun}" >&2
            echo "delete patches/opencode-bun-version-relax.patch and remove it from opencodePatchStack" >&2
            exit 1
          fi
          touch $out
        '';

      factory-oauth2-proxy-patch-applies =
        pkgs.runCommand "factory-oauth2-proxy-patch-applies" {
          inherit (pkgs.oauth2-proxy) src;
          patch = ../../patches/oauth2-proxy-pkce-no-secret.patch;
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
          completion = ../../completions/_kfactory;
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

      factory-kfactory-config-render =
        pkgs.runCommand "factory-kfactory-config-render" {
          configFile = components.unified.passthru.configFile;
          nativeBuildInputs = [pkgs.gnugrep];
        } ''
          cfg=$configFile
          grep -q '"model"[[:space:]]*:[[:space:]]*"openai/gpt-5.5"' "$cfg"
          grep -q '"permission"[[:space:]]*:' "$cfg"
          grep -q '"compaction"[[:space:]]*:' "$cfg"
          grep -q '"plugin"[[:space:]]*:' "$cfg"
          grep -q 'kfactory-plugin-kfactory-adapter' "$cfg"
          grep -q 'kfactory-plugin-ntfy' "$cfg"
          grep -q 'kfactory-plugin-loop' "$cfg"
          grep -q 'opencode-pty' "$cfg"
          grep -q '"loop"[[:space:]]*:' "$cfg"
          grep -q '"loop-stop"[[:space:]]*:' "$cfg"
          if grep -q '@[A-Z_][A-Z_]*@' "$cfg"; then
            echo "unsubstituted template token in opencode config" >&2
            exit 1
          fi
          touch $out
        '';

      # Typecheck patched opencode with tsc and compare normalized error lines
      # to the checked-in upstream-noise baseline.
      factory-opencode-typecheck = components.opencodePatched.overrideAttrs (_: {
        pname = "factory-opencode-typecheck";
        baseline = ../../checks/factory-opencode-typecheck.baseline;
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
          log=$(${pkgs.nodejs}/bin/node ./node_modules/typescript/bin/tsc --noEmit 2>&1 || true)
          echo "$log"
          # Match only real tsc error lines (file:loc - error TSnnnn:).
          # Avoids picking up prose containing the substring "error TS"
          # in the baseline's header comments.
          errPattern='error TS[0-9]'
          actual=$(printf '%s\n' "$log" \
            | sed -E 's/\x1b\[[0-9;]*m//g' \
            | sed -E 's|/nix/store/[^ ]+-opencode-node_modules-[^/]*/node_modules/|node_modules/|g' \
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
        # patched opencode adds for the binary.
        postInstall = "";
        postFixup = "";
        doInstallCheck = false;
      });
    }
  ]
