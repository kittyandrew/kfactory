# OCI image: kfactory CLI + opencode-kfactory (TUI runs in this
# container, operator gets it via `docker exec -it`); pre-staged
# ~/.config/kfactory/auth.json with far-future expiry so ensureFresh
# skips OIDC; bare /srv/test-repo.git for network-free dispatch.
# Entrypoint sleeps; operator drives via `docker exec`.
{
  pkgs,
  kfactory,
  opencode-kfactory,
  testRepo,
}: let
  entrypoint = pkgs.writeShellScript "kfactory-cli-entrypoint" ''
    set -e
    echo "kfactory-cli container ready."
    echo "Drive via: docker exec -it kfactory-cli kfactory <subcommand>"
    # `tail -f /dev/null` portable "sleep forever" that respects SIGTERM.
    exec tail -f /dev/null
  '';
in
  pkgs.dockerTools.buildLayeredImage {
    name = "kfactory-cli";
    tag = "dev";
    contents = [
      kfactory
      opencode-kfactory
      pkgs.git
      pkgs.openssh
      pkgs.cacert
      pkgs.bash
      pkgs.coreutils
      pkgs.jq
      pkgs.curl
    ];
    extraCommands = ''
      mkdir -p root/.config/kfactory
      cp ${./configs/auth.json} root/.config/kfactory/auth.json
      chmod 0600 root/.config/kfactory/auth.json
      mkdir -p srv
      cp -r ${testRepo} srv/test-repo.git
      mkdir -m 0777 tmp
    '';
    config = {
      Entrypoint = ["${entrypoint}"];
      WorkingDir = "/root";
      Env = [
        "HOME=/root"
        "XDG_CONFIG_HOME=/root/.config"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        # Default for non-interactive smoke tests; `docker exec -it`
        # overrides from the host shell.
        "TERM=xterm-256color"
      ];
    };
  }
