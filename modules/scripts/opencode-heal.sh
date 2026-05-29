# Heal opencode restarts: mark interrupted assistant turns, queue affected
# workspace IDs for recovery-sweep, and tolerate first boot by writing `[]`.
# Handles v1 `message` and v2 `session_message`; absent tables are no-ops.
# Wired by modules/recovery.nix as opencode-serve ExecStartPre.
# Usage: opencode-heal <PATH-TO-DB>
# Env: KFACTORY_RECOVERY_QUEUE (default /run/kfactory/recovery-queue.json)

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
    AND CASE WHEN json_valid($table.data) THEN json_extract($table.data, '\$.time.completed') IS NULL ELSE 0 END
    AND session.workspace_id IS NOT NULL;
SQL
}

# Mark stuck rows as interrupted. UI rendering keys on
# error.name=MessageAbortedError, not finish; see opencode
# packages/app/src/pages/session/message-timeline.data.ts. The completed-time
# and error-name predicates make reruns no-ops. Echoes rows touched.
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
  AND CASE WHEN json_valid(data) THEN json_extract(data, '\$.time.completed') IS NULL ELSE 0 END
  AND CASE WHEN json_valid(data) THEN json_extract(data, '\$.error.name') IS NOT 'MessageAbortedError' ELSE 0 END;
SELECT changes();
SQL
}

# Abandoned PTYs: opencode-pty keeps lifecycle state in memory, so a restart
# can kill a notifyOnExit PTY without the `<pty_exited>` message that resumes
# the agent. Until kfactory has a durable PTY ledger, mirror the transcript
# contract from plugins/ntfy/src/pty-lifecycle.ts; docs/spec.md owns the risk.
#
# v1-only for now. Single sqlite3 invocation because temp tables are scoped to
# one connection. Emits one workspace_id per abandoned PTY workspace.
heal_process_pty_v1() {
  "${SQLITE[@]}" "$DB" <<'SQL' || true
DROP TABLE IF EXISTS temp.abandoned_pty;
CREATE TEMP TABLE abandoned_pty AS
SELECT message_id, session_id, workspace_id, spawn_time, pty_id
FROM (
  SELECT
    p.message_id,
    p.session_id,
    s.workspace_id,
    p.time_created AS spawn_time,
    json_extract(p.data, '$.state.output') AS output,
    substr(
      json_extract(p.data, '$.state.output'),
      instr(json_extract(p.data, '$.state.output'), 'ID: pty_') + 4,
      12
    ) AS pty_id
  FROM part p
  JOIN message m ON p.message_id = m.id
  JOIN session s ON m.session_id = s.id
  WHERE CASE WHEN json_valid(p.data) THEN json_extract(p.data, '$.type') = 'tool' ELSE 0 END
    AND CASE WHEN json_valid(p.data) THEN json_extract(p.data, '$.tool') = 'pty_spawn' ELSE 0 END
    AND CASE WHEN json_valid(p.data) THEN json_extract(p.data, '$.state.input.notifyOnExit') = 1 ELSE 0 END
    AND s.workspace_id IS NOT NULL
    AND CASE WHEN json_valid(m.data) THEN json_extract(m.data, '$.error.name') IS NOT 'MessageAbortedError' ELSE 0 END
)
WHERE output IS NOT NULL
  AND instr(output, 'ID: pty_') > 0
  AND pty_id GLOB 'pty_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
  AND output LIKE '%<pty_spawned>' || char(10) || 'ID: ' || pty_id || char(10) || '%</pty_spawned>%';

DELETE FROM abandoned_pty WHERE rowid IN (
  SELECT a.rowid FROM abandoned_pty a
  WHERE EXISTS (
    SELECT 1 FROM part p2
    JOIN message m2 ON p2.message_id = m2.id
    WHERE p2.session_id = a.session_id
      AND p2.time_created > a.spawn_time
      AND CASE WHEN json_valid(p2.data) THEN json_extract(p2.data, '$.type') = 'text' ELSE 0 END
      AND CASE WHEN json_valid(p2.data) THEN json_extract(p2.data, '$.text') LIKE '%<pty_exited>' || char(10) || 'ID: ' || a.pty_id || char(10) || '%</pty_exited>%' ELSE 0 END
      AND CASE WHEN json_valid(m2.data) THEN json_extract(m2.data, '$.role') = 'user' ELSE 0 END
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
  affected_v1=$(heal_collect message "CASE WHEN json_valid(message.data) THEN json_extract(message.data, '\$.role') = 'assistant' ELSE 0 END")
  updated_v1=$(heal_update message "CASE WHEN json_valid(data) THEN json_extract(data, '\$.role') = 'assistant' ELSE 0 END")
  # Count non-empty PTY hits for operator-visible JSON; `grep -c` exits 1 on zero.
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

# Stable single-line JSON log for monitoring/scripted consumers.
heal_json=$(jq -nc \
  --argjson v1 "$updated_v1" \
  --argjson v2 "$updated_v2" \
  --argjson pty "$updated_pty_v1" \
  --argjson n "$affected_count" \
  '{v1_message: $v1, v2_session_message: $v2, abandoned_pty: $pty, affected_workspaces: $n}')
echo "opencode-heal: $heal_json"
