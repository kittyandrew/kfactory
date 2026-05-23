# [5c] permission.asked ntfy notification: body must substitute
# {project} + {permission_type} from event metadata, not deliver the
# literal placeholders. Default template (backend.ts) is
# "{project} · {permission_type}" specifically because the operator
# wants to see WHAT was asked without expanding the notification --
# branch context isn't useful here.
#
# Trigger: opencode-base.json sets `webfetch: ask`. We tick a prompt
# that asks the agent to use the webfetch tool; the tool call fires
# permission.asked with `permission: "webfetch"` (per opencode's
# tool/webfetch.ts). The agent waits indefinitely for an operator
# reply that never comes -- fine for our purposes, dev-down cleans up.

echo
echo "[5c] permission.asked ntfy body (project + permission_type, not literal placeholders)..."

# Fresh workspace: WS3 (used in 5b) and WS2 (used in 4e) both had SSE
# subscribers attached, so their ntfy plugin instances may still see
# subscriberCount > 0 (Stream.ensuring's disconnect publish fires on
# the next heartbeat, up to ~10s later). A fresh workspace's plugin
# instance starts at 0 -- no suppression race.
WS_PERM=$(cli kfactory dispatch "$REPO" "wait for instructions")
echo "      → minted workspace for permission test: $WS_PERM"
sleep 2  # let the dispatch complete

TS_BEFORE=$(date +%s)

# Force a webfetch invocation. Strong wording so the agent doesn't
# decide to skip the tool.
cli kfactory tick "$WS_PERM" \
  --prompt "Use the webfetch tool to fetch https://example.com. Do nothing else." \
  >/dev/null

# Permission.asked has notifyAfter=0s in notification-ntfy.json, so the
# ntfy POST fires the moment the tool gates the call. Wait long enough
# for the agent to ingest the prompt + start tool selection (~10s).
sleep 12

# Poll ntfy for any message tagged with the permission title that
# arrived after TS_BEFORE. The filter on title separates these from
# the session.idle and session.error events that share the topic.
NTFY_LOG=$(mktemp)
cli curl -sf "$NTFY_URL_INTERNAL/$TOPIC/json?poll=1&since=$TS_BEFORE" >"$NTFY_LOG" 2>/dev/null || true

if ! PERM_MSG=$(jq -s "map(select(.time >= $TS_BEFORE and .title == \"Permission Asked\")) | .[0]" <"$NTFY_LOG" 2>&1); then
  echo "      ❌ jq parse failed on ntfy poll output: $PERM_MSG"
  echo "         raw response (first 5 lines):"
  head -5 "$NTFY_LOG" | sed 's/^/         /'
  rm -f "$NTFY_LOG"
  exit 1
fi

if [ "$PERM_MSG" = "null" ] || [ -z "$PERM_MSG" ]; then
  echo "      ❌ no permission.asked notification fired in 12s"
  echo "         Possible causes:"
  echo "         - opencode-base.json no longer has webfetch=ask"
  echo "         - the agent chose not to call webfetch for this prompt"
  echo "         - permission.asked is disabled in notification-ntfy.json"
  echo "         Full ntfy capture (first 10 lines):"
  head -10 "$NTFY_LOG" | sed 's/^/         /'
  rm -f "$NTFY_LOG"
  exit 1
fi

PERM_BODY=$(echo "$PERM_MSG" | jq -r '.message')
echo "      ✓ permission.asked notification fired ('$PERM_BODY')"

# Literal-placeholder check: no `{project}` / `{permission_type}` /
# `{branch}` should appear unsubstituted.
if echo "$PERM_BODY" | grep -qE '\{(project|branch|session_id|event|time|permission_type|permission_patterns)\}'; then
  echo "      ❌ permission.asked body contains literal placeholders: '$PERM_BODY'"
  echo "         backend.ts:resolveContent must run DEFAULT_MESSAGES through"
  echo "         renderTemplate before returning, not return them raw."
  rm -f "$NTFY_LOG"
  exit 1
fi

# Positive-content check: the substituted permission_type should be
# 'webfetch' (per tool/webfetch.ts in opencode). If we see something
# else, either the prompt didn't drive webfetch (try a stronger prompt)
# or the metadata wiring in plugins/ntfy/src/index.ts:285-300 drifted.
if ! echo "$PERM_BODY" | grep -q 'webfetch'; then
  echo "      ❌ permission.asked body does not mention 'webfetch': '$PERM_BODY'"
  echo "         expected '<workspace-slug> · webfetch'. Check that the"
  echo "         agent actually tried webfetch (not bash/edit) and that"
  echo "         permission_type metadata is plumbed end-to-end."
  rm -f "$NTFY_LOG"
  exit 1
fi

rm -f "$NTFY_LOG"
