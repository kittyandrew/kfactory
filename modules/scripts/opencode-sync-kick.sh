# opencode-sync-kick: workaround for opencode's "workspace status only
# syncs on SPA init" wart. Polls /global/health, iterates workspaces,
# POSTs /sync/start per each. Per-workspace failures are logged and
# the loop continues -- one-shot, no retry-with-backoff (the 30s
# health poll covers the opencode-not-ready case; a per-workspace
# failure degrades gracefully to "first interaction triggers sync
# naturally").
#
# Wiring: ExecStartPost on the opencode-serve unit via the recovery
# module. Tests exec this script directly inside the opencode container.
#
# Usage: opencode-sync-kick --base <URL> [--health-timeout <SECONDS>]

BASE=""
HEALTH_TIMEOUT=30
while [ $# -gt 0 ]; do
  case $1 in
    --base)
      BASE=$2
      shift 2
      ;;
    --health-timeout)
      HEALTH_TIMEOUT=$2
      shift 2
      ;;
    --help | -h)
      echo "usage: opencode-sync-kick --base <URL> [--health-timeout <SECONDS>]"
      exit 0
      ;;
    *)
      echo "opencode-sync-kick: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done
if [ -z "$BASE" ]; then
  echo "opencode-sync-kick: --base is required" >&2
  exit 2
fi

# Poll health. opencode binds internal API; the VM-internal path is
# unauthenticated by design (reverse proxy is the auth boundary).
for i in $(seq 1 "$HEALTH_TIMEOUT"); do
  if curl -fsS -m 2 "$BASE/global/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [ "$i" -eq "$HEALTH_TIMEOUT" ]; then
    echo "opencode-sync-kick: opencode did not become healthy in ${HEALTH_TIMEOUT}s" >&2
    exit 1
  fi
done

IDS=$(curl -fsS -m 5 "$BASE/experimental/workspace" | jq -r '.[].id')
if [ -z "$IDS" ]; then
  echo "opencode-sync-kick: no workspaces to kick"
  exit 0
fi
kicked=0
for wid in $IDS; do
  if curl -fsS -m 5 -X POST "$BASE/sync/start?workspace=$wid" >/dev/null; then
    kicked=$((kicked + 1))
  else
    echo "opencode-sync-kick: failed to kick $wid" >&2
  fi
done
echo "opencode-sync-kick: kicked $kicked workspace(s)"
