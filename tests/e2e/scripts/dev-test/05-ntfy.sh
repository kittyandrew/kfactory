# [5/9] Subscribe to ntfy + verify session.idle notification fires.
# Spawns a 15-second background subscriber to the topic. The test
# dispatches from [2/9] should trigger session.idle within seconds,
# and the ntfy plugin's 3s notifyAfter window will fire.

echo
echo "[5/9] Subscribe to ntfy + verify session.idle notification fires..."
NTFY_LOG=$(mktemp)
(timeout 15 curl -s "$NTFY_URL/$TOPIC/json" >"$NTFY_LOG" || true) &
NTFY_PID=$!
sleep 12
wait $NTFY_PID 2>/dev/null || true

if grep -q '"message"' "$NTFY_LOG"; then
  echo "      ✓ ntfy received at least one notification:"
  grep '"message"' "$NTFY_LOG" | head -3 | sed 's/^/         /'
else
  echo "      ❌ no ntfy messages in 15s window. Possible causes:"
  echo "         - ntfy plugin failed to load (check opencode logs)"
  echo "         - notifyAfter=3 didn't expire in time (agent still busy)"
  echo "         - server.error path firing instead of session.idle"
  echo "      Captured ntfy stream:"
  sed 's/^/         /' "$NTFY_LOG"
fi
rm -f "$NTFY_LOG"
