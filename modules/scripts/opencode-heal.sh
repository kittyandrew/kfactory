# opencode-heal: sweep zombie assistant turns ("time.completed IS NULL"
# at last shutdown) + emit affected workspace IDs to the recovery queue
# file so `services.kfactory.recovery`'s recovery-sweep step ticks ONLY
# the workspaces with a mid-flight turn.
#
# Runs against TWO storage paths: opencode v1 (`message` table, role in
# JSON blob) and v2 (`session_message` table, role in `type` column).
# Whichever doesn't exist on a given DB is a silent no-op -- this keeps
# working as opencode flips between storage versions.
#
# Wiring: ExecStartPre on the opencode-serve unit via the recovery
# module. Tests exec this script directly inside the opencode container
# (no systemd in the e2e harness).
#
# Usage: opencode-heal <PATH-TO-DB>
# Env: KFACTORY_RECOVERY_QUEUE  (default /run/kfactory/recovery-queue.json)
#
# First-boot tolerant: if DB doesn't exist yet, writes empty queue + exits 0.

if [ $# -lt 1 ]; then
  echo "usage: opencode-heal <PATH-TO-DB>" >&2
  exit 2
fi
DB=$1
QUEUE_FILE=${KFACTORY_RECOVERY_QUEUE:-/run/kfactory/recovery-queue.json}

if [ ! -f "$DB" ]; then
  # First boot. Nothing to sweep. Write empty queue so downstream
  # consumers don't have to special-case absence.
  mkdir -p "$(dirname "$QUEUE_FILE")"
  echo '[]' >"$QUEUE_FILE"
  echo "opencode-heal: db-not-found ($DB); queue=empty"
  exit 0
fi

# `-cmd ".timeout 30000"` sets the busy timeout via the CLI rather
# than an in-SQL `PRAGMA busy_timeout=30000;` -- the PRAGMA echoes
# its new value as a result row in sqlite3's default output mode,
# which polluted heal_collect's workspace-id stream + heal_update's
# row-count integer (a regression caught when the e2e harness saw
# "30000" sneak into both outputs and the queue end up empty).
#
# Stored as an array so `.timeout 30000` stays one CLI arg under
# bash word-splitting (a string-form variable would split on the
# space + sqlite3 would parse "30000" as a positional database path).
SQLITE=(sqlite3 -cmd ".timeout 30000")

# Probe schema once per table; opencode flips between v1 (`message`
# JSON-role) and v2 (`session_message` typed-row) across versions. On
# a v2-only DB the v1 table simply doesn't exist (and vice versa on
# an old DB). The probes are inlined per table -- literal `name='...'`
# in the SQL (no shell interpolation), so the surface is closed
# against any future "what if a caller passes attacker-controlled
# input here" question.
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

# heal_collect <table> <role_predicate>
#   Emits one workspace_id per line for sessions whose <table> has a
#   stuck assistant row. Caller writes them to the recovery queue.
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

# heal_update <table> <role_predicate>
#   Marks stuck assistant rows finish='interrupted-by-restart' +
#   stamps time.completed=now. Echoes the row-count touched.
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

# Pre-update: collect workspace_ids whose sessions had a mid-flight
# assistant turn. We collect BEFORE the UPDATE because the UPDATE
# clears the `time.completed IS NULL` predicate we're filtering on.
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

# Merge + write the queue. printf with %s\n preserves the one-id-per-
# line format both queries return.
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
