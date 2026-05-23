# Sweep zombie assistant turns + emit affected workspace IDs to the
# recovery queue (recovery-sweep ticks ONLY those workspaces). Handles
# BOTH opencode v1 (`message` table, role in JSON) and v2
# (`session_message` table, role in `type` column) -- whichever doesn't
# exist on a given DB is a silent no-op.
#
# Wiring: modules/recovery.nix attaches this as ExecStartPre on the
# opencode-serve unit.
# Usage: opencode-heal <PATH-TO-DB>
# Env:   KFACTORY_RECOVERY_QUEUE (default /run/kfactory/recovery-queue.json)
# First-boot tolerant: missing DB writes empty queue + exits 0.

if [ $# -lt 1 ]; then
  echo "usage: opencode-heal <PATH-TO-DB>" >&2
  exit 2
fi
DB=$1
QUEUE_FILE=${KFACTORY_RECOVERY_QUEUE:-/run/kfactory/recovery-queue.json}

if [ ! -f "$DB" ]; then
  # First boot. Write empty queue so consumers don't special-case.
  mkdir -p "$(dirname "$QUEUE_FILE")"
  echo '[]' >"$QUEUE_FILE"
  echo "opencode-heal: db-not-found ($DB); queue=empty"
  exit 0
fi

# `-cmd ".timeout 30000"` over `PRAGMA busy_timeout=30000` -- PRAGMA
# echoes its value as a result row in default output mode, polluting
# heal_collect/heal_update outputs. Array form keeps the `.timeout`
# value as one CLI arg under bash word-splitting.
SQLITE=(sqlite3 -cmd ".timeout 30000")

# Literal `name='...'` in SQL (no shell interpolation) so the surface
# is closed against future attacker-influenced input.
v1_exists() {
  local n
  n=$("${SQLITE[@]}" "$DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='message';")
  [ "$n" = "1" ]
}

v2_exists() {
  local n
  n=$("${SQLITE[@]}" "$DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='session_message';")
  [ "$n" = "1" ]
}

# Emits one workspace_id per line for sessions with a stuck row.
heal_collect() {
  local table=$1 role_predicate=$2
  "${SQLITE[@]}" "$DB" <<SQL || true
SELECT DISTINCT session.workspace_id
  FROM $table
  JOIN session ON $table.session_id = session.id
  WHERE $role_predicate
    AND json_extract($table.data, '\$.time.completed') IS NULL
    AND session.workspace_id IS NOT NULL;
SQL
}

# Marks stuck rows: time.completed=now, finish='interrupted-by-restart',
# AND error={name: "MessageAbortedError", data: {message: ...}}. The
# error.name field is what opencode's UI checks (the
# `MessageAbortedError` branch in
# packages/app/src/pages/session/message-timeline.data.ts) to render
# the interrupted badge -- finish alone is informational and doesn't
# drive rendering. Idempotency: `time.completed IS NULL` ALREADY
# scopes the update to unhealed rows + the explicit
# `error.name IS NOT 'MessageAbortedError'` predicate makes
# re-running heal on already-marked rows a no-op (matches the same
# guard on heal_process_pty_v1). Echoes row-count touched.
heal_update() {
  local table=$1 role_predicate=$2
  "${SQLITE[@]}" "$DB" <<SQL
UPDATE $table
SET data = json_set(
  json_set(
    json_set(data, '\$.time.completed', cast(strftime('%s','now') as integer) * 1000),
    '\$.finish', 'interrupted-by-restart'
  ),
  '\$.error',
  json('{"name":"MessageAbortedError","data":{"message":"opencode-serve restarted; turn interrupted mid-flight"}}')
)
WHERE $role_predicate
  AND json_extract(data, '\$.time.completed') IS NULL
  AND json_extract(data, '\$.error.name') IS NOT 'MessageAbortedError';
SELECT changes();
SQL
}

# Abandoned-PTY detection (kfactory-specific): when opencode-serve
# restarts, opencode-pty's in-memory `sessions: Map<id, Session>`
# vanishes; PTY processes die with their parent. The agent's spawn
# turn was `time.completed=set` (the tool returned normally) so heal's
# stuck-turn predicate doesn't match. Without this pass the task is
# silently dropped: no recovery prompt, no UI signal.
#
# Strategy: build a TEMP TABLE of (message_id, session_id, workspace_id,
# spawn_time, pty_id) for every pty_spawn(notifyOnExit=true) tool part,
# then DELETE entries that DO have a matching exit message (user-role
# text part containing </pty_exited> AND the specific pty_id from this
# spawn). What survives is the set of abandoned PTYs. The temp table
# is consumed by a UPDATE (marks containing messages with
# error.name=MessageAbortedError for UI affordance) and a SELECT
# (emits workspace_ids for the recovery queue).
#
# pty_id extraction: opencode-pty's pty_spawn returns
# `<pty_spawned>\nID: pty_<8 hex chars>\n...` (per
# node_modules/opencode-pty/dist/src/plugin/pty/session-lifecycle.js:5,
# SESSION_ID_BYTE_LENGTH = 4 -> 8 hex chars -> `pty_` + 8 = 12 chars).
# `substr(output, instr(output, 'ID: pty_')+4, 12)` extracts exactly
# the id. Brittle if upstream changes the byte length -- documented
# in docs/spec.md as a known third-party-format coupling.
#
# Anchoring on the specific pty_id (not just '</pty_exited>') closes
# the multi-PTY false-negative class: if pty_A exited and pty_B is
# still pending, a string-only match on '</pty_exited>' would consider
# both resolved by pty_A's exit message. The role=user filter alone
# isn't enough -- an operator could quote the literal closing tag in
# a prompt and false-resolve every prior spawn in the session.
#
# v1-only today: v2 doesn't yet store assistant message parts in this
# version of opencode (the v1 message table is still the active one
# for assistant rows). A v2 skeleton is the obvious next addition.
#
# Single sqlite3 invocation -- temp tables don't persist across
# separate `${SQLITE[@]} "$DB"` calls. Emits one workspace_id per
# line; caller counts rows with `wc -l`. Idempotency: UPDATEs guard
# on `error.name IS NOT 'MessageAbortedError'` so re-runs are no-ops.
heal_process_pty_v1() {
  "${SQLITE[@]}" "$DB" <<'SQL' || true
DROP TABLE IF EXISTS temp.abandoned_pty;
CREATE TEMP TABLE abandoned_pty AS
SELECT
  p.message_id,
  p.session_id,
  s.workspace_id,
  p.time_created AS spawn_time,
  substr(
    json_extract(p.data, '$.state.output'),
    instr(json_extract(p.data, '$.state.output'), 'ID: pty_') + 4,
    12
  ) AS pty_id
FROM part p
JOIN message m ON p.message_id = m.id
JOIN session s ON m.session_id = s.id
WHERE json_extract(p.data, '$.type') = 'tool'
  AND json_extract(p.data, '$.tool') = 'pty_spawn'
  AND json_extract(p.data, '$.state.input.notifyOnExit') = 1
  AND s.workspace_id IS NOT NULL
  AND json_extract(p.data, '$.state.output') IS NOT NULL
  AND instr(json_extract(p.data, '$.state.output'), 'ID: pty_') > 0;

DELETE FROM abandoned_pty WHERE rowid IN (
  SELECT a.rowid FROM abandoned_pty a
  WHERE EXISTS (
    SELECT 1 FROM part p2
    JOIN message m2 ON p2.message_id = m2.id
    WHERE p2.session_id = a.session_id
      AND p2.time_created > a.spawn_time
      AND json_extract(p2.data, '$.type') = 'text'
      AND json_extract(p2.data, '$.text') LIKE '%</pty_exited>%'
      AND json_extract(p2.data, '$.text') LIKE '%' || a.pty_id || '%'
      AND json_extract(m2.data, '$.role') = 'user'
  )
);

UPDATE message
SET data = json_set(
  data,
  '$.error',
  json('{"name":"MessageAbortedError","data":{"message":"opencode-pty session killed by opencode-serve restart"}}')
)
WHERE id IN (SELECT message_id FROM abandoned_pty)
  AND json_extract(data, '$.error.name') IS NOT 'MessageAbortedError';

SELECT DISTINCT workspace_id FROM abandoned_pty;
SQL
}

# Collect BEFORE update: the update clears the `time.completed IS NULL`
# predicate we're filtering on.
affected_v1=""
affected_v2=""
affected_pty_v1=""
updated_v1=0
updated_v2=0
updated_pty_v1=0

if v1_exists; then
  affected_v1=$(heal_collect message "json_extract(message.data, '\$.role') = 'assistant'")
  updated_v1=$(heal_update message "json_extract(data, '\$.role') = 'assistant'")
  # heal_process_pty_v1 emits one workspace_id per line. Count
  # non-empty lines for the JSON log; the count's sole purpose is
  # operator visibility (every workspace also lands in the queue
  # below). Both grep paths use `|| true` because grep exits 1 on
  # zero matches and the script runs under `set -e`.
  affected_pty_v1=$(heal_process_pty_v1)
  updated_pty_v1=$(printf '%s\n' "$affected_pty_v1" | grep -c . || true)
  updated_pty_v1=${updated_pty_v1:-0}
fi

if v2_exists; then
  affected_v2=$(heal_collect session_message "session_message.type = 'assistant'")
  updated_v2=$(heal_update session_message "type = 'assistant'")
fi

# Merge v1 + v2 + abandoned-PTY outputs (one id per line) and dedupe.
mkdir -p "$(dirname "$QUEUE_FILE")"
ids=$(printf '%s\n%s\n%s\n' "$affected_v1" "$affected_v2" "$affected_pty_v1" |
  grep -v '^$' |
  sort -u || true)
if [ -z "$ids" ]; then
  echo '[]' >"$QUEUE_FILE"
  affected_count=0
else
  printf '%s\n' "$ids" | jq -R . | jq -s . >"$QUEUE_FILE"
  affected_count=$(printf '%s\n' "$ids" | wc -l)
fi

# JSON log line so monitoring / scripted consumers parse a stable
# schema (the prior space-separated `k=v` shape was position-fragile
# -- adding `abandoned_pty` between `v2_session_message` and
# `affected_workspaces` silently shifted columns for anyone field-
# splitting on it). Human-readable enough; `jq` already in PATH.
heal_json=$(jq -nc \
  --argjson v1 "$updated_v1" \
  --argjson v2 "$updated_v2" \
  --argjson pty "$updated_pty_v1" \
  --argjson n "$affected_count" \
  '{v1_message: $v1, v2_session_message: $v2, abandoned_pty: $pty, affected_workspaces: $n}')
echo "opencode-heal: $heal_json"
