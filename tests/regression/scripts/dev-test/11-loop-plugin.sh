# [11] Loop plugin -- end-to-end against the real opencode model.
#
# The /loop slash command writes a state file; the plugin's hot path
# is the session.idle handler that reads it, checks the last-line
# sentinel, and either injects a continuation prompt or clears state.
# We exercise that whole path with the real big-pickle model behind
# opencode-serve -- not isolated forgeries -- so the test fails if
# any link in the chain breaks (event subscription, state read,
# subagent guard, sentinel match, write-back, iteration cap,
# session.deleted cleanup).
#
# The slash-command UI itself isn't reachable via HTTP, so we
# simulate the user invoking /loop by writing the state file
# directly (= what loop-start does). The rest -- continuation
# prompts, model responses, idles, cleanup -- runs through opencode
# proper without harness intervention.
#
# State file path (opencode container):
#   /root/.local/state/kfactory-loop/<sha256(directory) | head -c 16>.json

echo
echo "[11] Loop plugin -- end-to-end auto-continuation against big-pickle..."

# Helper: compute the loop state file path for a workspace directory.
loop_state_file() {
  local dir="$1"
  local key
  key=$(ocexec sh -c "printf '%s' '$dir' | sha256sum" | cut -d' ' -f1 | head -c 16)
  echo "/root/.local/state/kfactory-loop/${key}.json"
}

# Helper: write a loop state file (= what the /loop slash command's
# loop-start tool does, minus the operator-facing tool-call surface).
# Args: <state_file> <sessionID> <iteration> <maxIterations> <sentinel> <task>
write_loop_state() {
  local sf="$1" sid="$2" iter="$3" max="$4" sentinel="$5" task="$6"
  ocexec mkdir -p /root/.local/state/kfactory-loop
  ocexec_i sh -c "cat > $sf" <<JSON
{
  "schemaVersion": 1,
  "active": true,
  "iteration": $iter,
  "maxIterations": $max,
  "sentinel": "$sentinel",
  "sessionID": "$sid",
  "task": "$task",
  "consecutiveFailures": 0
}
JSON
}

# Helper: dump state file JSON (empty string if missing).
read_loop_state() {
  local sf="$1"
  ocexec sh -c "[ -e '$sf' ] && cat '$sf' || true"
}

# Helper: count messages in a session.
loop_msg_count() {
  local wsid="$1" sid="$2"
  cli curl -sf -H "Authorization: Bearer $TOKEN" \
    -H "x-opencode-workspace: $wsid" \
    "$OPENCODE_BASE/session/$sid/message" | jq 'length'
}

