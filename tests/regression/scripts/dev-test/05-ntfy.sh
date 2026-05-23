# [5/9] Verify session.idle ntfy notification fires AND its body has
# real (substituted) content. Defaults like "{project} · {branch}"
# must be passed through renderTemplate; the body assertion is what
# catches plugins/ntfy/src/backend.ts:resolveContent skipping the
# template-render call on the default-message path.
#
# Uses ntfy's poll-history endpoint (`/json?poll=1&since=...`) instead
# of a live-stream capture window so we don't miss notifications that
# fired BETWEEN dispatch (phase 2) and now -- session.idle typically
# arrives within a couple seconds of dispatch, well before any 15s
# capture window we'd open here.

echo
echo "[5/9] ntfy session.idle notification body (substituted vs literal)..."

# Poll all messages on the topic in the past hour. ntfy's `poll=1` mode
# returns historical messages and exits, not a streaming connection.
NTFY_LOG=$(mktemp)
cli curl -sf "$NTFY_URL_INTERNAL/$TOPIC/json?poll=1&since=1h" >"$NTFY_LOG" || true

if ! grep -q '"message"' "$NTFY_LOG"; then
  echo "      ❌ no ntfy messages on topic in past hour. Possible causes:"
  echo "         - ntfy plugin failed to load (check opencode logs)"
  echo "         - none of the dispatches reached session.idle"
  echo "         - notification went to a different topic"
  echo "      Captured (head of /json?poll=1):"
  head -5 "$NTFY_LOG" | sed 's/^/         /'
  rm -f "$NTFY_LOG"
  exit 1
fi
NTFY_COUNT=$(grep -c '"message"' "$NTFY_LOG" || true)
echo "      ✓ ntfy fired $NTFY_COUNT notification(s) on topic"

# Body-content assertion: extract .message and confirm it contains NO
# literal `{project}` / `{branch}` placeholders. backend.ts uses these
# tokens in DEFAULT_MESSAGES (e.g. session.idle="{project} · {branch}");
# buildTemplateVariables substitutes them at send time. If the default
# path forgot to call renderTemplate, the placeholders ship verbatim.
NTFY_MSG=$(head -1 "$NTFY_LOG" | jq -r '.message // ""')
if [ -z "$NTFY_MSG" ]; then
  echo "      ❌ first ntfy notification has empty .message field"
  rm -f "$NTFY_LOG"
  exit 1
fi
if echo "$NTFY_MSG" | grep -qE '\{(project|branch|session_id|event|time)\}'; then
  echo "      ❌ ntfy body contains literal placeholders: '$NTFY_MSG'"
  echo "         expected substituted content (e.g. '<repo-slug> · main')."
  echo "         backend.ts:resolveContent must run DEFAULT_MESSAGES through"
  echo "         renderTemplate before returning, not return them raw."
  rm -f "$NTFY_LOG"
  exit 1
fi
echo "      ✓ ntfy message body is substituted ('$NTFY_MSG')"
rm -f "$NTFY_LOG"
