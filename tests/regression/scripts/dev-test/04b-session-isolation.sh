# [4b/9] Per-workspace /session isolation -- listByProject workspaceID
# filter regression. Without the filter, workspaces sharing project_id
# collapse to one result list and --continue lands on the same session.
# Hits the TUI's actual /session (not /experimental/session) +
# `?directory=` shape with the x-opencode-workspace header.

echo
echo "[4b/9] Per-workspace session-list isolation (the bug --continue triggers)..."
WS1_DIR=$(cli curl -sf -H "Authorization: Bearer $TOKEN" -H "x-opencode-workspace: $WS1" \
  "$OPENCODE_BASE/project" | jq -r '.[] | select(.vcs == "git") | .worktree')
WS2_DIR=$(cli curl -sf -H "Authorization: Bearer $TOKEN" -H "x-opencode-workspace: $WS2" \
  "$OPENCODE_BASE/project" | jq -r '.[] | select(.vcs == "git") | .worktree')
WS1_SESS=$(cli curl -sf -H "Authorization: Bearer $TOKEN" -H "x-opencode-workspace: $WS1" \
  "$OPENCODE_BASE/session?directory=$WS1_DIR" \
  | jq -r '.[].workspaceID' | sort -u)
WS2_SESS=$(cli curl -sf -H "Authorization: Bearer $TOKEN" -H "x-opencode-workspace: $WS2" \
  "$OPENCODE_BASE/session?directory=$WS2_DIR" \
  | jq -r '.[].workspaceID' | sort -u)
if [ "$WS1_SESS" = "$WS1" ]; then
  echo "      ✓ /session?directory header=$WS1 returned only WS1 sessions"
else
  echo "      ❌ /session for WS1 returned workspace ids: $WS1_SESS (expected only $WS1)"
  echo "         opencode-bearer-and-routing listByProject filter regressed."
  exit 1
fi
if [ "$WS2_SESS" = "$WS2" ]; then
  echo "      ✓ /session?directory header=$WS2 returned only WS2 sessions"
else
  echo "      ❌ /session for WS2 returned workspace ids: $WS2_SESS (expected only $WS2)"
  exit 1
fi
# Adversarial probe: mismatched header+directory must still respect header.
ADVERSARY=$(cli curl -sf -H "Authorization: Bearer $TOKEN" -H "x-opencode-workspace: $WS1" \
  "$OPENCODE_BASE/session?directory=$WS2_DIR" \
  | jq -r '.[].workspaceID' | sort -u)
if [ "$ADVERSARY" = "$WS1" ] || [ -z "$ADVERSARY" ]; then
  echo "      ✓ mismatched header+directory respects workspace header"
else
  echo "      ❌ adversarial probe leaked: $ADVERSARY (expected $WS1 or empty)"
  exit 1
fi
