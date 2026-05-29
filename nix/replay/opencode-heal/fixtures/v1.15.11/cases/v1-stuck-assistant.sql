INSERT INTO session (id, workspace_id) VALUES ('ses_v1', 'wrk_v1');
INSERT INTO message (id, session_id, data) VALUES (
  'msg_v1_stuck',
  'ses_v1',
  json('{"role":"assistant","time":{"created":1000,"completed":null},"parts":[]}')
);