# Helper: last user message text.
loop_last_user_text() {
  local wsid="$1" sid="$2"
  cli curl -sf -H "Authorization: Bearer $TOKEN" \
    -H "x-opencode-workspace: $wsid" \
    "$OPENCODE_BASE/session/$sid/message" |
    jq -r '[.[] | select(.info.role == "user")] | last
           | (.parts // []) | map(select(.type == "text") | .text) | join("")'
}

# Helper: last assistant message's joined text (mirrors the plugin's
# lastAssistantText concatenation: every text-typed part of the most-
# recent assistant message, joined by newline). Lets the test inspect
# the same string the plugin's matchesSentinel sees.
loop_last_assistant_text() {
  local wsid="$1" sid="$2"
  cli curl -sf -H "Authorization: Bearer $TOKEN" \
    -H "x-opencode-workspace: $wsid" \
    "$OPENCODE_BASE/session/$sid/message" |
    jq -r '[.[] | select(.info.role == "assistant")] | last
           | (.parts // []) | map(select(.type == "text") | .text) | join("\n")'
}

# Helper: poll the state file until it clears OR a max wait elapses.
# Prints final iteration if still present, or "cleared" if removed.
# Used as the "loop terminated" sync point.
wait_for_state_clear() {
  local sf="$1" timeout="${2:-90}"
  local end
  end=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if ! ocexec sh -c "[ -e '$sf' ]"; then
      echo "cleared"
      return
    fi
    sleep 1
  done
  ocexec sh -c "jq -r .iteration '$sf' 2>/dev/null || echo unknown"
}

# Helper: poll the state file until iteration >= target OR a max
# wait elapses. Prints the observed iteration (or "cleared" if state
# was cleared, or "timeout" if neither happened).
wait_for_iteration() {
  local sf="$1" target="$2" timeout="${3:-60}"
  local end iter
  end=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if ! ocexec sh -c "[ -e '$sf' ]"; then
      echo "cleared"
      return
    fi
    iter=$(ocexec sh -c "cat '$sf'" | jq -r '.iteration // empty' 2>/dev/null || true)
    if [ -n "$iter" ] && [ "$iter" -ge "$target" ]; then
      echo "$iter"
      return
    fi
    sleep 1
  done
  echo "timeout"
}

# Helper: create an empty session via API (no model run kicked).
create_empty_session() {
  local wsid="$1" parent="${2:-}"
  local body='{}'
  if [ -n "$parent" ]; then
    body="{\"parentID\":\"$parent\"}"
  fi
  cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$body" \
    "$OPENCODE_BASE/session?workspace=$wsid" | jq -r .id
}

# Helper: send a prompt to a session (sync, waits for the model
# response). Used to seed a session with a real LLM-driven turn so
# we can then write loop state on top and exercise the
# auto-continuation hot path.
send_prompt_sync() {
  local wsid="$1" sid="$2" prompt="$3"
  cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg p "$prompt" '{parts:[{type:"text",text:$p}]}')" \
    "$OPENCODE_BASE/session/$sid/message?workspace=$wsid" >/dev/null
}

# Set up a workspace dedicated to phase 11. Don't reuse earlier
# phases' workspaces -- those have completed sessions whose state +
# message history would muddy the assertions here.
WS_LOOP=$(cli kfactory dispatch "$REPO" "I am setting up for a loop test; just say hi and wait")
WS_LOOP_NAME=$(cli kfactory list 2>/dev/null | tail -n +2 |
  awk -v w="$WS_LOOP" '$2 == w { print $3 }')
WS_LOOP_DIR="/var/lib/kfactory/workspaces/${WS_LOOP_NAME}"
WS_LOOP_SF=$(loop_state_file "$WS_LOOP_DIR")
echo "      → workspace: $WS_LOOP ($WS_LOOP_NAME)"
echo "      → state file: $WS_LOOP_SF"

# Wait for the dispatch's initial agent turn to settle so the
# workspace's root session has a stable assistant message before any
# sub-test starts. 10s covers cold-start + the model's "Hi" reply.
sleep 10

clear_loop_state() {
  ocexec rm -f "$WS_LOOP_SF"
}

# ---- 11a: end-to-end "count to N" loop terminates on sentinel ----
#
# The model is asked to count 1..3, one number per response, and
# emit "LOOPDONE" as the FINAL line on its 3rd response. The plugin
# is responsible for injecting continuation prompts between each
# model turn so the agent gets another chance at the task. The loop
# must terminate via sentinel match (not via maxIterations cap or
# timeout), and we want at least 2 continuations injected to prove
# the hot path actually drove multiple iterations -- not just one
# fluke turn.

echo
echo "      ---- 11a: real-model auto-continuation drives + terminates ----"
clear_loop_state

SID_E2E=$(create_empty_session "$WS_LOOP")
if [ -z "$SID_E2E" ] || [ "$SID_E2E" = "null" ]; then
  echo "      ❌ failed to create empty session for 11a"
  exit 1
fi

# Seed the session with the counting task. We use a prompt the
# model can answer in ONE assistant turn (just emit "1") so that
# subsequent iterations are clearly driven by the loop plugin
# rather than opencode's runner internally multi-stepping a single
# prompt. The task description embedded in `task` (written into
# the loop state below) tells the model what to do across the
# continuations the plugin will inject.
COUNT_TASK="Output the single character 1 on its own line. Then stop. Do not call any tools, do not emit anything else."
send_prompt_sync "$WS_LOOP" "$SID_E2E" "$COUNT_TASK"

# Initial-turn settle: the first prompt is sync but the model run
# is async on the server side. Wait until the assistant message
# appears with at least one text part.
INIT_WAIT_END=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$INIT_WAIT_END" ]; do
  HAS_TEXT=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
    -H "x-opencode-workspace: $WS_LOOP" \
    "$OPENCODE_BASE/session/$SID_E2E/message" |
    jq '[.[] | select(.info.role == "assistant") | (.parts // [])[] | select(.type == "text") | .text] | length')
  if [ -n "$HAS_TEXT" ] && [ "$HAS_TEXT" -ge 1 ]; then
    break
  fi
  sleep 1
