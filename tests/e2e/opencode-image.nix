# OCI image for the e2e tests' opencode-kfactory container.
#
# Bundles:
#   - opencode-kfactory binary (the patched opencode from this flake)
#   - All three plugins via plugins.${system}.* outputs
#   - opencode.json wired to load the plugins by absolute store path
#   - notification-ntfy.json wired for the ntfy container + 3s notifyAfter
#   - git + openssh + cacert because the kfactory-adapter plugin shells
#     out to `git clone` over https / ssh
#
# Run via `dev-up`; serves on container port 4096, exposed to host as
# configured in tests/e2e/dev-env.nix.
{
  pkgs,
  opencode-kfactory,
  opencode-heal,
  opencode-sync-kick,
  plugins,
  thirdPartyPlugins,
  testRepo,
}: let
  # Build opencode.json inline from Nix values. opencode's
  # PluginLoader resolves directory paths via package.json's
  # exports["./server"], so each list entry is the package root's
  # /nix/store/... path. Iterating over `plugins` + `thirdPartyPlugins`
  # means adding a new plugin (kfactory-owned or third-party) flows
  # through flake.nix wiring, not through a placeholder list in this
  # file. Static knobs (permission policy) read from
  # ./configs/opencode-base.json so operators can tweak them without
  # touching Nix.
  opencodeBase = builtins.fromJSON (builtins.readFile ./configs/opencode-base.json);
  pluginStorePaths =
    map (p: "${p}") (builtins.attrValues plugins)
    ++ map (p: "${p}") (builtins.attrValues thirdPartyPlugins);
  # `opencodeBase` MUST NOT declare a `plugin` field -- the merge below
  # would silently overwrite it. The plugin list is the one structural
  # output this file owns; the base JSON file is for orthogonal knobs
  # (permission policy, etc.). Fail-loud on accidental drift instead
  # of letting an operator wonder why their hand-pasted plugin entry
  # vanished.
  opencodeJson = assert !(opencodeBase ? plugin);
    pkgs.writeText "opencode.json" (builtins.toJSON (opencodeBase
      // {
        plugin = pluginStorePaths;
      }));

  # Entrypoint: small wrapper that exports the env the kfactory-adapter
  # plugin needs (otherwise it falls back to defaults that won't work in
  # this image -- git/ssh wouldn't be on a scratch image's PATH) and
  # execs opencode serve on all interfaces so the kfactory-cli container
  # can reach it via the Docker bridge.
  entrypoint = pkgs.writeShellScript "kfactory-opencode-entrypoint" ''
    set -e
    # Paths the kfactory-adapter plugin's runtime config consumes.
    # Aligns with the env-var contract documented in
    # plugins/kfactory-adapter/src/index.ts.
    export KFACTORY_ADAPTER_GIT="${pkgs.git}/bin/git"
    export KFACTORY_ADAPTER_OPENSSH_SSH="${pkgs.openssh}/bin/ssh"
    export KFACTORY_ADAPTER_WORKSPACES_DIR="/var/lib/kfactory/workspaces"
    # Without this the workspace-routing middleware patched in via
    # opencode-bearer-and-routing is dormant; routing falls back to
    # opencode's default project resolution.
    export OPENCODE_EXPERIMENTAL_WORKSPACES=true
    # Bind to 0.0.0.0 so docker port-publish + bridge-network peers
    # (kfactory-cli) can reach us. No password set => warning logged +
    # server runs unsecured; that's exactly what the e2e tests wants
    # (skipping the OIDC stack for E2E debugging).
    mkdir -p "$KFACTORY_ADAPTER_WORKSPACES_DIR"
    exec ${opencode-kfactory}/bin/opencode serve --hostname 0.0.0.0 --port 4096
  '';
in
  pkgs.dockerTools.buildLayeredImage {
    name = "kfactory-opencode";
    tag = "dev";
    # Tools the patched opencode + plugins need at runtime:
    #   - opencode-kfactory: the binary itself + its wrapped bun runtime.
    #   - git + openssh: kfactory-adapter clones via `git clone`.
    #   - cacert: TLS verification for `git clone https://...`.
    #   - coreutils + bash: entrypoint shell + small env setup.
    #   - opencode-heal + opencode-sync-kick: lifecycle scripts the
    #     `services.kfactory.recovery` module wires as ExecStartPre /
    #     ExecStartPost on the opencode-serve unit. The e2e tests exec
    #     them directly via `docker exec` to validate the round-trip
    #     end-to-end (no systemd in the test environment).
    #   - sqlite: lets the e2e harness simulate a "stuck assistant turn"
    #     by UPDATE-ing the DB to clear `time.completed` -- the stuck
    #     state heal is supposed to catch. Bundling here (vs in the
    #     kfactory-cli image) keeps the DB-manipulation co-located with
    #     the DB volume; the cli container can't reach it.
    contents = [
      opencode-kfactory
      opencode-heal
      opencode-sync-kick
      pkgs.git
      pkgs.openssh
      pkgs.cacert
      pkgs.coreutils
      pkgs.bash
      pkgs.sqlite
    ];
    # `/root/.config/opencode/{opencode,notification-ntfy}.json` is where
    # opencode and the ntfy plugin look (per opencode's config.ts
    # candidates + plugins/ntfy/src/config.ts configPath()). Drop them
    # there at image-build time.
    extraCommands = ''
      mkdir -p root/.config/opencode
      cp ${opencodeJson} root/.config/opencode/opencode.json
      cp ${./configs/notification-ntfy.json} root/.config/opencode/notification-ntfy.json
      # Test repo bundled inside the image so kfactory-adapter can
      # `git clone file:///srv/test-repo.git` without network access.
      # Same repo lives at /srv/test-repo.git in the kfactory-cli image
      # for symmetry; both are produced by tests/e2e/test-repo.nix.
      mkdir -p srv
      cp -r ${testRepo} srv/test-repo.git
      # opencode + bun need a /tmp dir; layered image is otherwise scratch.
      mkdir -m 0777 tmp
    '';
    config = {
      Entrypoint = ["${entrypoint}"];
      ExposedPorts = {"4096/tcp" = {};};
      Env = [
        "HOME=/root"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        # opencode's PluginLoader runs `await import()` on the entrypoint
        # path; node resolves that via the file:// URL. Bun's runtime
        # transpiles the .ts files in-place.
      ];
      Healthcheck = {
        # The cheapest opencode endpoint that proves the server is up
        # and the bearer-auth patch is loaded. Returns 200 with [] for
        # an empty workspace list; that's enough to confirm liveness.
        Test = [
          "CMD"
          "${pkgs.curl}/bin/curl"
          "-sf"
          "-H"
          "Authorization: Bearer e2e-fake-bearer"
          "http://localhost:4096/experimental/workspace"
        ];
        Interval = 5000000000; # 5s in ns (Docker's unit)
        Timeout = 3000000000;
        Retries = 12; # 60s window before unhealthy
      };
    };
  }
