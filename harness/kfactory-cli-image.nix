# OCI image for the harness's kfactory-cli container.
#
# Contains:
#   - kfactory binary (the CLI under test)
#   - opencode-kfactory binary (the CLI execs `opencode attach` so the
#     TUI process runs inside this container; operator gets the TUI
#     over `docker exec -it`)
#   - git -- needed because `kfactory dispatch` POSTs a repo URL and
#     the in-process clone happens on the opencode side, but a local
#     bare repo at /srv/test-repo.git provides a network-free target.
#   - bash + coreutils -- for the entrypoint + interactive shell.
#   - Pre-staged ~/.config/kfactory/auth.json with bogus tokens at
#     far-future expiry, so `ensureFresh` short-circuits and the
#     CLI sends a Bearer header without going through OIDC.
#   - A local bare git repo at /srv/test-repo.git -- so the harness
#     never needs the public internet to dispatch a workspace.
#
# The container's entrypoint sleeps forever; operator drives it via
# `docker exec`.
{
  pkgs,
  kfactory,
  opencode-kfactory,
  testRepo,
}: let
  # Entrypoint: keep the container alive so `docker exec` works. The CLI
  # is invoked manually per-test by the operator (or the test script).
  entrypoint = pkgs.writeShellScript "kfactory-cli-entrypoint" ''
    set -e
    echo "kfactory-cli container ready."
    echo "Drive via: docker exec -it kfactory-cli kfactory <subcommand>"
    # `tail -f /dev/null` is a portable "sleep forever" that doesn't
    # ignore SIGTERM, so dev-down can stop the container cleanly.
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
      # Pre-stage auth.json so ensureFresh sees a non-expired token and
      # skips the OIDC refresh entirely. The harness needs this because
      # there's no IdP to talk to.
      mkdir -p root/.config/kfactory
      cp ${./configs/auth.json} root/.config/kfactory/auth.json
      chmod 0600 root/.config/kfactory/auth.json
      # Test repo at /srv/test-repo.git -- dispatch against
      # file:///srv/test-repo.git from inside the container, or against
      # the bind-mounted /srv/test-repo.git on the opencode side.
      mkdir -p srv
      cp -r ${testRepo} srv/test-repo.git
      # opencode TUI uses an alternate screen; needs /tmp.
      mkdir -m 0777 tmp
    '';
    config = {
      Entrypoint = ["${entrypoint}"];
      WorkingDir = "/root";
      Env = [
        "HOME=/root"
        "XDG_CONFIG_HOME=/root/.config"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        # opencode attach (TUI) needs a sensible TERM; the docker exec -it
        # invocation overrides this if the host shell has one, but a
        # default keeps non-interactive smoke tests from breaking.
        "TERM=xterm-256color"
      ];
    };
  }