done
if [ "$HAS_TEXT" -lt 1 ]; then
  echo "      ❌ initial model turn never produced an assistant text part"
  exit 1
fi
INIT_ASSIST=$(loop_last_assistant_text "$WS_LOOP" "$SID_E2E")
INIT_MSG_COUNT=$(loop_msg_count "$WS_LOOP" "$SID_E2E")
echo "      → initial assistant text (head): '$(printf '%s' "$INIT_ASSIST" | tr '\n' ' ' | head -c 80)'"
echo "      → initial msg count: $INIT_MSG_COUNT"

# Now write loop state -- this is the operator's /loop invocation.
# maxIterations=8 leaves headroom for the model to wander a turn or
# two before reaching the sentinel; if it loops longer than 8 we
# know the matcher is broken (not the model).
# `task` is the human-readable description embedded in every
# continuation prompt. The model reads it on each iteration so it
# knows what to do when told to "continue working on the task".
write_loop_state "$WS_LOOP_SF" "$SID_E2E" 0 8 "LOOPDONE" \
  "You are counting up by one. Your last assistant turn emitted some integer N. Your next response should emit ONLY the integer N+1 on its own line. When you reach 3, emit 3 on one line, then LOOPDONE on the final line."

# The state file is now active. The plugin re-reads it on every
# session.idle. The model's most-recent turn was a "1" reply (or
# the first counted number), so the next idle (when the model
# finishes the next continuation it's about to receive) triggers
# the iteration counter.
#
# BUT: the model just finished its initial turn before we wrote the
# state file, so the corresponding session.idle event ALREADY
# fired -- the plugin missed it. We need to fire one ourselves to
# kick the first iteration.
cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_E2E/abort" >/dev/null

# Wait for either sentinel match (state cleared) or a clear failure
# signal (cap hit, timeout). Real end-to-end: this hands control to
# the plugin + model for up to 120s.
RESULT=$(wait_for_state_clear "$WS_LOOP_SF" 120)
FINAL_MSG_COUNT=$(loop_msg_count "$WS_LOOP" "$SID_E2E")
FINAL_ASSIST=$(loop_last_assistant_text "$WS_LOOP" "$SID_E2E")

# How many continuations did the plugin inject? Each continuation
# prompt starts with "[loop iteration N/M]" -- count those user
# messages in the session.
CONT_COUNT=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_E2E/message" |
  jq '[.[] | select(.info.role == "user") | (.parts // [])[] | select(.type == "text" and (.text | startswith("[loop iteration ")))] | length')

echo "      → final state: $RESULT"
echo "      → injected continuations: $CONT_COUNT"
echo "      → final msg count: $FINAL_MSG_COUNT"
echo "      → final assistant (tail): '$(printf '%s' "$FINAL_ASSIST" | tail -c 80)'"

if [ "$RESULT" != "cleared" ]; then
  echo "      ❌ loop did NOT terminate within 120s (state still iter=$RESULT)"
  echo "         either sentinel match is broken or the plugin stopped"
  echo "         dispatching continuations. plugin logs:"
  docker logs --tail 200 "$OPENCODE_CONTAINER" 2>&1 |
    grep -i loop | tail -15 | sed 's/^/         /'
  exit 1
fi
if [ "$CONT_COUNT" -lt 1 ]; then
  echo "      ❌ plugin injected $CONT_COUNT continuation(s), expected >= 1"
  echo "         the loop never injected a continuation -- the plugin's"
  echo "         event handler isn't firing on session.idle at all."
  exit 1
fi
case "$FINAL_ASSIST" in
  *"LOOPDONE")
    : # last line is the sentinel; the plugin TERMINATED on match.
    ;;
  *)
    echo "      ❌ final assistant text does not end with the sentinel:"
    echo "         '$(printf '%s' "$FINAL_ASSIST" | tail -c 200)'"
    echo "         loop cleared state but for a different reason than"
    echo "         sentinel match -- likely deleted session or fault path."
    exit 1
    ;;
esac

