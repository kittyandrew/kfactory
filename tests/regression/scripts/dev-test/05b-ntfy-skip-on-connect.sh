# [5b/9] ntfy skip-on-connect regression: TUI attach mode subscribes
# to /global/event (SDKProvider.startSSE). opencode-session-subscribers
# patch instruments BOTH /event AND /global/event so subscriberCount > 0
# triggers the skip path. Replicates the TUI's exact SSE shape (with
# x-opencode-workspace header) and asserts no notification fires while
# attached. [5/9] tested the easy half ("fires when nobody watches");
# this is the hard half.

echo
echo "[5b/9] ntfy skip-on-connect (suppress while SSE attached)..."

# WS3 keeps WS1 free for [9/9]. WS3's .git was wiped by 03b's no-branch
# assertion -- fine here, we only need a bus + session. Don't assert on
# git state in this phase.
ATTACH_WS=$WS3
ATTACH_SESS=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $ATTACH_WS" \
  "$OPENCODE_BASE/experimental/session?workspace=$ATTACH_WS" |
  jq -r '[.[] | select(.parentID == null or .parentID == "")]
         | sort_by(.time.updated) | reverse | .[0].id')
if [ -z "$ATTACH_SESS" ] || [ "$ATTACH_SESS" = "null" ]; then
  echo "      ❌ no root session in WS3 to target"
  exit 1
fi

# SSE subscriber to /global/event with the workspace header.
# Connection-open triggers the +1 publish in the patched global.ts
# handler. cli_d = `docker exec -d`.
cli_d sh -c \
  "curl -N -sS -H 'Authorization: Bearer $TOKEN' -H 'x-opencode-workspace: $ATTACH_WS' '$OPENCODE_BASE/global/event' > /tmp/sse-attach.out 2>&1 &
   echo \$! > /tmp/sse-attach.pid"
sleep 2 # give the SSE handler time to run the +1 publish

# 12s ntfy capture window; meanwhile trigger session.idle via tick.
cli_d sh -c \
  "timeout 12 curl -s '$NTFY_URL/$TOPIC/json' > /tmp/ntfy-skip.out 2>&1 &
   echo \$! > /tmp/ntfy-skip.pid"
sleep 1

# notifyAfter default in tests is 3s, so session.idle would normally
# fire a notification 3s after the agent finishes.
cli kfactory tick "$ATTACH_WS" --prompt "say bye and immediately stop" >/dev/null

# Wait the full ntfy capture window.
sleep 11

# Read ntfy capture
NTFY_CAPTURED=$(cli cat /tmp/ntfy-skip.out 2>/dev/null || true)
NTFY_MSG_COUNT=$(echo "$NTFY_CAPTURED" | grep -c '"message"' || true)

# `$PID` unexpanded at host shell; expands inside the cli container.
# shellcheck disable=SC2016
cli sh -c \
  'PID=$(cat /tmp/sse-attach.pid 2>/dev/null); [ -n "$PID" ] && kill "$PID" 2>/dev/null || true' || true

# THE assertion: zero notifications while SSE was attached.
if [ "$NTFY_MSG_COUNT" -eq 0 ]; then
  echo "      ✓ no ntfy notifications fired while SSE subscriber attached"
else
  echo "      ❌ $NTFY_MSG_COUNT notification(s) fired despite SSE subscriber"
  echo "         (the operator's TUI is the realistic instance of this SSE shape)"
  echo "         ntfy capture (first lines):"
  echo "$NTFY_CAPTURED" | head -5 | sed 's/^/         /'
  exit 1
fi

# shellcheck disable=SC2016
cli sh -c \
  'PID=$(cat /tmp/ntfy-skip.pid 2>/dev/null); [ -n "$PID" ] && kill "$PID" 2>/dev/null || true; rm -f /tmp/ntfy-skip.out /tmp/ntfy-skip.pid /tmp/sse-attach.out /tmp/sse-attach.pid' || true
