# [4e] TUI live-progress: /global/event SSE delivers workspace events
# to a subscriber attached via the TUI's exact shape (Authorization:
# Bearer + x-opencode-workspace header). The bug we're catching: the
# TUI sees nothing live; messages and progress only appear after a
# reconnect (the initial GET of persisted state).
#
# Topology (matches sdk.tsx:startSSE):
#   GET /global/event with x-opencode-workspace header (no ?workspace=
#   query -- the SDK only rewrites header -> query for fetch, not for
#   long-lived SSE.) Server's workspace-routing middleware resolves the
#   header into InstanceRef. The /global/event handler subscribes to
#   GlobalBus.on("event", ...) and streams every event the per-workspace
#   bus.publish forwarded via the GlobalBus.emit bridge in
#   packages/opencode/src/bus/index.ts:114.
#
# Expectation: after we trigger assistant work, the SSE stream MUST
# emit at least one event beyond the initial `server.connected` -- a
# session.* / message.* / part.* event proves end-to-end live delivery.

echo
echo "[4e] TUI live-progress: /global/event SSE delivers workspace events..."

ATTACH_WS=$WS2  # WS2 was dispatched in [2], no other phase touches it.
SSE_LOG=/tmp/sse-events-live.out
SSE_PID_FILE=/tmp/sse-events-live.pid

# Open SSE subscriber FIRST, before the tick. Mimics the TUI's order:
# sdk.tsx:startSSE subscribes before any user prompt.
cli sh -c "rm -f $SSE_LOG $SSE_PID_FILE"
cli_d sh -c \
  "curl -N -sS -H 'Authorization: Bearer $TOKEN' -H 'x-opencode-workspace: $ATTACH_WS' '$OPENCODE_BASE/global/event' > $SSE_LOG 2>&1 &
   echo \$! > $SSE_PID_FILE"

# Give the SSE handler time to wire up the Stream.callback acquire +
# GlobalBus.on registration (Effect.gen yields are not instant).
sleep 3

# Sanity: did the SSE connection actually open and emit the initial
# `server.connected` frame? If not, every later assertion is meaningless.
INITIAL=$(cli cat "$SSE_LOG" 2>/dev/null || true)
if ! echo "$INITIAL" | grep -q 'server.connected'; then
  echo "      ❌ SSE never emitted server.connected -- request failed before stream began"
  echo "         captured (first 10 lines):"
  echo "$INITIAL" | head -10 | sed 's/^/         /'
  cli sh -c \
    "PID=\$(cat $SSE_PID_FILE 2>/dev/null); [ -n \"\$PID\" ] && kill \"\$PID\" 2>/dev/null || true; rm -f $SSE_LOG $SSE_PID_FILE"
  exit 1
fi

# Trigger assistant work via tick. The agent's response generation
# publishes session/message/part events into the workspace bus, which
# bus.publish forwards via GlobalBus.emit. Those should land on our
# /global/event stream.
cli kfactory tick "$ATTACH_WS" --prompt "say hi and immediately stop" >/dev/null

# Wait for the agent to produce + complete a turn. Same window as 05-ntfy
# (long enough that session.idle fires).
sleep 15

# Pull everything the SSE stream emitted in that window.
EVENTS=$(cli cat "$SSE_LOG" 2>/dev/null || true)

# Kill the subscriber; clean up the temp files.
cli sh -c \
  "PID=\$(cat $SSE_PID_FILE 2>/dev/null); [ -n \"\$PID\" ] && kill \"\$PID\" 2>/dev/null || true"

# Count "live" events: any event payload with a `type` field other than
# the boot frame (server.connected) and the keepalive (server.heartbeat).
# Live progress is anything else: session.updated, message.updated,
# message.part.updated, permission.asked, etc.
LIVE_COUNT=$(echo "$EVENTS" | grep -oE '"type":"[^"]+"' \
  | grep -cvE '"type":"(server.connected|server.heartbeat)"' || true)

if [ "$LIVE_COUNT" -ge 1 ]; then
  echo "      ✓ SSE delivered $LIVE_COUNT live event(s) for WS2"
  echo "$EVENTS" | grep -oE '"type":"[^"]+"' \
    | grep -vE '"type":"(server.connected|server.heartbeat)"' \
    | sort -u | head -5 | sed 's/^/         seen: /'
else
  echo "      ❌ SSE delivered ZERO live events for WS2 after a full agent turn"
  echo "         (only server.connected / heartbeat). The TUI live-progress"
  echo "         path is broken -- per-workspace bus publishes are not"
  echo "         reaching /global/event subscribers."
  echo "         Captured (last 20 lines of SSE stream):"
  echo "$EVENTS" | tail -20 | sed 's/^/         /'
  cli sh -c "rm -f $SSE_LOG $SSE_PID_FILE"
  exit 1
fi

cli sh -c "rm -f $SSE_LOG $SSE_PID_FILE"
