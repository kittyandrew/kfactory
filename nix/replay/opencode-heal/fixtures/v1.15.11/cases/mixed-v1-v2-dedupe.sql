INSERT INTO session (id, workspace_id) VALUES ('ses_mixed_v1', 'wrk_same'), ('ses_mixed_v2', 'wrk_same'), ('ses_mixed_other', 'wrk_other');
INSERT INTO message (id, session_id, data) VALUES ('msg_mixed_v1', 'ses_mixed_v1', json('{"role":"assistant","time":{"created":1000,"completed":null}}'));
INSERT INTO session_message (id, session_id, type, data) VALUES
  ('smsg_mixed_v2', 'ses_mixed_v2', 'assistant', json('{"time":{"created":1001,"completed":null}}')),
  ('smsg_mixed_other', 'ses_mixed_other', 'assistant', json('{"time":{"created":1002,"completed":null}}'));
