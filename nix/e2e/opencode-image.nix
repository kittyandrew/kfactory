# Regression opencode server image. Run via `dev-up`; host port mapping lives
# in dev-env.nix.
{
  pkgs,
  kfactory,
  testRepo,
}: let
  # Exports the kfactory-adapter env contract (see
  # plugins/kfactory-adapter/src/index.ts) -- absolute paths because
  # git/ssh aren't on a scratch image's PATH. Binds 0.0.0.0 so
  # kfactory client reaches us via the Docker bridge; no password
  # (regression tests skip OIDC).
  entrypoint = pkgs.writeShellScript "kfactory-opencode-entrypoint" ''
    set -e
    export KFACTORY_ADAPTER_WORKSPACES_DIR="/var/lib/kfactory/workspaces"
    mkdir -p "$KFACTORY_ADAPTER_WORKSPACES_DIR"
    exec ${kfactory}/bin/opencode serve --hostname 0.0.0.0 --port 4096
  '';
in
  pkgs.dockerTools.buildLayeredImage {
    name = "kfactory-opencode";
    tag = "dev";
    # Includes clone tools, recovery hooks called by docker exec, and sqlite for
    # harness DB updates.
    contents = [
      kfactory
      kfactory.passthru.opencodeHeal
      kfactory.passthru.opencodeSyncKick
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
      cp ${./configs/notification-ntfy.json} root/.config/opencode/notification-ntfy.json
      # Bundled test repo; client image uses the same file:// path.
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
        # Cheapest endpoint that proves the server is up and the
        # experimental-workspaces surface responds. (The Bearer header is
        # inert here: server-side opencode never validates Bearer.)
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
