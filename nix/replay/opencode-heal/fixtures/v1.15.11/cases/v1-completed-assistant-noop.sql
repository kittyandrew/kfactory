INSERT INTO session (id, workspace_id) VALUES ('ses_done', 'wrk_done');
INSERT INTO message (id, session_id, data) VALUES (
  'msg_done',
  'ses_done',
  json('{"role":"assistant","time":{"created":1000,"completed":2000},"parts":[]}')
);
