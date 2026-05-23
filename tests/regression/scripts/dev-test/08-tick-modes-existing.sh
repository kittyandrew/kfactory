# [8] kfactory tick (scheduled) -- mode-driven behavior when a
# workspace ALREADY exists for the task. Three modes, two positive
# cases for skip-if-dirty (clean + dirty), so four assertions:
#
#   skip-if-exists        + existing -> no-op (no message dispatched)
#   skip-if-dirty + clean + existing -> dispatch continuation_prompt
#   skip-if-dirty + dirty + existing -> no-op (no message dispatched)
#   continue              + existing -> dispatch continuation_prompt
#
# Phase 7 already covered the create-on-miss path that all three
# modes share. This phase reuses workspace WS1 (dispatched in phase
# 2) so we have a known root session to baseline message counts
# against. Each sub-test creates its own task-id + scheduled config
# under /tmp/kfactory-scheduled so they don't interfere.
#
# Server-side dirty enrichment (opencode-workspace-branch patch) shells
# `git status --porcelain` against the workspace directory; null = the
# probe couldn't determine, and kfactory tick fails-closed (treats as
# dirty). The "dirty" sub-test below writes a real untracked file
# into the workspace's worktree to make git status non-empty.

echo
echo "[8] kfactory tick (scheduled) -- mode-driven existing-workspace behavior..."

# Reuse the workspace minted by phase 7 (slug ends in --aaaa). Mode
# tests need a slug-suffix match for kfactory tick to find a workspace
# by task-id; WS1 from phase 2 has a random slug so it doesn't apply.
TASK_AAAA="aaaa"
WS_AAAA=$(cli kfactory list 2>/dev/null | tail -n +2 |
  awk -v t="$TASK_AAAA" '$3 ~ ("--" t "$") { print $2 }' | head -1)
if [ -z "$WS_AAAA" ]; then
  echo "      ❌ couldn't find workspace ending in --$TASK_AAAA (phase 7 must run first)"
  exit 1
fi
echo "      → reusing $WS_AAAA (slug --$TASK_AAAA) from phase 7"

# Resolve WS_AAAA's root session.
WS_AAAA_ROOT=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_AAAA" \
  "$OPENCODE_BASE/experimental/session?workspace=$WS_AAAA" |
  jq -r '[.[] | select(.parentID == null or .parentID == "")]
         | sort_by(.time.updated) | reverse | .[0].id')
if [ -z "$WS_AAAA_ROOT" ] || [ "$WS_AAAA_ROOT" = "null" ]; then
  echo "      ❌ no root session in WS_AAAA; phase 7 dispatch incomplete?"
  exit 1
fi

aaaa_msg_count() {
  cli curl -sf -H "Authorization: Bearer $TOKEN" \
    -H "x-opencode-workspace: $WS_AAAA" \
    "$OPENCODE_BASE/session/$WS_AAAA_ROOT/message" | jq 'length'
}

# Wait for phase 7's initial agent turn to fully settle before
# checkpointing message counts. The dispatch fires async; if we
# checkpoint mid-stream the after-count includes the agent reply
# rather than just our test's effect.
sleep 5

# ---- 8a: skip-if-exists + existing -> no dispatch ----

echo
echo "      ---- 8a: skip-if-exists (no dispatch when workspace exists) ----"
cli sh -c "cat > /tmp/kfactory-scheduled/${TASK_AAAA}.json" <<'JSON'
{
  "repo": "file:///srv/test-repo.git",
  "mode": "skip-if-exists",
  "initial_prompt": "say hi and immediately stop",
  "continuation_prompt": "say bye and immediately stop"
}
JSON

MSG_BEFORE=$(aaaa_msg_count)
SKIP_OUT=$(cli env KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled \
  kfactory tick "$TASK_AAAA" 2>/tmp/skip-if-exists.stderr)
SKIP_LOG=$(cat /tmp/skip-if-exists.stderr)
rm -f /tmp/skip-if-exists.stderr

