# [4c/9] listByProject + workspaceID filter shape -- regression test
# for the project_id divergence bug.
#
# Root cause: sessions get stamped with the workspace's hashed
# project_id at INSERT (POST /session forwards to the workspace
# instance per server/shared/workspace-routing.ts -- ctx.project.id =
# worktree-derived hash). But GET /session is action:"local" in the
# same routing config -- stays in the front-opencode where
# ctx.project.id = the front project (typically "global"). With the
# pre-fix listByProject AND'ing both, the filter
# `project_id='global' AND workspace_id=<wid>` matches 0 rows, even
# though the workspace's session row exists.
#
# The fix (patches/opencode-bearer-and-routing.patch listByProject
# hunk): when workspaceID is set, filter ONLY by workspace_id.
# Workspace_id is itself a unique scope -- safe to drop project_id.
#
# Pre-fix symptom: TUI's `--continue` sees an empty session list,
# silently lands on the home view (or, on UNPATCHED opencode, picks
# the globally most-recent session regardless of workspace --
# diagnosed in the May 22 kfactory attach 2 / klocc incident).
#
# Why [4b/9]'s `?directory=` shape was falsely green: passing
# `?directory=<workspace-dir>` triggers project re-resolution against
# that directory, accidentally updating ctx.project.id to the hash
# and making the AND match. The TUI does NOT pass `?directory=` --
# it computes `path = relative(worktree, directory)` (empty string
# when worktree == directory) and sends `?path=`, which takes the
# buggy code path. This phase replicates that exact call shape.

echo
echo "[4c/9] listByProject filter for the TUI's session.list shape..."

# Precondition: confirm sessions get stamped with the workspace's
# HASHED project_id (not 'global'). If upstream ever changes that,
# the bug premise dissolves and we'd want to revisit.
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

# THE assertion: TUI's actual session.list shape -- `?path=` with
# x-opencode-workspace header. Replicates sync.tsx's sessionListQuery()
# when worktree == directory (the workspace-root case, which is what
# kfactory-adapter produces).
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

# Also assert scope=project shape (the kv-disabled-filter fallback in
# sessionListQuery): same workspace, same workspace header, must
# still return >=1 session.
SCOPE_LEN=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS1" \
  "$OPENCODE_BASE/session?scope=project" | jq 'length')
if [ "$SCOPE_LEN" -ge 1 ]; then
  echo "      ✓ /session?scope=project returned $SCOPE_LEN session(s) for WS1"
else
  echo "      ❌ /session?scope=project returned 0 for WS1 (same bug)"
  exit 1
fi
