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

# Marks stuck rows finish='interrupted-by-restart' + time.completed=now;
# echoes row-count touched.
heal_update() {
  local table=$1 role_predicate=$2
  "${SQLITE[@]}" "$DB" <<SQL
UPDATE $table
SET data = json_set(
  json_set(data, '\$.time.completed', cast(strftime('%s','now') as integer) * 1000),
  '\$.finish', 'interrupted-by-restart'
)
WHERE $role_predicate
  AND json_extract(data, '\$.time.completed') IS NULL;
SELECT changes();
SQL
}

# Collect BEFORE update: the update clears the `time.completed IS NULL`
# predicate we're filtering on.
affected_v1=""
affected_v2=""
updated_v1=0
updated_v2=0

if v1_exists; then
  affected_v1=$(heal_collect message "json_extract(message.data, '\$.role') = 'assistant'")
  updated_v1=$(heal_update message "json_extract(data, '\$.role') = 'assistant'")
fi

if v2_exists; then
  affected_v2=$(heal_collect session_message "session_message.type = 'assistant'")
  updated_v2=$(heal_update session_message "type = 'assistant'")
fi

# Merge v1 + v2 outputs (one id per line) and dedupe.
mkdir -p "$(dirname "$QUEUE_FILE")"
ids=$(printf '%s\n%s\n' "$affected_v1" "$affected_v2" |
  grep -v '^$' |
  sort -u || true)
if [ -z "$ids" ]; then
  echo '[]' >"$QUEUE_FILE"
  affected_count=0
else
  printf '%s\n' "$ids" | jq -R . | jq -s . >"$QUEUE_FILE"
  affected_count=$(printf '%s\n' "$ids" | wc -l)
fi

echo "opencode-heal: v1.message=$updated_v1 v2.session_message=$updated_v2 affected_workspaces=$affected_count"
