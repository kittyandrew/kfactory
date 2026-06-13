INSERT INTO session (id, workspace_id) VALUES ('ses_user', 'wrk_user');
INSERT INTO message (id, session_id, data) VALUES (
  'msg_user_stuck',
  'ses_user',
  json('{"role":"user","time":{"created":1000,"completed":null},"parts":[]}')
);
