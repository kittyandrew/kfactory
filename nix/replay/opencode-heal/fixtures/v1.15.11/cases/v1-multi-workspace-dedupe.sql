INSERT INTO session (id, workspace_id) VALUES ('ses_a1', 'wrk_a'), ('ses_a2', 'wrk_a'), ('ses_b', 'wrk_b');
INSERT INTO message (id, session_id, data) VALUES
  ('msg_a1', 'ses_a1', json('{"role":"assistant","time":{"created":1000,"completed":null}}')),
  ('msg_a2', 'ses_a2', json('{"role":"assistant","time":{"created":1001,"completed":null}}')),
  ('msg_b', 'ses_b', json('{"role":"assistant","time":{"created":1002,"completed":null}}'));
