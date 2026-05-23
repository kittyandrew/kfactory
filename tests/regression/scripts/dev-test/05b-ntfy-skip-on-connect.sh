# [5b] ntfy skip-on-connect regression: when an SSE subscriber is
# attached to /global/event with the workspace header (the TUI's exact
# shape), session.idle's pending notification MUST be cancelled by the
# subscriberCount > 0 signal published by the opencode-session-subscribers
# patch. This is the "I reconnected to the session while a notification
# was waiting -- it should be silenced, not fire anyway" symptom.
#
# Mechanism (when working):
#   1. /global/event handler runs `bus.publish(SubscribersChanged, {count: 1})`
#      onto the workspace's instance bus on connect.
#   2. plugins/ntfy subscribes to that bus, sees count > 0.
#   3. session.idle fires its notifyAfter timer (3s default in regression).
#   4. The subscribers.changed signal cancels the timer BEFORE it expires
#      -> no notification.
#
# This test uses ntfy's /json?poll=1&since=<TS> history endpoint rather
# than a streaming capture window so the assertion is timing-robust:
# regardless of when the notification would have fired within the wait
# window, polling-since-TS catches it.

echo
echo "[5b] ntfy skip-on-connect (suppress while SSE attached)..."

# WS3 keeps WS1 free for [9]. WS3's .git was wiped by 03b's no-branch
# assertion -- fine here, we only need a bus + session.
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

# Open SSE subscriber to /global/event with the workspace header
# (replicates the TUI's exact attach shape -- sdk.tsx:startSSE).
# Connection-open should trigger the +1 publish in the patched global.ts
# handler. cli_d = `docker exec -d`.
cli sh -c "rm -f /tmp/sse-attach.out /tmp/sse-attach.pid"
cli_d sh -c \
  "curl -N -sS -H 'Authorization: Bearer $TOKEN' -H 'x-opencode-workspace: $ATTACH_WS' '$OPENCODE_BASE/global/event' > /tmp/sse-attach.out 2>&1 &
   echo \$! > /tmp/sse-attach.pid"
sleep 3 # let the SSE handler run the +1 publish (or fail trying)

# Sanity probe: did the SSE actually attach? If /global/event 500s
# immediately, the subscribers.changed publish never happens and the
# entire test is meaningless. Surface that as a distinct failure mode.
SSE_OUT=$(cli cat /tmp/sse-attach.out 2>/dev/null || true)
if echo "$SSE_OUT" | grep -q 'UnknownError\|"name"'; then
  echo "      ❌ /global/event returned an error response, not an SSE stream:"
  echo "$SSE_OUT" | head -3 | sed 's/^/         /'
  echo "         -> the subscribers.changed publish never reached the ntfy"
  echo "            plugin (the patched handler in handlers/global.ts dies"
  echo "            before publishing). This is the upstream cause of the"
  echo "            'reconnect-doesn't-silence-the-pending-notification' bug."
  # shellcheck disable=SC2016
  cli sh -c \
    'PID=$(cat /tmp/sse-attach.pid 2>/dev/null); [ -n "$PID" ] && kill "$PID" 2>/dev/null || true; rm -f /tmp/sse-attach.*'
  exit 1
fi
if ! echo "$SSE_OUT" | grep -q 'server.connected'; then
  echo "      ❌ SSE did not emit server.connected within 3s of attach"
  echo "         captured: $(echo "$SSE_OUT" | head -3)"
  # shellcheck disable=SC2016
  cli sh -c \
    'PID=$(cat /tmp/sse-attach.pid 2>/dev/null); [ -n "$PID" ] && kill "$PID" 2>/dev/null || true; rm -f /tmp/sse-attach.*'
  exit 1
fi

# Timestamp the moment BEFORE tick, in unix seconds. ntfy's
# /json?poll=1&since=<TS> returns messages with .time >= TS.
TS_BEFORE=$(date +%s)

# Trigger session.idle via tick. The agent's "say bye" response idles
# within a few seconds, then the ntfy plugin's notifyAfter=3s default
# starts a pending timer. If subscriber-count > 0 (which it should be,
# since our SSE is attached), the timer gets cancelled.
cli kfactory tick "$ATTACH_WS" --prompt "say bye and immediately stop" >/dev/null

# Wait long enough for: agent reply (~2-5s) + session.idle + notifyAfter
# (3s). 12s gives plenty of margin.
sleep 12

# Kill the subscriber so its absence in /json?poll doesn't matter.
# shellcheck disable=SC2016
cli sh -c \
  'PID=$(cat /tmp/sse-attach.pid 2>/dev/null); [ -n "$PID" ] && kill "$PID" 2>/dev/null || true'

# Poll ntfy for any notifications posted to the topic SINCE the tick.
# Filter by .time >= TS_BEFORE because the topic also carries
# notifications from earlier phases (5/9).
NEW_MSGS=$(cli curl -sf "$NTFY_URL_INTERNAL/$TOPIC/json?poll=1&since=$TS_BEFORE" 2>/dev/null || true)
# Bare-string fallback for NEW_COUNT (instead of `|| echo 0`) so a jq
# failure surfaces as a test error rather than a silent false-pass.
if ! NEW_COUNT=$(echo "$NEW_MSGS" | jq -s "map(select(.time >= $TS_BEFORE)) | length" 2>&1); then
  echo "      ❌ jq parse failed on ntfy poll output: $NEW_COUNT"
  echo "         raw response (first 5 lines):"
  echo "$NEW_MSGS" | head -5 | sed 's/^/         /'
  cli sh -c 'rm -f /tmp/sse-attach.*'
  exit 1
fi

if [ "$NEW_COUNT" -eq 0 ]; then
  echo "      ✓ no ntfy notifications fired while SSE subscriber attached"
else
  echo "      ❌ $NEW_COUNT notification(s) fired despite SSE subscriber attached:"
  echo "$NEW_MSGS" | jq -c '{time,title,message}' 2>/dev/null | head -3 | sed 's/^/         /'
  echo "         The patched /global/event was supposed to publish"
  echo "         kfactory.subscribers.changed onto the workspace's bus,"
  echo "         which would cancel the pending notifyAfter timer in"
  echo "         plugins/ntfy. That publish never reached the plugin."
  cli sh -c 'rm -f /tmp/sse-attach.*'
  exit 1
fi

cli sh -c 'rm -f /tmp/sse-attach.*'
