-- Generated/minimized from anomalyco/opencode v1.15.11 (d2bd7eaad54bf39de04bf6e279d5953bd1666574).
-- Source migrations:
--   packages/opencode/migration/20260127222353_familiar_lady_ursula/migration.sql
--   packages/opencode/migration/20260227213759_add_session_workspace_id/migration.sql
--   packages/opencode/migration/20260427172553_slow_nightmare/migration.sql
PRAGMA foreign_keys = ON;

CREATE TABLE session (
  id TEXT PRIMARY KEY,
  workspace_id TEXT
);

CREATE TABLE message (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  data TEXT NOT NULL,
  FOREIGN KEY (session_id) REFERENCES session(id)
);

CREATE TABLE part (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  time_created INTEGER NOT NULL,
  data TEXT NOT NULL,
  FOREIGN KEY (message_id) REFERENCES message(id),
  FOREIGN KEY (session_id) REFERENCES session(id)
);

CREATE TABLE session_message (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  type TEXT NOT NULL,
  data TEXT NOT NULL,
  FOREIGN KEY (session_id) REFERENCES session(id)
);
