# OCI image: opencode-kfactory + all three plugins + opencode.json
# wired to load them + ntfy config + git/openssh/cacert for clones.
# Run via `dev-up`; serves on 4096. Host port mapping in dev-env.nix.
{
  pkgs,
  opencode-kfactory,
  opencode-heal,
  opencode-sync-kick,
  plugins,
  thirdPartyPlugins,
  testRepo,
}: let
  # opencode.json: plugin list is the structural output this file
  # owns; orthogonal knobs (permission policy etc.) come from
  # ./configs/opencode-base.json. Iterating `plugins` + `thirdPartyPlugins`
  # means new plugins register via flake.nix, not via this file.
  opencodeBase = builtins.fromJSON (builtins.readFile ./configs/opencode-base.json);
  pluginStorePaths =
    map (p: "${p}") (builtins.attrValues plugins)
    ++ map (p: "${p}") (builtins.attrValues thirdPartyPlugins);
  # Fail-loud if opencodeBase ever declares `plugin` -- the merge below
  # would silently overwrite.
  opencodeJson = assert !(opencodeBase ? plugin);
    pkgs.writeText "opencode.json" (builtins.toJSON (opencodeBase
      // {
        plugin = pluginStorePaths;
      }));

  # Exports the kfactory-adapter env contract (see
  # plugins/kfactory-adapter/src/index.ts) -- absolute paths because
  # git/ssh aren't on a scratch image's PATH. Binds 0.0.0.0 so
  # kfactory-cli reaches us via the Docker bridge; no password
  # (regression tests skip OIDC).
  entrypoint = pkgs.writeShellScript "kfactory-opencode-entrypoint" ''
    set -e
    export KFACTORY_ADAPTER_GIT="${pkgs.git}/bin/git"
    export KFACTORY_ADAPTER_OPENSSH_SSH="${pkgs.openssh}/bin/ssh"
    export KFACTORY_ADAPTER_WORKSPACES_DIR="/var/lib/kfactory/workspaces"
    # Required so the workspace-routing middleware is live -- without
    # it, opencode falls back to default project resolution.
    export OPENCODE_EXPERIMENTAL_WORKSPACES=true
    mkdir -p "$KFACTORY_ADAPTER_WORKSPACES_DIR"
    exec ${opencode-kfactory}/bin/opencode serve --hostname 0.0.0.0 --port 4096
  '';
in
  pkgs.dockerTools.buildLayeredImage {
    name = "kfactory-opencode";
    tag = "dev";
    # Runtime tools: opencode + bun (wrapped); git + openssh + cacert
    # for kfactory-adapter's `git clone https://...`; coreutils + bash
    # for the entrypoint; opencode-heal + opencode-sync-kick for the
    # recovery lifecycle (the regression tests call them via `docker exec`, no systemd);
    # sqlite for the harness to simulate stuck turns by UPDATE-ing the
    # DB co-located with the volume.
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
    # opencode + the ntfy plugin look in `/root/.config/opencode/`
    # (per opencode's config.ts + plugins/ntfy/src/config.ts).
    extraCommands = ''
      mkdir -p root/.config/opencode
      cp ${opencodeJson} root/.config/opencode/opencode.json
      cp ${./configs/notification-ntfy.json} root/.config/opencode/notification-ntfy.json
      # Bundled test repo: kfactory-adapter clones via
      # file:///srv/test-repo.git without network. Same path in the
      # cli image too (both from tests/regression/test-repo.nix).
      mkdir -p srv
      cp -r ${testRepo} srv/test-repo.git
      # opencode + bun need /tmp; layered image is otherwise scratch.
      mkdir -m 0777 tmp
    '';
    config = {
      Entrypoint = ["${entrypoint}"];
      ExposedPorts = {"4096/tcp" = {};};
      Env = [
        "HOME=/root"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
      Healthcheck = {
        # Cheapest endpoint that proves the server's up AND the
        # bearer-auth patch is loaded.
        Test = [
          "CMD"
          "${pkgs.curl}/bin/curl"
          "-sf"
          "-H"
          "Authorization: Bearer regression-fake-bearer"
          "http://localhost:4096/experimental/workspace"
        ];
        Interval = 5000000000; # 5s in ns (Docker's unit)
        Timeout = 3000000000;
        Retries = 12; # 60s window before unhealthy
      };
    };
  }
