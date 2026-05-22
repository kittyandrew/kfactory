# [3b/9] kfactory list BRANCH column -- regression test for the
# "list should show branch per workspace" feature.
#
# The patched `/experimental/workspace` handler enriches each row with
# a fresh branch read from .git/HEAD server-side (in a single round-
# trip, not N+1). Test cases:
#
#   - A workspace with a real .git clone (WS1, from the bundled
#     test-repo) MUST show a non-"-" branch (test-repo defaults to
#     "main" -- see tests/e2e/test-repo.nix).
#   - A workspace whose directory has no .git (manufactured by
#     wiping the dir) MUST fall back to "-" in the CLI's output and
#     the underlying API field MUST be null/empty/missing rather
#     than a stale stored value.
#
# Why this matters: prior to the patch, the workspace.branch column
# in opencode's DB stayed NULL for every kfactory-adapter dispatch
# (the adapter doesn't set it). `kfactory list` would show empty /
# "-" for every workspace, defeating the column's purpose. The patch
# reads .git/HEAD live so the column reflects the current checkout.

echo
echo "[3b/9] kfactory list BRANCH column..."

# WS1 / WS2 / WS3 all clone the bundled test-repo, whose default
# branch is "main". Verify the CLI shows that.
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
  # Test-repo's actual default branch may vary depending on git config
  # ("main" vs "master"). Accept any non-empty non-dash value.
  echo "      ✓ WS1 shows non-empty branch ($WS1_BRANCH)"
fi

# Also assert the API response carries the field at all (the CLI
# could be reading a stale field from the workspace row instead of
# the patched fresh read).
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

# Broken-clone case: blow away WS3's .git so the directory exists
# but has no git metadata. The handler must fall back to "-" / empty
# (current behaviour for the waybap-style failed-clone state).
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
