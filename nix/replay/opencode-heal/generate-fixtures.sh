#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: generate-fixtures.sh <opencode-source>" >&2
  exit 2
fi

src=$1
fixture_version=v1.17.4
cat <<'SQL'
-- Regenerate by reviewing the pinned opencode migrations listed below and
-- keeping only the table/column surface consumed by opencode-heal.
-- Source migrations:
--   packages/core/migration/20260127222353_familiar_lady_ursula/migration.sql
--   packages/core/migration/20260227213759_add_session_workspace_id/migration.sql
--   packages/core/migration/20260427172553_slow_nightmare/migration.sql
SQL

for path in \
  packages/core/migration/20260127222353_familiar_lady_ursula/migration.sql \
  packages/core/migration/20260227213759_add_session_workspace_id/migration.sql \
  packages/core/migration/20260427172553_slow_nightmare/migration.sql
do
  if [ ! -f "$src/$path" ]; then
    echo "missing expected opencode migration: $path" >&2
    exit 1
  fi
done

cat "$(dirname "${BASH_SOURCE[0]}")/fixtures/$fixture_version/schema.sql"
