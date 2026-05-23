# [4c/9] listByProject workspaceID filter regression.
#
# Sessions stamped with workspace's hashed project_id at INSERT (POST
# /session forwards to the workspace instance); GET /session stays in
# the front-opencode where ctx.project.id="global". Pre-fix
# listByProject AND'd both → 0 rows. Fix (bearer-and-routing.patch):
# when workspaceID is set, filter only by workspace_id.
#
# Pre-fix symptom: TUI --continue silently lands on home view (or on
# unpatched opencode, picks the globally most-recent session). 4b/9's
# `?directory=` shape was falsely green -- it triggers project
# re-resolution that updates ctx.project.id to the hash. The TUI uses
# `?path=` (empty when worktree==directory) which takes the buggy
# path; this phase replicates that.

echo
echo "[4c/9] listByProject filter for the TUI's session.list shape..."

# Premise: sessions stamped with workspace's HASHED project_id (not
# 'global'). If upstream changes that, the bug dissolves.
WS1_SESS_PID=$(ocexec sqlite3 "$OPENCODE_DB" \
  "SELECT project_id FROM session WHERE workspace_id='$WS1' LIMIT 1;")
echo "      → session.project_id for WS1: $WS1_SESS_PID"
if [ "$WS1_SESS_PID" = "global" ]; then
  echo "      ⚠ session.project_id is 'global' -- bug premise may have shifted."
  echo "        listByProject's AND-with-project_id might be safe now; revisit."
fi
if [ -z "$WS1_SESS_PID" ]; then
  echo "      ❌ could not read session.project_id from DB (sqlite probe failed)"
  exit 1
fi

# Replicates sync.tsx's sessionListQuery() when worktree == directory
# (the kfactory-adapter shape): `?path=` + x-opencode-workspace header.
TUI_LEN=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS1" \
  "$OPENCODE_BASE/session?path=" | jq 'length')
if [ "$TUI_LEN" -ge 1 ]; then
  echo "      ✓ /session?path= returned $TUI_LEN session(s) for WS1"
else
  echo "      ❌ /session?path= returned 0 sessions for WS1."
  echo "         The session row exists in the DB but listByProject's"
  echo "         AND with ctx.project.id='global' filters it out (session"
  echo "         is stamped with the workspace's hashed project_id, not"
  echo "         'global'). The workspaceID-supersedes-projectID fix in"
  echo "         opencode-bearer-and-routing.patch (listByProject hunk)"
  echo "         is missing or regressed."
  exit 1
fi

# scope=project (the kv-disabled-filter fallback in sessionListQuery).
SCOPE_LEN=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS1" \
  "$OPENCODE_BASE/session?scope=project" | jq 'length')
if [ "$SCOPE_LEN" -ge 1 ]; then
  echo "      ✓ /session?scope=project returned $SCOPE_LEN session(s) for WS1"
else
  echo "      ❌ /session?scope=project returned 0 for WS1 (same bug)"
  exit 1
fi
