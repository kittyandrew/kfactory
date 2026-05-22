{pkgs}: let
  env = import ../dev-env.nix;
in
  pkgs.writeShellApplication {
    name = "dev-down";
    # `docker` is bin-only here -- the script talks to whatever daemon
    # is on the host (typically /var/run/docker.sock). docker-client
    # is the slim CLI-only derivation and is fine for that.
    runtimeInputs = [pkgs.docker-client];
    text = ''
      if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker not found"
        exit 1
      fi
      echo "Stopping containers..."
      for c in ${env.cliContainer} ${env.opencodeContainer} ${env.ntfyContainer}; do
        if docker ps -aq --filter "name=^$c$" | grep -q .; then
          docker stop "$c" >/dev/null 2>&1 || true
          docker rm "$c" >/dev/null 2>&1 || true
          echo "  → $c stopped + removed"
        fi
      done
      echo "Network + volumes preserved (use dev-clean to wipe)."
    '';
  }