# Iteration progression: each continuation prompt is built from
# `state.iteration + 1` (the plugin's `next` local). The Nth
# continuation should declare `[loop iteration N/M]`. If two
# different injections both declare `iteration 1`, that's the
# operator-visible symptom of the iteration counter never advancing
# (matches the user's "loop showed 2/20 then stalled" report -- two
# handlers raced on a stale local state and both wrote next=1).
ITER_LABELS=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_E2E/message" |
  jq -r '[.[] | select(.info.role == "user") | (.parts // [])[]
          | select(.type == "text" and (.text | startswith("[loop iteration ")))
          | .text]
         | map(capture("^\\[loop iteration (?<n>[0-9]+)/")) | map(.n | tonumber)
         | tostring')
echo "      → iteration labels: $ITER_LABELS"
# Expect ascending sequence (1,2,3,...). Duplicates ([1,1]) or
# non-monotonic = the race condition where two handlers read the
# same stale state.iteration and both wrote `next = state.iter + 1`,
# stalling iteration progression. With strictly increasing, every
# new continuation reflects ONE more handler-write to disk.
NOT_INCREASING=$(echo "$ITER_LABELS" |
  jq '[range(1; length) as $i | if .[$i] > .[$i-1] then 0 else 1 end] | add // 0')
if [ "$NOT_INCREASING" != "0" ]; then
  echo "      ❌ iteration labels are NOT strictly increasing: $ITER_LABELS"
  echo "         this is the iteration-stall bug: two handlers raced on the"
  echo "         same stale local state and both injected with next=N."
  echo "         operator-visible symptom: loop appears to 'stall' at iter N."
  exit 1
fi
echo "      ✓ loop drove $CONT_COUNT continuation(s) and terminated on sentinel"
echo "      ✓ iteration labels strictly increasing: $ITER_LABELS"

# ---- 11b: maxIterations cap halts the loop ----
#
# Pin sentinel to a string CONTAINING A NEWLINE (multi-line). The
# matcher checks single trimmed lines against the sentinel string;
# a multi-line sentinel can NEVER equal any single trimmed line, so
# matchesSentinel always returns false. The loop can only terminate
# via the cap path -- giving us a deterministic cap regression.
#
# With maxIterations=1: handleIdle on the initial idle bumps iter
# from 0 to 1 and injects one continuation. The model's response
# fires the next idle; handleIdle sees iter (1) >= maxIterations (1),
# clears state, and emits the "hit maxIterations" log line.

echo
echo "      ---- 11b: maxIterations cap halts the loop ----"
clear_loop_state

SID_CAP=$(create_empty_session "$WS_LOOP")
send_prompt_sync "$WS_LOOP" "$SID_CAP" \
  "Output the single word 'tick' as your response. Do not output anything else."

INIT_WAIT_END=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$INIT_WAIT_END" ]; do
  HAS_TEXT=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
    -H "x-opencode-workspace: $WS_LOOP" \
    "$OPENCODE_BASE/session/$SID_CAP/message" |
    jq '[.[] | select(.info.role == "assistant") | (.parts // [])[] | select(.type == "text") | .text] | length')
  if [ -n "$HAS_TEXT" ] && [ "$HAS_TEXT" -ge 1 ]; then
    break
  fi
  sleep 1
done

# `CAP_UNMATCHABLE_SENTINEL` contains a literal `\n` escape, which
# write_loop_state passes through the heredoc verbatim; jq + JSON.parse
# decode it into an actual newline in the in-memory sentinel string.
# matchesSentinel splits assistant text by `\r?\n` and compares each
# single trimmed line === sentinel. A sentinel that itself contains a
# newline can't equal any single line, so the match path is unreachable.
CAP_UNMATCHABLE_SENTINEL='LINE-A\nLINE-B'
write_loop_state "$WS_LOOP_SF" "$SID_CAP" 0 1 "$CAP_UNMATCHABLE_SENTINEL" "11b cap"
cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_CAP/abort" >/dev/null

CAP_RESULT=$(wait_for_state_clear "$WS_LOOP_SF" 120)
CAP_CONT=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_CAP/message" |
  jq '[.[] | select(.info.role == "user") | (.parts // [])[] | select(.type == "text" and (.text | startswith("[loop iteration ")))] | length')

if [ "$CAP_RESULT" != "cleared" ]; then
  echo "      ❌ cap test: state did not clear within 120s (got '$CAP_RESULT')"
  exit 1