if [ "$SKIP_OUT" != "$WS_AAAA" ]; then
  echo "      ❌ skip-if-exists stdout = '$SKIP_OUT', expected '$WS_AAAA'"
  exit 1
fi
if ! echo "$SKIP_LOG" | grep -q 'skip-if-exists'; then
  echo "      ❌ skip-if-exists stderr missing reason: $SKIP_LOG"
  exit 1
fi
sleep 2
MSG_AFTER=$(aaaa_msg_count)
if [ "$MSG_AFTER" -ne "$MSG_BEFORE" ]; then
  echo "      ❌ skip-if-exists appended a message: $MSG_BEFORE -> $MSG_AFTER"
  echo "         the no-dispatch path is broken; this mode is supposed to no-op."
  exit 1
fi
echo "      ✓ skip-if-exists no-op'd ($MSG_BEFORE messages, unchanged)"

# ---- 8b: skip-if-dirty + clean workspace -> dispatch ----

echo
echo "      ---- 8b: skip-if-dirty + clean workspace -> dispatch ----"
cli sh -c "cat > /tmp/kfactory-scheduled/${TASK_AAAA}.json" <<'JSON'
{
  "repo": "file:///srv/test-repo.git",
  "mode": "skip-if-dirty",
  "initial_prompt": "say hi and immediately stop",
  "continuation_prompt": "say bye and immediately stop"
}
JSON

# Ensure clean. kfactory-adapter clones the bare repo into the
# worktree; freshly-minted workspaces start clean.
DIRTY_PROBE=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  "$OPENCODE_BASE/experimental/workspace" |
  jq --arg id "$WS_AAAA" -r '.[] | select(.id == $id) | .dirty')
echo "      → server reports dirty=$DIRTY_PROBE for $WS_AAAA (expecting false)"
if [ "$DIRTY_PROBE" != "false" ]; then
  echo "      ❌ expected clean workspace; server reports dirty=$DIRTY_PROBE"
  echo "         either the patch isn't enriching 'dirty', or the workspace"
  echo "         has untracked files we didn't expect."
  exit 1
fi

MSG_BEFORE=$(aaaa_msg_count)
CLEAN_OUT=$(cli env KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled \
  kfactory tick "$TASK_AAAA")
if [ "$CLEAN_OUT" != "$WS_AAAA" ]; then
  echo "      ❌ skip-if-dirty (clean) stdout = '$CLEAN_OUT', expected '$WS_AAAA'"
  exit 1
fi
sleep 3
MSG_AFTER=$(aaaa_msg_count)
if [ "$MSG_AFTER" -le "$MSG_BEFORE" ]; then
  echo "      ❌ skip-if-dirty (clean) did NOT append: $MSG_BEFORE -> $MSG_AFTER"
  echo "         clean workspace should dispatch continuation_prompt."
  exit 1
fi
LAST_USER_TEXT=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_AAAA" \
  "$OPENCODE_BASE/session/$WS_AAAA_ROOT/message" |
  jq -r '[.[] | select(.info.role == "user")] | last
         | (.parts // []) | map(select(.type == "text") | .text) | join("")')
if [ "$LAST_USER_TEXT" != "say bye and immediately stop" ]; then
  echo "      ❌ last user text = '$LAST_USER_TEXT', expected continuation_prompt"
  exit 1
fi
echo "      ✓ skip-if-dirty (clean) dispatched continuation ($MSG_BEFORE -> $MSG_AFTER)"

# ---- 8c: skip-if-dirty + dirty workspace -> no dispatch ----

echo
echo "      ---- 8c: skip-if-dirty + dirty workspace -> no dispatch ----"

# Make the workspace dirty by writing an untracked file. The worktree
# lives at /var/lib/kfactory/workspaces/<slug> inside the opencode
# container; ocexec gives us a shell there.
WS_AAAA_NAME=$(cli kfactory list 2>/dev/null | tail -n +2 |
  awk -v wid="$WS_AAAA" '$2 == wid { print $3 }')
WORKTREE="/var/lib/kfactory/workspaces/$WS_AAAA_NAME"
ocexec sh -c "echo 'untracked dirty marker' > $WORKTREE/dirty-test-marker.txt"

# Wait briefly for the next list call to re-shell git status.
sleep 1

DIRTY_PROBE=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  "$OPENCODE_BASE/experimental/workspace" |
  jq --arg id "$WS_AAAA" -r '.[] | select(.id == $id) | .dirty')
