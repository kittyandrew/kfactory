# [4d/9] sync/start?workspace= populates status -- regression test
# for the project_id divergence in SyncHttpApi.start.
#
# Root cause: the workspace-routing middleware routes a request with
# `?workspace=<wid>` to the workspace's instance, whose `project.id`
# is the worktree-hashed value (e.g. f58b62...). sync.ts handler
# reads that and calls `workspace.startWorkspaceSyncing(project.id)`,
# which executes:
#   SELECT DISTINCT workspace FROM workspace WHERE project_id = ?
# with `?` = the worktree-hash. But the kfactory-adapter writes
# WorkspaceTable.project_id="global" for every row -- so the query
# matches 0 rows, the iteration never runs, setStatus is never
# called, the in-memory `connections` Map stays empty, and
# /experimental/workspace/status returns []. The TUI then refuses
# attach with DialogWorkspaceUnavailable because store.workspace.status
# is empty.
#
# Same class of bug as the listByProject divergence fixed in
# opencode-bearer-and-routing.patch (phase [4c/9]): when the routing
# middleware has set InstanceState.workspaceID, we must dispatch by
# workspace_id rather than the routed-instance's project_id.
#
# Pre-restart, the connections Map is already populated by earlier
# phases ([2/9] dispatch + the create-path's internal startSync). To
# exercise the bug we have to RESTART opencode-serve to clear the
# in-memory state. After the assertion, we re-populate the map via
# /sync/start (no workspace param -- the project_id="global" path
# that works) so subsequent phases see a healthy server.

echo
echo "[4d/9] /sync/start?workspace= populates status..."

# Restart to clear the in-memory connections Map. Workspaces stay
# in the DB; only the runtime state is wiped -- exactly the shape
# of a real opencode-serve restart.
docker restart "$OPENCODE_CONTAINER" >/dev/null
# Wait for /global/health (mirrors opencode-sync-kick's poll shape).
for _ in $(seq 1 30); do
  if cli curl -fsS -m 2 "$OPENCODE_BASE/global/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Pre-check: status MUST be [] right after restart. If not, the
# connections map persisted somehow (in-memory state leaked across
# restarts) and the test premise dissolves.
PRE_STATUS=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  "$OPENCODE_BASE/experimental/workspace/status" | jq 'length')
if [ "$PRE_STATUS" != "0" ]; then
  echo "      ⚠ status not empty after restart (len=$PRE_STATUS) -- premise shifted, skipping"
  exit 0
fi

# THE assertion: POST /sync/start?workspace=$WS1 then verify status
# now contains WS1. Pre-fix: status stays [] because the iteration
# inside startWorkspaceSyncing(project.id) returns 0 rows.
START_RESP=$(cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  "$OPENCODE_BASE/sync/start?workspace=$WS1")
if [ "$START_RESP" != "true" ]; then
  echo "      ❌ /sync/start?workspace=$WS1 did not return 'true' (got: $START_RESP)"
  exit 1
fi

# Poll for up to 5s for WS1 to appear in status. Pre-fix it never will.
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

# Restore the connections map for subsequent phases via the
# no-workspace-param path that works (project_id="global" iterates
# all 5 rows).
cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  "$OPENCODE_BASE/sync/start" >/dev/null
