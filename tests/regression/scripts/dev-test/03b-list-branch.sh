# [3b/9] BRANCH column regression: the patched
# /experimental/workspace handler reads .git/HEAD per row server-side
# (single round-trip, not N+1). WorkspaceTable.branch stays NULL
# under kfactory-adapter; the patch fills the field live.

echo
echo "[3b/9] kfactory list BRANCH column..."

# test-repo defaults to "main"; accept any non-empty/non-dash value
# since git defaults can differ.
WS1_BRANCH=$(cli kfactory list 2>/dev/null | tail -n +2 |
  awk -v wid="$WS1" '$2 == wid { print $4 }')
echo "      → WS1 branch column: $WS1_BRANCH"
if [ "$WS1_BRANCH" = "main" ]; then
  echo "      ✓ WS1 shows live branch from .git/HEAD"
elif [ "$WS1_BRANCH" = "-" ] || [ -z "$WS1_BRANCH" ]; then
  echo "      ❌ WS1 branch column is empty/dash -- patch didn't enrich"
  echo "         workspace.list handler (bearer-and-routing patch) regressed."
  exit 1
else
  echo "      ✓ WS1 shows non-empty branch ($WS1_BRANCH)"
fi

# API-level check that the field is filled (not just CLI rendering).
API_BRANCH=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  "$OPENCODE_BASE/experimental/workspace" |
  jq -r --arg id "$WS1" '.[] | select(.id == $id) | .branch // ""')
if [ -n "$API_BRANCH" ] && [ "$API_BRANCH" != "null" ]; then
  echo "      ✓ /experimental/workspace response carries branch=$API_BRANCH for WS1"
else
  echo "      ❌ /experimental/workspace response has empty branch for WS1"
  echo "         expected the patched handler to fill it via .git/HEAD read"
  exit 1
fi

# Broken-clone case: directory exists without .git -- handler falls
# back to empty/dash.
ocexec rm -rf "/var/lib/kfactory/workspaces/$(cli kfactory list 2>/dev/null | tail -n +2 | awk -v wid="$WS3" '$2 == wid { print $3 }')/.git"

WS3_BRANCH=$(cli kfactory list 2>/dev/null | tail -n +2 |
  awk -v wid="$WS3" '$2 == wid { print $4 }')
if [ "$WS3_BRANCH" = "-" ] || [ -z "$WS3_BRANCH" ]; then
  echo "      ✓ WS3 (no .git) shows '-' (no live branch)"
else
  echo "      ❌ WS3 has no .git but branch column shows '$WS3_BRANCH'"
  echo "         expected empty/dash fallback"
  exit 1
fi
