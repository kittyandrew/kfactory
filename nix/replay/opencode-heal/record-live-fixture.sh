#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: record-live-fixture.sh <opencode.db> <workspace-id>" >&2
  exit 2
fi

db=$1
workspace=$2

if [ ! -f "$db" ]; then
  echo "db not found: $db" >&2
  exit 1
fi

sqlite3 -json "$db" <<SQL | jq -r --arg workspace "$workspace" '
  def q: @json;
  .[] as $row |
  if $row.kind == "session" then
    "INSERT INTO session (id, workspace_id) VALUES (" + ($row.id|q) + ", " + ($row.workspace_id|q) + ");"
  elif $row.kind == "message" then
    "INSERT INTO message (id, session_id, data) VALUES (" + ($row.id|q) + ", " + ($row.session_id|q) + ", json(" + ($row.data|q) + "));"
  elif $row.kind == "part" then
    "INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (" + ($row.id|q) + ", " + ($row.message_id|q) + ", " + ($row.session_id|q) + ", " + ($row.time_created|tostring) + ", json(" + ($row.data|q) + "));"
  elif $row.kind == "session_message" then
    "INSERT INTO session_message (id, session_id, type, data) VALUES (" + ($row.id|q) + ", " + ($row.session_id|q) + ", " + ($row.type|q) + ", json(" + ($row.data|q) + "));"
  else empty end
'
SELECT 'session' AS kind, id, workspace_id, NULL AS session_id, NULL AS message_id, NULL AS time_created, NULL AS type, NULL AS data
  FROM session WHERE workspace_id = '$workspace'
UNION ALL
SELECT 'message' AS kind, message.id, NULL, message.session_id, NULL, NULL, NULL, message.data
  FROM message JOIN session ON message.session_id = session.id WHERE session.workspace_id = '$workspace'
UNION ALL
SELECT 'part' AS kind, part.id, NULL, part.session_id, part.message_id, part.time_created, NULL, part.data
  FROM part JOIN session ON part.session_id = session.id WHERE session.workspace_id = '$workspace'
UNION ALL
SELECT 'session_message' AS kind, session_message.id, NULL, session_message.session_id, NULL, NULL, session_message.type, session_message.data
  FROM session_message JOIN session ON session_message.session_id = session.id WHERE session.workspace_id = '$workspace'
ORDER BY kind, id;
SQL
