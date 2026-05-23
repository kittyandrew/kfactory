# [8/9] tick (scheduled) -- continue + skip-if-exists (separate config).
# Stdout = workspace id on every tick exit (including skip) so wrappers
# capturing $(kfactory tick ...) always get a usable reference.

echo
echo "[8/9] kfactory tick (scheduled) -- continue + skip-if-exists..."

# ---- continue branch ----

# Most-recent root session (no parentID) for before/after message-count.
TICK_SESS=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $TICK_WS" \
  "$OPENCODE_BASE/experimental/session?workspace=$TICK_WS" |
  jq -r '[.[] | select(.parentID == null or .parentID == "")]
         | sort_by(.time.updated) | reverse | .[0].id')
if [ -z "$TICK_SESS" ] || [ "$TICK_SESS" = "null" ]; then
  echo "      ❌ no root session found in workspace $TICK_WS"
  exit 1
fi
echo "      → tracking root session $TICK_SESS"

MSG_BEFORE=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $TICK_WS" \
  "$OPENCODE_BASE/session/$TICK_SESS/message" | jq 'length')
echo "      → messages before continue: $MSG_BEFORE"

TICK_CONT=$(cli env KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled \
  kfactory tick "$TASK_ID")
if [ "$TICK_CONT" = "$TICK_WS" ]; then
  echo "      ✓ continue returned same workspace ($TICK_WS)"
else
  echo "      ❌ continue returned $TICK_CONT, expected $TICK_WS"
  exit 1
fi

sleep 2
MSG_AFTER=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $TICK_WS" \
  "$OPENCODE_BASE/session/$TICK_SESS/message" | jq 'length')
if [ "$MSG_AFTER" -gt "$MSG_BEFORE" ]; then
  echo "      ✓ continue appended a message ($MSG_BEFORE -> $MSG_AFTER)"
else
  echo "      ❌ continue did not append: $MSG_BEFORE -> $MSG_AFTER"
  echo "         continuation prompt was lost; tick continue path broken."
  exit 1
fi

# Join ALL text parts of the last user message; `| tail -1` would be
# satisfied by a multi-part message ending with the continuation prompt.
LAST_USER_TEXT=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $TICK_WS" \
  "$OPENCODE_BASE/session/$TICK_SESS/message" |
  jq -r '[.[] | select(.info.role == "user")] | last
         | (.parts // []) | map(select(.type == "text") | .text) | join("")')
if [ "$LAST_USER_TEXT" = "say bye and immediately stop" ]; then
  echo "      ✓ last user message body = continuation_prompt"
else
  echo "      ❌ last user message body = $LAST_USER_TEXT"
  echo "         expected: say bye and immediately stop"
  exit 1
fi

# ---- skip-if-exists branch ----

SKIP_TASK="bbbb"
echo
echo "      ---- skip-if-exists (config-mode driven) ----"

# Clean up any leftover from a previous run.
EXISTING_SKIP=$(cli kfactory list 2>/dev/null | tail -n +2 |
  awk -v t="$SKIP_TASK" '$3 ~ ("--" t "$") { print $2 }')
for wid in $EXISTING_SKIP; do
  cli kfactory delete -y "$wid" >/dev/null 2>&1 || true
done

cli sh -c "cat > /tmp/kfactory-scheduled/${SKIP_TASK}.json" <<'JSON'
{
  "repo": "file:///srv/test-repo.git",
  "mode": "skip-if-exists",
  "initial_prompt": "say hi and immediately stop"
}
JSON

# First tick mints (skip-if-exists only blocks on subsequent ticks).
SKIP_WS=$(cli env KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled \
  kfactory tick "$SKIP_TASK")
echo "      → first tick (mint) returned $SKIP_WS"

# Snapshot the session + message count BEFORE the would-be-skip tick.
SKIP_SESS=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $SKIP_WS" \
  "$OPENCODE_BASE/experimental/session?workspace=$SKIP_WS" |
  jq -r '[.[] | select(.parentID == null or .parentID == "")]
         | sort_by(.time.updated) | reverse | .[0].id')
SKIP_MSG_BEFORE=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $SKIP_WS" \
  "$OPENCODE_BASE/session/$SKIP_SESS/message" | jq 'length')

# Second tick: workspace exists -> skip path. Stdout still prints id.
SKIP_OUT=$(cli env KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled \
  kfactory tick "$SKIP_TASK" 2>/tmp/skip-stderr)
SKIP_LOG=$(cat /tmp/skip-stderr)
rm -f /tmp/skip-stderr

if [ "$SKIP_OUT" = "$SKIP_WS" ]; then
  echo "      ✓ skip stdout prints workspace id ($SKIP_OUT)"
else
  echo "      ❌ skip stdout = '$SKIP_OUT', expected '$SKIP_WS'"
  exit 1
fi
if echo "$SKIP_LOG" | grep -q "skipped"; then
  echo "      ✓ skip stderr contains 'skipped'"
else
  echo "      ❌ skip stderr missing 'skipped': $SKIP_LOG"
  exit 1
fi

sleep 1
SKIP_MSG_AFTER=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $SKIP_WS" \
  "$OPENCODE_BASE/session/$SKIP_SESS/message" | jq 'length')
if [ "$SKIP_MSG_AFTER" -eq "$SKIP_MSG_BEFORE" ]; then
  echo "      ✓ skip did not append a message ($SKIP_MSG_BEFORE messages, unchanged)"
else
  echo "      ❌ skip appended messages: $SKIP_MSG_BEFORE -> $SKIP_MSG_AFTER"
  echo "         skip-if-exists branch incorrectly posted to the session."
  exit 1
fi
