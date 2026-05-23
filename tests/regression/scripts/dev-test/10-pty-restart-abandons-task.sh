# [10] PTY lifecycle survives opencode-serve restart? It doesn't.
#
# Scenario: the operator runs a long-lived task through pty_spawn with
# notifyOnExit=true (the opencode-pty plugin's intended async pattern).
# The agent's first turn calls pty_spawn, gets back a pty_id, and
# completes -- time.completed gets set on that assistant message
# normally. Meanwhile the PTY process runs in the background until it
# exits, at which point opencode-pty's notification-manager.js calls
# `client.session.promptAsync(<pty_exited>...)` to wake the agent for
# turn 2.
#
# When opencode-serve restarts (deploy, OOM, crash) mid-PTY:
#   - The opencode process dies; bun-pty's child processes die with it.
#   - The opencode-pty plugin's in-memory `sessions: Map<id, Session>`
#     vanishes (no on-disk persistence -- see node_modules/opencode-pty/
#     dist/src/plugin/pty/session-lifecycle.js:12).
#   - On restart, the plugin loads with an empty Map. No PTY ids exist.
#   - The exit-callback for the killed PTY never fires (the JS handler
#     died with the process), so no <pty_exited> message is injected.
#   - opencode-heal scans `message`/`session_message` for assistant
#     turns with `time.completed IS NULL` -- the pty_spawn turn doesn't
#     match (it completed normally when the tool returned). Heal's
#     recovery queue stays empty for this workspace.
#   - Result: the agent's task is silently abandoned. No signal to the
#     operator that their long-running work is dead.
#
# Phase order matters: this MUST run after [9] because we restart
# kfactory-opencode mid-test, which would invalidate the heal-canary
# state in earlier phases.

echo
echo "[10] PTY abandoned on opencode-serve restart..."

WS_PTY=$(cli kfactory dispatch "$REPO" "wait for instructions")
echo "      → minted workspace for PTY restart test: $WS_PTY"
# Wait long enough for the dispatch's natural turn to finish (~2s
# agent response + small margin) so the followup tick isn't queued
# behind it. The dispatch's own session.idle notification doesn't
# matter here -- this phase doesn't poll ntfy.
sleep 5

# Pick a sleep that's long enough to survive the docker restart (which
# can take 5-10s) plus our heal probe afterwards. 30s gives margin.
cli kfactory tick "$WS_PTY" --prompt \
  "Use the pty_spawn tool to start the bash command 'sleep 30 && echo PTY_RESTART_DONE'. Set notifyOnExit to true. Then stop immediately -- do not call any other tools." \
  >/dev/null

# Wait for the agent to ingest the tick prompt + call pty_spawn. The
# test model is non-deterministic on latency; 10s covers the slow path.
sleep 10

PTY_SPAWN_BEFORE=$(ocexec sqlite3 "$OPENCODE_DB" "
  SELECT count(*) FROM part p
  JOIN message m ON p.message_id = m.id
  JOIN session s ON m.session_id = s.id
  WHERE s.workspace_id = '$WS_PTY'
    AND json_extract(p.data, '\$.type') = 'tool'
    AND json_extract(p.data, '\$.tool') = 'pty_spawn';")

if [ "$PTY_SPAWN_BEFORE" -lt 1 ]; then
  echo "      ❌ agent didn't call pty_spawn before restart (count=$PTY_SPAWN_BEFORE)."
  echo "         The test model may have ignored the explicit instruction."
  exit 1
fi
echo "      ✓ pre-restart: pty_spawn tool call recorded ($PTY_SPAWN_BEFORE)"

# No pty_exited message should exist yet -- the sleep is 30s, only 6s
# have elapsed since the tick.
PTY_EXITED_BEFORE=$(ocexec sqlite3 "$OPENCODE_DB" "
  SELECT count(*) FROM part p
  JOIN message m ON p.message_id = m.id
  JOIN session s ON m.session_id = s.id
  WHERE s.workspace_id = '$WS_PTY'
    AND json_extract(p.data, '\$.type') = 'text'
    AND json_extract(p.data, '\$.text') LIKE '%</pty_exited>%'
    AND json_extract(m.data, '\$.role') = 'user';")
echo "      → pre-restart: <pty_exited> messages in session: $PTY_EXITED_BEFORE (should be 0)"

# Hard restart kfactory-opencode. This kills the bun process + every
# child PTY process. New opencode-serve starts fresh; opencode-pty's
# Map<id, Session> is empty.
echo "      → restarting kfactory-opencode container..."
docker restart "$OPENCODE_CONTAINER" >/dev/null

# Wait for opencode to come back. /global/health is the cheapest probe.
for _ in $(seq 1 30); do
  if cli curl -sf -H "Authorization: Bearer $TOKEN" "$OPENCODE_BASE/global/health" >/dev/null 2>&1; then
    echo "      ✓ kfactory-opencode is back"
    break
  fi
  sleep 1
done

# Wait a beat for opencode-pty's plugin to fully load on the new instance.
sleep 3

# At this point the PTY is dead (process killed when its parent died).
# It would have naturally exited at T+30 if not killed; it's now T+~15.
# But the natural exit's onExit handler is gone with the process.
PTY_EXITED_AFTER=$(ocexec sqlite3 "$OPENCODE_DB" "
  SELECT count(*) FROM part p
  JOIN message m ON p.message_id = m.id
  JOIN session s ON m.session_id = s.id
  WHERE s.workspace_id = '$WS_PTY'
    AND json_extract(p.data, '\$.type') = 'text'
    AND json_extract(p.data, '\$.text') LIKE '%</pty_exited>%'
    AND json_extract(m.data, '\$.role') = 'user';")
echo "      → post-restart: <pty_exited> messages in session: $PTY_EXITED_AFTER"

# Run heal against the restarted DB. Heal sweeps stuck assistant turns
# (time.completed IS NULL). The pty_spawn turn was NOT stuck -- it
# completed normally when the tool returned -- so heal won't include
# this workspace in its recovery queue. THIS is the regression: the
# abandoned PTY task gets no recovery signal.
QUEUE=/tmp/pty-restart-heal.json
HEAL_OUTPUT=$(ocexec env KFACTORY_RECOVERY_QUEUE="$QUEUE" opencode-heal "$OPENCODE_DB")
echo "      → heal log: $HEAL_OUTPUT"

if ocexec cat "$QUEUE" | jq -e --arg w "$WS_PTY" 'any(. == $w)' >/dev/null 2>&1; then
  echo "      ✓ heal queue contains the abandoned-PTY workspace ($WS_PTY)"
else
  echo "      ❌ heal queue does NOT contain $WS_PTY -- abandoned PTY undetected"
  echo "         queue: $(ocexec cat "$QUEUE")"
  echo ""
  echo "         The PTY process died when opencode-serve restarted, but:"
  echo "         (a) the assistant turn that called pty_spawn was already"
  echo "             time.completed=set, so heal's 'stuck turn' query"
  echo "             (json_extract(data, '\$.time.completed') IS NULL)"
  echo "             doesn't match;"
  echo "         (b) the PTY plugin's in-memory exit-notification hook"
  echo "             vanished with the dead process, so no <pty_exited>"
  echo "             message ever gets injected to wake the agent;"
  echo "         (c) the operator's task is silently dropped."
  echo ""
  echo "         A complete recovery mechanism would need to scan the"
  echo "         session history for pty_spawn tool calls with"
  echo "         notifyOnExit=true that have no follow-up <pty_exited>"
  echo "         message, and either mark those turns failed or inject"
  echo "         a synthetic 'your PTY was killed by restart' message."
  exit 1
fi
