# [9/9] opencode-heal + opencode-sync-kick + recovery round-trip.
# This is the canary for the suspected "recovery did not actually
# work" regression in the prior kittyos extraction. End-to-end it
# proves:
#   1) we manufacture a stuck assistant turn (mid-flight crash);
#   2) heal marks it + writes the affected-workspace queue file;
#   3) sync-kick succeeds against the running server;
#   4) `kfactory tick <wid> --prompt <recovery>` injects the
#      operator-supplied recovery prompt as a new user message in
#      the workspace's most-recent root session.
# The previously-broken kittyos shape is suspected of skipping step 4
# (or routing it at the wrong session). Step 4's assertion below is
# the canary; F4-tightened so a future multi-text-part change can't
# silently weaken it.

echo
echo "[9/9] opencode-heal + opencode-sync-kick + recovery round-trip..."

# Reuse WS1 from [2/9]; its assistant turn already completed, which
# is what we need to "uncomplete" to simulate a crash.
HEAL_WS=$WS1

# Resolve WS1's session. Then locate the most-recent assistant
# message; opencode stores assistant turns in EITHER `message` (v1,
# role in JSON blob) OR `session_message` (v2, role in `type` column)
# depending on the path opencode took at insert time. The heal script
# itself handles both; the test probes both so it works on whichever
# schema opencode happens to write.
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

# Manufacture the stuck state: drop time.completed + finish from the
# assistant message JSON in whichever table holds it. json_remove on
# absent paths is a no-op, so this is idempotent across re-runs.
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

# Run heal. Queue path overridable via env so the test doesn't need
# /run/kfactory (which would require the container to have the right
# ownership on /run -- /tmp is portable).
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

# Sync-kick: target localhost from inside the opencode container
# (mirrors the production ExecStartPost wiring). The /sync/start
# endpoint succeeds on each workspace; per-workspace failures would
# be logged + the loop continues.
SYNC_LOG=$(ocexec opencode-sync-kick --base http://localhost:4096 --health-timeout 10 2>&1)
echo "      → sync-kick log: $SYNC_LOG"
if echo "$SYNC_LOG" | grep -qE "kicked [1-9][0-9]* workspace"; then
  echo "      ✓ sync-kick reported kicked workspaces"
else
  echo "      ❌ sync-kick did not kick any workspace"
  exit 1
fi

# Recovery prompt injection -- the canary for the suspected "recovery
# did not actually work" bug. If tick fails to append the prompt as a
# new user message, the assertion below catches it.
RECOVERY_PROMPT="opencode-serve restarted; resume your last action"
REC_BEFORE=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $HEAL_WS" \
  "$OPENCODE_BASE/session/$HEAL_SESS/message" | jq 'length')

# Iterate over the queue exactly the way the systemd recovery-sweep
# helper does -- read JSON, loop, post a tick per workspace. Same
# code path; we just invoke `kfactory tick` directly instead of going
# through the writeShellApplication wrapper.
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
# F4-tightened: join ALL text parts of the last user message into one
# string. Earlier shape used `... | tail -1` which would have been
# satisfied by a multi-text-part message ending with the recovery
# prompt -- a future regression vector the tail collapsed.
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
  echo "         This is the regression you flagged: heal + sync-kick"
  echo "         ran cleanly but recovery-sweep failed to follow through."
  exit 1
fi

echo
echo "========================================================"
echo " Done."
echo " ntfy UI:  $NTFY_URL/$TOPIC"
echo "========================================================"
