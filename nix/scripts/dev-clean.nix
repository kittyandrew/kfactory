{pkgs}: let
  env = import ../e2e/dev-env.nix;
in
  pkgs.writeShellApplication {
    name = "dev-clean";
    runtimeInputs = [pkgs.docker-client];
    text = ''
      if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker not found"
        exit 1
      fi
      echo "Stopping any running containers..."
      for c in ${env.clientContainer} ${env.opencodeContainer} ${env.ntfyContainer}; do
        docker stop "$c" >/dev/null 2>&1 || true
        docker rm "$c" >/dev/null 2>&1 || true
      done
      echo "Removing volumes..."
      docker volume rm ${env.volumes.opencodeData} >/dev/null 2>&1 || true
      echo "Removing network..."
      docker network rm ${env.network} >/dev/null 2>&1 || true
      echo "Removing loaded images..."
      docker rmi ${env.images.opencode} >/dev/null 2>&1 || true
      docker rmi ${env.images.client} >/dev/null 2>&1 || true
      echo "Clean."
    '';
  }
