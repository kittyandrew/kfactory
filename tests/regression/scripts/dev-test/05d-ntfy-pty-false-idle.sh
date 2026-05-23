# [5d] ntfy false-idle while PTY is running:
#
# When the agent uses `pty_spawn` with `notifyOnExit=true` (opencode-pty
# plugin's intended async pattern), it gets back a PTY id, finishes its
# turn, and the LLM session goes `session.idle`. ntfy queues a
# notification after notifyAfter (3s default in this env). Meanwhile
# the PTY is still running -- when it eventually exits, the plugin's
# notification-manager.js calls `client.session.promptAsync(...)`
# injecting a `<pty_exited>` user message that kicks off a NEW agent
# turn (the agent resumes, reads output, decides what to do next).
#
# Bug: the operator gets an "Agent Idle" push notification 3s after
# the agent's first turn ends, even though the agent will demonstrably
# resume on its own once the PTY exits. This conflates "LLM is idle"
# with "task is done." The notification interrupts the operator
# unnecessarily; the real completion notification comes seconds later.
#
# This test makes the bug observable: it dispatches a workspace,
# asks the agent to spawn a PTY that sleeps for 8s, and checks
# whether an `Agent Idle` notification fires for that workspace
# DURING the PTY's runtime (i.e. before the agent would resume).

echo
echo "[5d] ntfy false-idle while PTY is running..."

TS_DISPATCH=$(date +%s)
WS_PTY=$(cli kfactory dispatch "$REPO" "wait for instructions")
echo "      → minted PTY workspace: $WS_PTY"
PTY_SLUG=$(cli kfactory list 2>/dev/null | awk -v w="$WS_PTY" '$2 == w { print $3 }')
if [ -z "$PTY_SLUG" ]; then
  echo "      ❌ could not resolve slug for $WS_PTY"
  exit 1
fi
# Poll ntfy until the dispatch's own session.idle notification lands.
# Otherwise that notification fires inside our PTY-window and false-
# positives the test. 15s timeout (30 * 0.5s) covers worst-case agent
# latency. Faster + more reliable than a fixed sleep against a
# non-deterministic LLM.
#
# O(N) per poll iteration -- each call refetches the full ntfy
# history since TS_DISPATCH and jq-walks it. Acceptable here because
# N is small (a few notifications from earlier phases) and the loop
# exits as soon as the new dispatch idle lands. If a future test
# copies this shape against a high-volume topic, tighten the `since`
# bound or switch to ntfy's streaming endpoint.
for _ in $(seq 1 30); do
  COUNT=$(cli curl -sf "$NTFY_URL_INTERNAL/$TOPIC/json?poll=1&since=$TS_DISPATCH" 2>/dev/null \
    | jq -s "map(select(.time >= $TS_DISPATCH and .title == \"Agent Idle\" and (.message | contains(\"$PTY_SLUG\")))) | length")
  if [ "${COUNT:-0}" -ge 1 ]; then
    echo "      → dispatch idle notification landed"
    break
  fi
  sleep 0.5
done
# ntfy timestamps + `date +%s` are second-precision. The dispatch
# notification may have just landed at THIS second, so TS_TICK set
# now would be `time >= TS_TICK` for that notification too. Advance
# the clock past its boundary.
sleep 1

TS_TICK=$(date +%s)
cli kfactory tick "$WS_PTY" --prompt \
  "Use the pty_spawn tool to start the bash command 'sleep 8 && echo PTY_DONE'. Set notifyOnExit to true. Then stop immediately -- do not call any other tools, do not say anything else." \
  >/dev/null

# Sleep long enough that:
#   - agent ingests prompt (~1-2s)
#   - agent calls pty_spawn + finishes turn (~1-2s) -> session.idle
#   - notifyAfter (3s) elapses -> notification fires
#   - PTY's `sleep 8` is STILL running (we time-budget 7s total, PTY
#     started ~3s after TS_TICK so it exits ~T+11s)
sleep 7

