# [7/9] tick (scheduled) -- fresh-workspace mint. Task-id is the
# deterministic slug suffix so a second tick finds the workspace by
# slug-ends-with-id. 4-hex constraint enforced at scheduled-tasks.nix,
# cmd/kfactory/tick.go, and plugins/kfactory-adapter SLUG_RE.

echo
echo "[7/9] kfactory tick (scheduled) -- fresh-workspace path..."
TASK_ID="aaaa"

# Sweep stale workspaces so we observe a real mint, not an idempotent no-op.
EXISTING_IDS=$(cli kfactory list 2>/dev/null | tail -n +2 |
  awk -v t="$TASK_ID" '$3 ~ ("--" t "$") { print $2 }')
for wid in $EXISTING_IDS; do
  echo "      → cleaning up stale $wid (slug ends in --$TASK_ID)"
  cli kfactory delete -y "$wid" >/dev/null 2>&1 || true
done

# KFACTORY_SCHEDULED_DIR overrides the /etc/kfactory/scheduled prod path.
cli mkdir -p /tmp/kfactory-scheduled
cli sh -c "cat > /tmp/kfactory-scheduled/${TASK_ID}.json" <<'JSON'
{
  "repo": "file:///srv/test-repo.git",
  "mode": "continue",
  "initial_prompt": "say hi and immediately stop",
  "continuation_prompt": "say bye and immediately stop"
}
JSON

TICK_WS=$(cli env KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled \
  kfactory tick "$TASK_ID")
echo "      → fresh tick returned workspace $TICK_WS"

# Confirm the slug is deterministic (ends in --<task-id>).
TICK_SLUG=$(cli kfactory list 2>/dev/null | tail -n +2 |
  awk -v wid="$TICK_WS" '$2 == wid { print $3 }')
if echo "$TICK_SLUG" | grep -qE -- "--${TASK_ID}\$"; then
  echo "      ✓ workspace slug $TICK_SLUG matches --$TASK_ID suffix"
else
  echo "      ❌ slug $TICK_SLUG does not end in --$TASK_ID"
  echo "         kfactory-adapter slugSuffix wiring is broken."
  exit 1
fi
