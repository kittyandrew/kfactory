{
  # Keep in sync with inputs.opencode.url in flake.nix; replay fixtures
  # assert against this so opencode bumps cannot silently keep stale DB fixtures.
  opencodeVersion = "v1.17.4";

  opencodePatchStack = [
    # Bun-version build workaround; deletion condition lives in the patch header.
    ../../patches/opencode-bun-version-relax.patch
    ../../patches/opencode-static-bearer.patch
    ../../patches/opencode-workspace-routing.patch
    ../../patches/opencode-kfactory-refresh.patch
  ];

  # Per-plugin source + npm deps hash. To refresh the hash after a
  # package-lock.json change:
  #   nix shell nixpkgs#prefetch-npm-deps -c prefetch-npm-deps \
  #     plugins/<name>/package-lock.json
  pluginSrcs = {
    kfactory-adapter = {
      src = ../../plugins/kfactory-adapter;
      npmDepsHash = "sha256-lUlCrlOTwN4R/Pr7dO9yS2uMl30Y0c9vdOUFhe+i55Q=";
    };
    ntfy = {
      src = ../../plugins/ntfy;
      npmDepsHash = "sha256-zvCJCA8KS2mlBo0JI0O7Nq54JZ8KvdhkCC67r5VK3R4=";
    };
    loop = {
      src = ../../plugins/loop;
      npmDepsHash = "sha256-gQxcx+5LOwMlulZKA/7SrP7iL47fG1tQLh2jbI/Klbw=";
      keepNodeModules = true;
    };
  };

  # Per-third-party-plugin source + npm deps hash. Carriers live
  # under plugins/<name>/ (manifest-only; no src/). Adding an entry
  # here auto-registers:
  #   - internal package (via mkThirdPartyPlugin)
  #   - `factory-<name>-smoke` flake check (via mkThirdPartyPluginSmoke)
  #   - opencode.json plugin-list entry inside the regression tests image
  # Bumping any of these follows .claude/rules/050-third-party-nix-plugins.md.
  thirdPartyPluginSrcs = {
    opencode-pty = {
      packageName = "@josxa/opencode-pty";
      version = "0.7.1";
      src = ../../plugins/opencode-pty;
      npmDepsHash = "sha256-cO5SFt3hJdNmLiGZ3EJeFOAFT6BVQai4cLAFWJ/ICYg=";
      postInstallCommands = ''
        substituteInPlace "$out/dist/src/plugin/pty/notification-manager.js" \
          --replace-fail "    return elapsedMs <= FAST_EXIT_INTERRUPT_MS;" "    return false;"
      '';
    };
  };
}
