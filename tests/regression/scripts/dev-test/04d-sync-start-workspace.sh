# [4d] sync/start?workspace= populates status -- regression for the
# project_id divergence in SyncHttpApi.start. Same class as the
# listByProject fix in opencode-bearer-and-routing.patch (phase 4c):
# routed instance's project.id is the worktree-hash but
# WorkspaceTable.project_id="global" everywhere -- query matches 0,
# setStatus never fires, status stays []. TUI then refuses attach
# with DialogWorkspaceUnavailable.
#
# Earlier phases populate connections via the create-path's internal
# startSync; restart wipes it. After the assertion, re-populate via
# the no-workspace-param path (project_id="global") for downstream.

echo
echo "[4d] /sync/start?workspace= populates status..."

# Mirrors a real opencode-serve restart: DB stays, in-memory state wipes.
docker restart "$OPENCODE_CONTAINER" >/dev/null
for _ in $(seq 1 30); do
  if cli curl -fsS -m 2 "$OPENCODE_BASE/global/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Premise check: connections map MUST be empty post-restart; if state
# leaks across restarts the test no longer exercises the bug.
PRE_STATUS=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  "$OPENCODE_BASE/experimental/workspace/status" | jq 'length')
if [ "$PRE_STATUS" != "0" ]; then
  echo "      ⚠ status not empty after restart (len=$PRE_STATUS) -- premise shifted, skipping"
  exit 0
fi

# THE assertion: post-fix status[WS1] populates; pre-fix stays [].
START_RESP=$(cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  "$OPENCODE_BASE/sync/start?workspace=$WS1")
if [ "$START_RESP" != "true" ]; then
  echo "      ❌ /sync/start?workspace=$WS1 did not return 'true' (got: $START_RESP)"
  exit 1
fi

# Up-to-5s poll for WS1 to appear. Pre-fix it never will.
WS1_STATUS=""
for _ in $(seq 1 10); do
  WS1_STATUS=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
    "$OPENCODE_BASE/experimental/workspace/status" \
    | jq -r ".[] | select(.workspaceID==\"$WS1\") | .status")
  if [ -n "$WS1_STATUS" ]; then break; fi
  sleep 0.5
done

if [ "$WS1_STATUS" = "connected" ]; then
  echo "      ✓ WS1 status='connected' after /sync/start?workspace=$WS1"
elif [ -z "$WS1_STATUS" ]; then
  echo "      ❌ WS1 absent from /experimental/workspace/status after sync/start"
  echo "         The workspace-routing middleware routed to WS1's instance,"
  echo "         whose project.id is the worktree-hashed value (e.g."
  echo "         f58b62...). sync.ts calls startWorkspaceSyncing(project.id)"
  echo "         which queries WorkspaceTable WHERE project_id=<hash>, but"
  echo "         every WorkspaceTable row has project_id='global' (set by"
  echo "         the kfactory-adapter at create-time). Query returns 0,"
  echo "         iteration never runs, setStatus never fires."
  echo "         The startWorkspaceSyncing workspaceID-opt fix in"
  echo "         patches/opencode-bearer-and-routing.patch (the bullet"
  echo "         pointing at SyncHttpApi.start in the patch preamble) is"
  echo "         missing or regressed."
  exit 1
else
  echo "      ❌ WS1 status='$WS1_STATUS' (expected 'connected')"
  exit 1
fi

# Restore the map via the no-workspace-param path for downstream phases.
cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  "$OPENCODE_BASE/sync/start" >/dev/null
