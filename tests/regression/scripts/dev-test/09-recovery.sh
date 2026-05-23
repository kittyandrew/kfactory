# [9/9] heal + sync-kick + recovery round-trip canary.
#   1) manufacture stuck assistant turn (simulate mid-flight crash);
#   2) heal marks the row + writes the recovery queue;
#   3) sync-kick succeeds;
#   4) `kfactory tick <wid> --prompt` injects the recovery prompt as
#      a new user message in the workspace's most-recent root session.
# Step 4 is the canary -- F4-tightened so multi-text-part messages
# can't silently weaken it.

echo
echo "[9/9] opencode-heal + opencode-sync-kick + recovery round-trip..."

# Reuse WS1 from [2/9]; "uncomplete" its assistant turn to simulate
# the crash. opencode stores turns in EITHER `message` (v1, role in
# JSON) or `session_message` (v2, role in `type` column) depending on
# version; probe both.
HEAL_WS=$WS1

HEAL_SESS=$(ocexec sqlite3 "$OPENCODE_DB" \
  "SELECT id FROM session WHERE workspace_id='$HEAL_WS' LIMIT 1;")
HEAL_MSG=$(ocexec sqlite3 "$OPENCODE_DB" "
  SELECT id FROM session_message
    WHERE session_id='$HEAL_SESS' AND type='assistant'
    ORDER BY time_created DESC LIMIT 1;")
HEAL_TABLE=session_message
if [ -z "$HEAL_MSG" ]; then
  HEAL_MSG=$(ocexec sqlite3 "$OPENCODE_DB" "
    SELECT id FROM message
      WHERE session_id='$HEAL_SESS'
        AND json_extract(data, '\$.role')='assistant'
      ORDER BY time_created DESC LIMIT 1;")
  HEAL_TABLE=message
fi
if [ -z "$HEAL_SESS" ] || [ -z "$HEAL_MSG" ]; then
  echo "      ❌ could not locate WS1 session+assistant message"
  echo "         session=$HEAL_SESS msg=$HEAL_MSG"
  exit 1
fi
echo "      → heal target: ws=$HEAL_WS sess=$HEAL_SESS msg=$HEAL_MSG (table=$HEAL_TABLE)"

# Drop time.completed + finish from the JSON blob; json_remove on
# absent paths is a no-op so this is idempotent across re-runs.
ocexec sqlite3 "$OPENCODE_DB" "
  UPDATE $HEAL_TABLE
    SET data = json_remove(data, '\$.time.completed', '\$.finish')
    WHERE id='$HEAL_MSG';"

STUCK=$(ocexec sqlite3 "$OPENCODE_DB" "
  SELECT count(*) FROM $HEAL_TABLE
    WHERE id='$HEAL_MSG'
      AND json_extract(data, '\$.time.completed') IS NULL;")
if [ "$STUCK" != "1" ]; then
  echo "      ❌ failed to manufacture stuck state (count=$STUCK)"
  exit 1
fi
echo "      ✓ assistant message $HEAL_MSG marked stuck"

# /tmp/ instead of /run/kfactory/ (which would need the right ownership
# on /run -- /tmp is portable in the container).
QUEUE=/tmp/recovery-queue.json
HEAL_LOG=$(ocexec env KFACTORY_RECOVERY_QUEUE="$QUEUE" opencode-heal "$OPENCODE_DB")
echo "      → heal log: $HEAL_LOG"

# Assert the queue file lists WS1.
if ocexec cat "$QUEUE" | jq -e --arg w "$HEAL_WS" 'any(. == $w)' >/dev/null 2>&1; then
  echo "      ✓ heal queue contains $HEAL_WS"
else
  echo "      ❌ heal queue missing $HEAL_WS. queue contents:"
  ocexec cat "$QUEUE"
  exit 1
fi

# Assert heal marked the row finish='interrupted-by-restart' (in the
# table whichever schema opencode wrote to -- see HEAL_TABLE above).
HEAL_FINISH=$(ocexec sqlite3 "$OPENCODE_DB" "
  SELECT json_extract(data, '\$.finish') FROM $HEAL_TABLE
    WHERE id='$HEAL_MSG';")
HEAL_COMPLETED=$(ocexec sqlite3 "$OPENCODE_DB" "
  SELECT json_extract(data, '\$.time.completed') FROM $HEAL_TABLE
    WHERE id='$HEAL_MSG';")
if [ "$HEAL_FINISH" = "interrupted-by-restart" ] && [ -n "$HEAL_COMPLETED" ]; then
  echo "      ✓ assistant row marked finish='$HEAL_FINISH' completed=$HEAL_COMPLETED"
else
  echo "      ❌ heal did NOT mark the row: finish=$HEAL_FINISH completed=$HEAL_COMPLETED"
  exit 1
fi

# Localhost-inside-container mirrors the production ExecStartPost wiring.
SYNC_LOG=$(ocexec opencode-sync-kick --base http://localhost:4096 --health-timeout 10 2>&1)
echo "      → sync-kick log: $SYNC_LOG"
if echo "$SYNC_LOG" | grep -qE "kicked [1-9][0-9]* workspace"; then
  echo "      ✓ sync-kick reported kicked workspaces"
else
  echo "      ❌ sync-kick did not kick any workspace"
  exit 1
fi

# Recovery prompt injection -- the canary.
RECOVERY_PROMPT="opencode-serve restarted; resume your last action"
REC_BEFORE=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $HEAL_WS" \
  "$OPENCODE_BASE/session/$HEAL_SESS/message" | jq 'length')

# Same iteration as the systemd recovery-sweep helper; we just call
# `kfactory tick` directly here instead of through the wrapper.
QUEUE_JSON=$(ocexec cat "$QUEUE")
while IFS= read -r wid; do
  [ -z "$wid" ] && continue
  echo "      → recovery tick on $wid"
  cli kfactory tick "$wid" --prompt "$RECOVERY_PROMPT" >/dev/null
done < <(echo "$QUEUE_JSON" | jq -r '.[]')

sleep 2
REC_AFTER=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $HEAL_WS" \
  "$OPENCODE_BASE/session/$HEAL_SESS/message" | jq 'length')
# Join ALL text parts of the last user message; a `tail -1` would be
# satisfied by a multi-text-part message ending with the recovery prompt.
REC_LAST_USER=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $HEAL_WS" \
  "$OPENCODE_BASE/session/$HEAL_SESS/message" |
  jq -r '[.[] | select(.info.role == "user")] | last
         | (.parts // []) | map(select(.type == "text") | .text) | join("")')

if [ "$REC_AFTER" -gt "$REC_BEFORE" ] && [ "$REC_LAST_USER" = "$RECOVERY_PROMPT" ]; then
  echo "      ✓ recovery tick injected prompt into stuck session"
  echo "        ($REC_BEFORE -> $REC_AFTER messages; last user matches recovery prompt)"
else
  echo "      ❌ recovery did NOT inject the prompt."
  echo "         before=$REC_BEFORE after=$REC_AFTER"
  echo "         last user text: $REC_LAST_USER"
  echo "         expected:       $RECOVERY_PROMPT"
  echo "         heal + sync-kick ran but recovery-sweep didn't follow through."
  exit 1
fi

echo
echo "========================================================"
echo " Done."
echo " ntfy UI:  $NTFY_URL/$TOPIC"
echo "========================================================"
