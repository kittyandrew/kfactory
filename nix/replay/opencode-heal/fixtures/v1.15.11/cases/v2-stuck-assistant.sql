INSERT INTO session (id, workspace_id) VALUES ('ses_v2', 'wrk_v2');
INSERT INTO session_message (id, session_id, type, data) VALUES (
  'smsg_v2_stuck',
  'ses_v2',
  'assistant',
  json('{"time":{"created":1000,"completed":null},"parts":[]}')
);