fi
# Cap path must have actually fired (not a fluke sentinel match).
# The 11a iteration-progression assertion is what catches the
# stalled-iteration race; this check just guards against the
# wrong-termination-branch scenario.
if ! docker logs --tail 1000 "$OPENCODE_CONTAINER" 2>&1 |
     grep -q "loop: hit maxIterations=1"; then
  echo "      ❌ cap test: state cleared but no 'hit maxIterations=1' log line"
  echo "         loop may have terminated via a wrong path."
  exit 1
fi
# With maxIterations=1 and the race fix: handler reads iter=0, writes
# iter=1, injects one continuation. Next idle sees iter (1) >= max (1)
# and clears. Exactly one continuation. Two would be the race (caught
# separately by 11a's strict-increasing-iteration-labels assertion);
# accepting it here would silently hide a regression in the cap path.
if [ "$CAP_CONT" -ne 1 ]; then
  echo "      ❌ cap test: $CAP_CONT continuation(s) injected with maxIter=1, expected exactly 1"
  exit 1
fi
echo "      ✓ cap halted the loop after $CAP_CONT continuation"

# ---- 11c: manual state clear (simulates /loop-stop) halts the loop ----
#
# The /loop-stop slash command's tool path simply deletes the state
# file. We bypass the tool wiring (operator-facing) and do the
# delete ourselves mid-flight. After the delete, the plugin must
# stop injecting continuations even though the model would otherwise
# keep going. Catches regressions where /loop-stop's `clearState`
# fails to break the in-flight handler's writeStateTo (a stale
# in-memory copy used to silently resurrect cleared state).

echo
echo "      ---- 11c: manual state clear stops continuations ----"
clear_loop_state

SID_STOP=$(create_empty_session "$WS_LOOP")
send_prompt_sync "$WS_LOOP" "$SID_STOP" \
  "Output the word 'tick' on each response and nothing else. Continue until told otherwise."

INIT_WAIT_END=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$INIT_WAIT_END" ]; do
  HAS_TEXT=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
    -H "x-opencode-workspace: $WS_LOOP" \
    "$OPENCODE_BASE/session/$SID_STOP/message" |
    jq '[.[] | select(.info.role == "assistant") | (.parts // [])[] | select(.type == "text") | .text] | length')
  if [ -n "$HAS_TEXT" ] && [ "$HAS_TEXT" -ge 1 ]; then
    break
  fi
  sleep 1
done

# Same trick as 11b: multi-line sentinel is structurally unreachable
# (matchesSentinel splits text by `\r?\n` and compares each single
# trimmed line against the sentinel string; a sentinel containing a
# newline can't equal any single line). Prevents the model from
# helpfully terminating the loop by copying the sentinel verbatim
# from the continuation prompt -- the 11c test specifically needs
# the loop to keep running until WE manually clear state.
write_loop_state "$WS_LOOP_SF" "$SID_STOP" 0 10 'LINE-A\nLINE-B' "11c stop"
cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_STOP/abort" >/dev/null

# Wait for at least 2 iterations to confirm the loop is actually
# running before we yank the rug.
MID_ITER=$(wait_for_iteration "$WS_LOOP_SF" 2 90)
case "$MID_ITER" in
  ""|"timeout"|"cleared"|"unknown")
    echo "      ❌ stop test: did not observe iteration >= 2 within 90s (got '$MID_ITER')"
    echo "         loop never gained traction; stop semantics untestable."
    exit 1
    ;;
esac
echo "      → reached iteration $MID_ITER; clearing state file (simulates /loop-stop)"
clear_loop_state

# Capture the continuation count NOW. After the manual clear, no
# more continuations should be injected. Wait long enough for any
# pending model run to finish + the resulting idle to be processed
# by the plugin (with no state file, the plugin no-ops).
STOP_CONT_AT_CLEAR=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_STOP/message" |
  jq '[.[] | select(.info.role == "user") | (.parts // [])[] | select(.type == "text" and (.text | startswith("[loop iteration ")))] | length')

# Wait a generous window for any racing in-flight handler to land
# its writeStateTo (which would resurrect state) AND for any
# subsequent model run to idle + be handled.
sleep 30

# If the state file came back, the in-flight handler resurrected it
# -- that's the exact bug stateStillOurs is meant to prevent.
if ocexec sh -c "[ -e '$WS_LOOP_SF' ]"; then
  echo "      ❌ state file resurrected after manual clear:"
  read_loop_state "$WS_LOOP_SF" | sed 's/^/         /'
  echo "         stateStillOurs guard failed; the handler raced the clear."
  exit 1
