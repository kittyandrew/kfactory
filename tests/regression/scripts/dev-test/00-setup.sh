# Setup: container precondition + shared helpers + env. Sourced first
# by every other phase; all later phases assume these names are bound.
#
# Inherits CLI_CONTAINER / OPENCODE_CONTAINER / NTFY_PORT / NTFY_TOPIC
# from the driver (exported at the top of the concatenated script
# from dev-env.nix Nix-eval-time values).
#
# `cli` runs commands inside the kfactory-cli container with stdin
# attached so heredocs forward correctly (`docker exec -i`). Named
# `cli` rather than `exec` because `exec` is a shell builtin that
# replaces the current process -- shadowing it would silently break
# any future `exec foo` line in the harness.

if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker not found. Run dev-up first."
  exit 1
fi

if ! docker ps -q --filter "name=^${CLI_CONTAINER}$" | grep -q .; then
  echo "ERROR: $CLI_CONTAINER not running. Run 'nix run .#dev-up' first."
  exit 1
fi

cli() { docker exec -i "$CLI_CONTAINER" "$@"; }
# Background (detached) variant -- used by phases that spawn a long-
# lived process inside the cli container (e.g. an SSE subscriber or
# an ntfy listener) and pick the output back up later from /tmp.
cli_d() { docker exec -d "$CLI_CONTAINER" "$@"; }
ocexec() { docker exec "$OPENCODE_CONTAINER" "$@"; }

REPO="file:///srv/test-repo.git"
NTFY_URL="http://localhost:${NTFY_PORT}"
TOPIC="$NTFY_TOPIC"
# The bearer the opencode container's healthcheck accepts (server
# runs unauthenticated; any non-empty bearer passes). Same value
# baked into tests/regression/configs/auth.json.
TOKEN="regression-fake-bearer"
OPENCODE_DB=/root/.local/share/opencode/opencode.db
OPENCODE_BASE="http://${OPENCODE_CONTAINER}:4096"

# Phase scripts share one bash file (writeShellApplication concatenates
# them in lex order), so a variable set in 02-dispatch.sh is visible
# in 09-recovery.sh. No pre-declarations needed -- shellcheck reads
# the concatenated whole, not each phase in isolation.

echo
echo "========================================================"
echo " kfactory regression validation"
echo "========================================================"
