{pkgs}: let
  env = import ../dev-env.nix;
in
  pkgs.writeShellApplication {
    name = "dev-up";
    # writeShellApplication PREPENDS runtimeInputs to PATH (not
    # replaces) -- the host's `nix` from /run/current-system stays
    # reachable so we can `nix build` from within.
    runtimeInputs = [pkgs.docker-client pkgs.curl pkgs.git];
    text = ''
      cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

      if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker not found. On NixOS: virtualisation.docker.enable = true"
        exit 1
      fi

      echo "[1/5] Building OCI images via Nix..."
      opencode_img=$(nix build .#opencode-image --no-link --print-out-paths -L)
      cli_img=$(nix build .#kfactory-cli-image --no-link --print-out-paths -L)
      docker load < "$opencode_img" 2>&1 | tail -1
      docker load < "$cli_img" 2>&1 | tail -1

      echo "[2/5] Creating network + volumes..."
      docker network create ${env.network} 2>/dev/null || true
      docker volume create ${env.volumes.opencodeData} >/dev/null 2>&1 || true

      start_if_needed() {
        local name="$1"; shift
        if docker ps -q --filter "name=^''${name}$" | grep -q .; then
          echo "      → $name (already running)"
        elif docker ps -aq --filter "name=^''${name}$" | grep -q .; then
          docker start "$name" >/dev/null
          echo "      → $name (restarted)"
        else
          docker run "$@" >/dev/null
          echo "      → $name (created)"
        fi
      }

      echo "[3/5] Starting ntfy + opencode + kfactory-cli..."

      # @NOTE: ntfy image is `:latest`, not pinned by digest. Bump via
      #   `docker pull binwiederhier/ntfy:latest && docker inspect ... | jq '.[0].RepoDigests'`
      start_if_needed ${env.ntfyContainer} \
        -d --name ${env.ntfyContainer} \
        --network ${env.network} \
        -p ${toString env.ports.ntfy}:80 \
        -e NTFY_BASE_URL=http://localhost:${toString env.ports.ntfy} \
        -e NTFY_BEHIND_PROXY=false \
        -e NTFY_LISTEN_HTTP=:80 \
        binwiederhier/ntfy:latest serve

      printf "      → waiting for ntfy..."
      for i in $(seq 1 20); do
        if curl -sf "http://localhost:${toString env.ports.ntfy}/v1/health" >/dev/null 2>&1; then
          echo " ready"
          break
        fi
        [ "$i" -eq 20 ] && echo " TIMEOUT" && exit 1
        sleep 1
      done

      # OPENCODE_EXPERIMENTAL_WORKSPACES is baked into the image's entrypoint.
      start_if_needed ${env.opencodeContainer} \
        -d --name ${env.opencodeContainer} \
        --network ${env.network} \
        -v ${env.volumes.opencodeData}:/root/.local/share/opencode \
        -p ${toString env.ports.opencode}:4096 \
        ${env.images.opencode}

      printf "      → waiting for opencode..."
      # Poll Docker's own Healthcheck (see opencode-image.nix). 90×2s=3min
      # budget covers first-boot's sqlite migration (~30s); subsequent
      # dev-ups come up in seconds.
      for i in $(seq 1 90); do
        status=$(docker inspect --format='{{.State.Health.Status}}' \
          ${env.opencodeContainer} 2>/dev/null || echo "unknown")
        if [ "$status" = "healthy" ]; then
          echo " ready"
          break
        fi
        [ "$i" -eq 90 ] && echo " TIMEOUT (status=$status; docker logs ${env.opencodeContainer})" && exit 1
        sleep 2
      done

      # Idle container; drive via `docker exec`. No port mapping.
      start_if_needed ${env.cliContainer} \
        -d --name ${env.cliContainer} \
        --network ${env.network} \
        ${env.images.cli}

      echo "[4/5] Smoke check..."
      if docker exec ${env.cliContainer} kfactory list 2>&1 | grep -q "no workspaces\|^#"; then
        echo "      → kfactory list works against opencode"
      else
        echo "      → WARNING: kfactory list unexpected output"
        docker exec ${env.cliContainer} kfactory list || true
      fi

      echo "[5/5] Done!"
      echo ""
      echo "  ┌────────────────────────────────────────────────────────────┐"
      echo "  │ Manual test sequence:                                      │"
      echo "  │                                                            │"
      echo "  │  ntfy UI:    http://localhost:${toString env.ports.ntfy}/${env.ntfyTopic}  │"
      echo "  │  opencode:   http://localhost:${toString env.ports.opencode}                       │"
      echo "  │                                                            │"
      echo "  │  Drive kfactory CLI:                                       │"
      echo "  │    docker exec -it ${env.cliContainer} bash               │"
      echo "  │    kfactory dispatch file:///srv/test-repo.git \"say hi\"   │"
      echo "  │    kfactory list                                           │"
      echo "  │    kfactory attach 1   # TUI for first workspace           │"
      echo "  │                                                            │"
      echo "  │  Or run the scripted check:                                │"
      echo "  │    nix run .#dev-test                                      │"
      echo "  │                                                            │"
      echo "  │  Tear down:  nix run .#dev-down                            │"
      echo "  │  Wipe data:  nix run .#dev-clean                           │"
      echo "  └────────────────────────────────────────────────────────────┘"
    '';
  }