# Format-pin: opencode-pty's spawn output is
# `<pty_spawned>\nID: pty_<8 hex>\n...` (SESSION_ID_BYTE_LENGTH=4 in
# node_modules/opencode-pty/dist/src/plugin/pty/session-lifecycle.js).
# Both ntfy's PTY-pending check (plugins/ntfy/src/index.ts) AND heal's
# abandoned-PTY pass (modules/scripts/opencode-heal.sh) extract the
# pty_id under that assumption. Heal's `substr(output, ..., 12)` is
# byte-length-rigid (12 = `pty_` + 8 hex chars); if upstream ever
# bumps the length, heal silently truncates / over-reads. This
# assertion catches that bump LOUDLY here rather than via a flaky
# multi-PTY recovery failure in production.
PTY_ID_RECORDED=$(ocexec sqlite3 "$OPENCODE_DB" "
  SELECT substr(
    json_extract(p.data, '\$.state.output'),
    instr(json_extract(p.data, '\$.state.output'), 'ID: pty_') + 4,
    12
  )
  FROM part p
  JOIN message m ON p.message_id = m.id
  JOIN session s ON m.session_id = s.id
  WHERE s.workspace_id = '$WS_PTY'
    AND json_extract(p.data, '\$.tool') = 'pty_spawn'
  ORDER BY p.time_created DESC LIMIT 1;")
if ! echo "$PTY_ID_RECORDED" | grep -qE '^pty_[a-f0-9]{8}$'; then
  echo "      ❌ opencode-pty pty_id format drift: got '$PTY_ID_RECORDED'"
  echo "         expected exactly 'pty_<8 hex chars>'. heal's substr(...,12)"
  echo "         AND ntfy's regex assume that shape -- a bump in"
  echo "         SESSION_ID_BYTE_LENGTH silently breaks both. Re-pin or"
  echo "         re-derive the magic length."
  rm -f "$NTFY_LOG" 2>/dev/null || true
  exit 1
fi
echo "      ✓ pty_id format matches pinned shape ($PTY_ID_RECORDED)"

# Anything that fires before TS_TICK + 10 must be a false positive
# (PTY hasn't exited yet, agent hasn't been told to resume, so the
# "Agent Idle" notification is wrong about the session being done).
DEADLINE=$((TS_TICK + 10))

NTFY_LOG=$(mktemp)
cli curl -sf "$NTFY_URL_INTERNAL/$TOPIC/json?poll=1&since=$TS_TICK" >"$NTFY_LOG" 2>/dev/null || true

if ! FALSE_COUNT=$(jq -s "map(select(.time < $DEADLINE and .title == \"Agent Idle\" and (.message | contains(\"$PTY_SLUG\")))) | length" <"$NTFY_LOG" 2>&1); then
  echo "      ❌ jq parse failed on ntfy poll output: $FALSE_COUNT"
  head -5 "$NTFY_LOG" | sed 's/^/         /'
  rm -f "$NTFY_LOG"
  exit 1
fi

if [ "$FALSE_COUNT" -eq 0 ]; then
  echo "      ✓ no false-idle notification fired while PTY was running"
  rm -f "$NTFY_LOG"
else
  echo "      ❌ $FALSE_COUNT false-idle 'Agent Idle' notification(s) fired"
  echo "         while a PTY was still running (deadline=TS_TICK+10=$DEADLINE):"
  jq -s "map(select(.time < $DEADLINE and .title == \"Agent Idle\" and (.message | contains(\"$PTY_SLUG\")))) | .[] | {time, title, message}" <"$NTFY_LOG" |
    sed 's/^/         /'
  echo ""
  echo "         Mechanism: agent spawns PTY -> turn completes ->"
  echo "         session.idle -> notifyAfter (3s) -> ntfy fires."
  echo "         Meanwhile PTY is still running; when it exits the"
  echo "         opencode-pty notification-manager.js injects a new"
  echo "         user message and the agent resumes. The 'idle' was"
  echo "         transient, not a real task-done signal."
  rm -f "$NTFY_LOG"
  exit 1
fi