fi

STOP_CONT_AFTER=$(cli curl -sf -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_STOP/message" |
  jq '[.[] | select(.info.role == "user") | (.parts // [])[] | select(.type == "text" and (.text | startswith("[loop iteration ")))] | length')

# Allow at most ONE post-clear continuation: a handler that began
# before the clear can still complete its write of a continuation
# prompt. The next handler will see no state and skip.
DELTA=$(( STOP_CONT_AFTER - STOP_CONT_AT_CLEAR ))
if [ "$DELTA" -gt 1 ]; then
  echo "      ❌ stop test: $DELTA continuation(s) injected AFTER state clear"
  echo "         (before clear: $STOP_CONT_AT_CLEAR, after 30s wait: $STOP_CONT_AFTER)"
  echo "         /loop-stop semantics broken -- continuations leaked past clear."
  exit 1
fi
echo "      ✓ manual clear stopped the loop (deltas: continuations=$DELTA, state=gone)"

# ---- 11d: idle on a wrong session is a no-op ----
#
# Loop state targets session A. session.idle fires on session B
# (different ID, same workspace). The handler's
# `state.sessionID !== sessionID` guard must drop the event. No
# LLM needed; we abort empty sessions which fires idle directly.

echo
echo "      ---- 11d: idle on a different session in same workspace is no-op ----"
clear_loop_state

SID_A=$(create_empty_session "$WS_LOOP")
SID_B=$(create_empty_session "$WS_LOOP")
if [ -z "$SID_A" ] || [ "$SID_A" = "null" ] || [ -z "$SID_B" ] || [ "$SID_B" = "null" ] || [ "$SID_A" = "$SID_B" ]; then
  echo "      ❌ failed to create two distinct empty sessions"
  exit 1
fi
write_loop_state "$WS_LOOP_SF" "$SID_A" 0 5 "DONE" "11d wrong session"
cli curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_B/abort" >/dev/null
sleep 3

STATE_AFTER=$(read_loop_state "$WS_LOOP_SF")
if [ -z "$STATE_AFTER" ]; then
  echo "      ❌ state was cleared by an idle on the WRONG session"
  exit 1
fi
SID_PERSIST=$(echo "$STATE_AFTER" | jq -r .sessionID)
ITER_PERSIST=$(echo "$STATE_AFTER" | jq -r .iteration)
if [ "$SID_PERSIST" != "$SID_A" ] || [ "$ITER_PERSIST" != "0" ]; then
  echo "      ❌ state mutated: sessionID=$SID_PERSIST iter=$ITER_PERSIST"
  echo "         (expected sessionID=$SID_A iter=0)"
  exit 1
fi
MSG_AFTER_A=$(loop_msg_count "$WS_LOOP" "$SID_A")
MSG_AFTER_B=$(loop_msg_count "$WS_LOOP" "$SID_B")
if [ "$MSG_AFTER_A" != "0" ] || [ "$MSG_AFTER_B" != "0" ]; then
  echo "      ❌ unexpected messages: A=$MSG_AFTER_A B=$MSG_AFTER_B (both should be 0)"
  exit 1
fi
echo "      ✓ wrong-session idle ignored (state pinned to A, no injection)"

# ---- 11e: session.deleted clears loop state ----
#
# Loop state targets session S. DELETE the session via API. The
# plugin's session.deleted event handler routes through
# tryClearState. Without that path, deleting the loop's target
# session leaves dangling state that blocks future /loop-start.

echo
echo "      ---- 11e: session.deleted clears loop state ----"
clear_loop_state

SID_DEL=$(create_empty_session "$WS_LOOP")
write_loop_state "$WS_LOOP_SF" "$SID_DEL" 2 10 "DONE" "11e deleted"
cli curl -sf -X DELETE -H "Authorization: Bearer $TOKEN" \
  -H "x-opencode-workspace: $WS_LOOP" \
  "$OPENCODE_BASE/session/$SID_DEL" >/dev/null
sleep 3

STATE_AFTER=$(read_loop_state "$WS_LOOP_SF")
if [ -n "$STATE_AFTER" ]; then
  echo "      ❌ session.deleted did NOT clear loop state:"
  echo "         $STATE_AFTER"
  exit 1
fi
echo "      ✓ session.deleted cleared loop state"

# Final tidy-up.
clear_loop_state