echo "      → server reports dirty=$DIRTY_PROBE for $WS_AAAA (expecting true)"
if [ "$DIRTY_PROBE" != "true" ]; then
  echo "      ❌ marker file present but server reports dirty=$DIRTY_PROBE"
  echo "         git-status enrichment is broken or workspace path differs."
  exit 1
fi

# Wait a beat for the previous-sub-test's continuation to land in
# the message stream so the before-count is stable.
sleep 4

MSG_BEFORE=$(aaaa_msg_count)
DIRTY_OUT=$(cli env KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled \
  kfactory tick "$TASK_AAAA" 2>/tmp/skip-if-dirty.stderr)
DIRTY_LOG=$(cat /tmp/skip-if-dirty.stderr)
rm -f /tmp/skip-if-dirty.stderr

if [ "$DIRTY_OUT" != "$WS_AAAA" ]; then
  echo "      ❌ skip-if-dirty (dirty) stdout = '$DIRTY_OUT', expected '$WS_AAAA'"
  exit 1
fi
if ! echo "$DIRTY_LOG" | grep -q 'skip-if-dirty'; then
  echo "      ❌ skip-if-dirty (dirty) stderr missing reason: $DIRTY_LOG"
  exit 1
fi
sleep 2
MSG_AFTER=$(aaaa_msg_count)
if [ "$MSG_AFTER" -ne "$MSG_BEFORE" ]; then
  echo "      ❌ skip-if-dirty (dirty) appended a message: $MSG_BEFORE -> $MSG_AFTER"
  echo "         dirty workspace must NOT receive a prompt -- the safety net failed."
  exit 1
fi
echo "      ✓ skip-if-dirty (dirty) no-op'd ($MSG_BEFORE messages, unchanged)"

# Clean up the marker so the next-mode test starts from a clean tree.
ocexec rm -f "$WORKTREE/dirty-test-marker.txt"

# ---- 8d: continue + existing -> dispatch (unconditional) ----

echo
echo "      ---- 8d: continue + existing -> dispatch (unconditional) ----"
cli sh -c "cat > /tmp/kfactory-scheduled/${TASK_AAAA}.json" <<'JSON'
{
  "repo": "file:///srv/test-repo.git",
  "mode": "continue",
  "initial_prompt": "say hi and immediately stop",
  "continuation_prompt": "say bye and immediately stop"
}
JSON

# Make the workspace dirty AGAIN -- continue mode should dispatch
# regardless. This is the explicit "no safety net" semantic.
ocexec sh -c "echo 'untracked dirty marker' > $WORKTREE/dirty-test-marker.txt"

# Stable before-count.
sleep 4
MSG_BEFORE=$(aaaa_msg_count)
CONT_OUT=$(cli env KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled \
  kfactory tick "$TASK_AAAA")
if [ "$CONT_OUT" != "$WS_AAAA" ]; then
  echo "      ❌ continue stdout = '$CONT_OUT', expected '$WS_AAAA'"
  exit 1
fi
sleep 3
MSG_AFTER=$(aaaa_msg_count)
if [ "$MSG_AFTER" -le "$MSG_BEFORE" ]; then
  echo "      ❌ continue did NOT append (workspace dirty): $MSG_BEFORE -> $MSG_AFTER"
  echo "         continue mode must dispatch unconditionally."
  exit 1
fi
echo "      ✓ continue dispatched even with dirty workspace ($MSG_BEFORE -> $MSG_AFTER)"

# Clean up.
ocexec rm -f "$WORKTREE/dirty-test-marker.txt"
