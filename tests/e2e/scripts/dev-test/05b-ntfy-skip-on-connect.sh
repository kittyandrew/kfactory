# [5b/9] ntfy skip-on-connect -- regression test for the "operator's
# TUI is open but ntfy still fires" bug.
#
# Root cause (now fixed): the TUI in attach mode subscribes to
# /global/event (via SDKProvider.startSSE -> sdk.global.event). The
# opencode-session-subscribers patch originally only instrumented the
# per-instance /event endpoint -- /global/event left the per-workspace
# subscriberCounts WeakMap at 0, no kfactory.subscribers.changed
# event published, and ntfy's `subscriberCount > 0 -> skip` never
# triggered. The patch now ALSO instruments /global/event so both
# endpoints feed the same shared counter.
#
# This phase opens a real SSE connection to /global/event with the
# x-opencode-workspace header (the EXACT shape the TUI uses in attach
# mode) and asserts that no ntfy notification fires for a session.idle
# event in that workspace while the SSE is held open. After detach,
# notifications resume.
#
# The earlier [5/9] only tested "do notifications fire when nobody is
# watching" -- the easy half. This phase covers the hard half.

echo
echo "[5b/9] ntfy skip-on-connect (suppress while SSE attached)..."

# Use WS3 to keep WS1 free for [9/9]'s heal flow. WS3 has had its
# .git wiped by phase 03b's no-branch-fallback assertion; that's
# fine for this test (we only need a bus to subscribe to + a session
# to tick), but means the agent running here can't actually do
# anything git-aware. Don't add assertions on git state in this
# phase.
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

# Open a backgrounded SSE subscriber to /global/event with the
# workspace header. `curl -N` disables output buffering so the
# request stays alive streaming. Discard the body -- we just need
# the connection open. The post-patch global.ts handler increments
# the per-workspace subscriber count + publishes the
# kfactory.subscribers.changed bus event the moment this connection
# lands. `cli_d` is `docker exec -d` -- inner-shell backgrounding
# would be redundant.
cli_d sh -c \
  "curl -N -sS -H 'Authorization: Bearer $TOKEN' -H 'x-opencode-workspace: $ATTACH_WS' '$OPENCODE_BASE/global/event' > /tmp/sse-attach.out 2>&1 &
   echo \$! > /tmp/sse-attach.pid"
sleep 2 # give the SSE handler time to run the +1 publish

# Subscribe to ntfy in the background; capture any messages in a 12s
# window. Then trigger a session.idle by posting a fresh prompt to
# the watched session.
cli_d sh -c \
  "timeout 12 curl -s '$NTFY_URL/$TOPIC/json' > /tmp/ntfy-skip.out 2>&1 &
   echo \$! > /tmp/ntfy-skip.pid"
sleep 1

# Dispatch a prompt to the watched session. The notifyAfter window
# default (3s in tests) means session.idle would otherwise produce a
# notification after the agent finishes + 3s.
cli kfactory tick "$ATTACH_WS" --prompt "say bye and immediately stop" >/dev/null

# Wait the full ntfy capture window.
sleep 11

# Read ntfy capture
NTFY_CAPTURED=$(cli cat /tmp/ntfy-skip.out 2>/dev/null || true)
NTFY_MSG_COUNT=$(echo "$NTFY_CAPTURED" | grep -c '"message"' || true)

# Kill the SSE subscriber. The disconnect publishes count=0; future
# events fire normally. The `$PID` expansions are intentionally
# unexpanded at the host shell -- they're for the inner `sh -c`
# running inside the cli container.
# shellcheck disable=SC2016
cli sh -c \
  'PID=$(cat /tmp/sse-attach.pid 2>/dev/null); [ -n "$PID" ] && kill "$PID" 2>/dev/null || true' || true

# THE assertion: WHILE THE SSE WAS HELD OPEN, NO NTFY NOTIFICATION
# FOR ANY WORKSPACE -- the ntfy plugin's subscriberCount > 0 -> skip
# check should bite the moment the +1 publish lands on the
# workspace's bus.
if [ "$NTFY_MSG_COUNT" -eq 0 ]; then
  echo "      ✓ no ntfy notifications fired while SSE subscriber attached"
else
  echo "      ❌ $NTFY_MSG_COUNT notification(s) fired despite SSE subscriber"
  echo "         (the operator's TUI is the realistic instance of this SSE shape)"
  echo "         ntfy capture (first lines):"
  echo "$NTFY_CAPTURED" | head -5 | sed 's/^/         /'
  exit 1
fi

# Cleanup: kill leftover ntfy subscriber + tmp files (inner-shell $PID).
# shellcheck disable=SC2016
cli sh -c \
  'PID=$(cat /tmp/ntfy-skip.pid 2>/dev/null); [ -n "$PID" ] && kill "$PID" 2>/dev/null || true; rm -f /tmp/ntfy-skip.out /tmp/ntfy-skip.pid /tmp/sse-attach.out /tmp/sse-attach.pid' || true
