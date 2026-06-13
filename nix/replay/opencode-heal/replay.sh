#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FIXTURES="$SCRIPT_DIR/fixtures/v1.17.4"
SCHEMA="$FIXTURES/schema.sql"
: "${OPENCODE_HEAL:=opencode-heal}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dump_case() {
  local name=$1 db=$2 queue=$3 log=$4
  echo "--- $name log ---" >&2
  [ -f "$log" ] && cat "$log" >&2 || true
  echo "--- $name queue ---" >&2
  [ -f "$queue" ] && cat "$queue" >&2 || true
  if [ -f "$db" ]; then
    echo "--- $name message rows ---" >&2
    sqlite3 "$db" "SELECT id, session_id, data FROM message ORDER BY id;" >&2 || true
    echo "--- $name session_message rows ---" >&2
    sqlite3 "$db" "SELECT id, session_id, type, data FROM session_message ORDER BY id;" >&2 || true
    echo "--- $name part rows ---" >&2
    sqlite3 "$db" "SELECT id, message_id, session_id, time_created, data FROM part ORDER BY id;" >&2 || true
  fi
}

json_eq() {
  local label=$1 actual=$2 expected=$3
  local actual_norm expected_norm
  actual_norm=$(mktemp "$tmp/actual.XXXXXX")
  expected_norm=$(mktemp "$tmp/expected.XXXXXX")
  jq -S . "$actual" >"$actual_norm"
  jq -S . "$expected" >"$expected_norm"
  if ! diff -u "$expected_norm" "$actual_norm" >&2; then
    echo "$label mismatch" >&2
    return 1
  fi
}

expected_field() {
  local expected=$1 field=$2 out=$3
  jq -S "$field" "$expected" >"$out"
}

parsed_log() {
  local log=$1 out=$2
  grep '^opencode-heal: {' "$log" | tail -n 1 | sed 's/^opencode-heal: //' | jq -S . >"$out"
}

run_once() {
  local queue=$1 log=$2 db=$3
  KFACTORY_RECOVERY_QUEUE="$queue" "$OPENCODE_HEAL" "$db" >"$log"
}

check_expected() {
  local name=$1 db=$2 queue=$3 log=$4 expected=$5 prefix=$6
  local actual_queue expected_queue actual_log expected_log assertions
  actual_queue="$tmp/$name.$prefix.queue.actual.json"
  expected_queue="$tmp/$name.$prefix.queue.expected.json"
  actual_log="$tmp/$name.$prefix.log.actual.json"
  expected_log="$tmp/$name.$prefix.log.expected.json"
  local queue_field log_field
  if [ "$prefix" = "second" ]; then
    queue_field=".secondQueue"
    log_field=".secondLog"
  else
    queue_field=".queue"
    log_field=".log"
  fi
  jq -S . "$queue" >"$actual_queue"
  expected_field "$expected" "$queue_field" "$expected_queue"
  json_eq "$name $prefix queue" "$actual_queue" "$expected_queue"

  parsed_log "$log" "$actual_log"
  expected_field "$expected" "$log_field" "$expected_log"
  json_eq "$name $prefix log" "$actual_log" "$expected_log"

  assertions="$FIXTURES/cases/$name.expected.sql"
  if [ -f "$assertions" ] && [ "$prefix" = "" ]; then
    local failures
    failures=$(sqlite3 "$db" <"$assertions")
    if [ -n "$failures" ]; then
      echo "$name SQL assertions failed:" >&2
      printf '%s\n' "$failures" >&2
      return 1
    fi
  fi
}

run_missing_db() {
  local name=missing-db
  local expected="$FIXTURES/cases/$name.expected.json"
  local dir="$tmp/$name" db="$tmp/$name/missing.db" queue="$tmp/$name/queue.json" log="$tmp/$name/heal.log"
  mkdir -p "$dir"
  if ! run_once "$queue" "$log" "$db"; then
    dump_case "$name" "$db" "$queue" "$log"
    exit 1
  fi
  local actual_queue expected_queue
  actual_queue="$tmp/$name.queue.actual.json"
  expected_queue="$tmp/$name.queue.expected.json"
  jq -S . "$queue" >"$actual_queue"
  expected_field "$expected" ".queue" "$expected_queue"
  json_eq "$name queue" "$actual_queue" "$expected_queue" || {
    dump_case "$name" "$db" "$queue" "$log"
    exit 1
  }
  local want
  want=$(jq -r '.logSubstring' "$expected")
  if ! grep -Fq "$want" "$log"; then
    echo "$name log missing substring $want" >&2
    dump_case "$name" "$db" "$queue" "$log"
    exit 1
  fi
  echo "✓ $name"
}

run_case() {
  local name=$1
  local case_sql="$FIXTURES/cases/$name.sql"
  local expected="$FIXTURES/cases/$name.expected.json"
  local dir="$tmp/$name" db="$tmp/$name/opencode.db" queue="$tmp/$name/queue.json" log="$tmp/$name/heal.log"
  mkdir -p "$dir"
  sqlite3 "$db" <"$SCHEMA"
  sqlite3 "$db" <"$case_sql"
  if ! run_once "$queue" "$log" "$db"; then
    dump_case "$name" "$db" "$queue" "$log"
    exit 1
  fi
  if ! check_expected "$name" "$db" "$queue" "$log" "$expected" ""; then
    dump_case "$name" "$db" "$queue" "$log"
    exit 1
  fi
  if jq -e 'has("secondQueue") or has("secondLog")' "$expected" >/dev/null; then
    local second_queue="$tmp/$name/queue.second.json" second_log="$tmp/$name/heal.second.log"
    if ! run_once "$second_queue" "$second_log" "$db"; then
      dump_case "$name second" "$db" "$second_queue" "$second_log"
      exit 1
    fi
    if ! check_expected "$name" "$db" "$second_queue" "$second_log" "$expected" "second"; then
      dump_case "$name second" "$db" "$second_queue" "$second_log"
      exit 1
    fi
  fi
  echo "✓ $name"
}

run_missing_db
for expected in "$FIXTURES"/cases/*.expected.json; do
  name=$(basename "$expected" .expected.json)
  [ "$name" = "missing-db" ] && continue
  run_case "$name"
done
