{pkgs}: let
  env = import ../e2e/dev-env.nix;
in
  pkgs.writeShellApplication {
    name = "dev-down";
    runtimeInputs = [pkgs.docker-client];
    text = ''
      if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker not found"
        exit 1
      fi
      echo "Stopping containers..."
      for c in ${env.clientContainer} ${env.opencodeContainer} ${env.ntfyContainer}; do
        if docker ps -aq --filter "name=^$c$" | grep -q .; then
          docker stop "$c" >/dev/null 2>&1 || true
          docker rm "$c" >/dev/null 2>&1 || true
          echo "  → $c stopped + removed"
        fi
      done
      echo "Network + volumes preserved (use dev-clean to wipe)."
    '';
  }
