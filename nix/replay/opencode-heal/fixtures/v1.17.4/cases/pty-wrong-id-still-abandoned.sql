INSERT INTO session (id, workspace_id) VALUES ('ses_pty_wrong', 'wrk_pty_wrong');
INSERT INTO message (id, session_id, data) VALUES
  ('msg_pty_wrong_spawn', 'ses_pty_wrong', json('{"role":"assistant","time":{"created":1000,"completed":2000}}')),
  ('msg_pty_wrong_user', 'ses_pty_wrong', json('{"role":"user","time":{"created":3000,"completed":3000}}'));
INSERT INTO part (id, message_id, session_id, time_created, data) VALUES
  ('part_spawn_wrong', 'msg_pty_wrong_spawn', 'ses_pty_wrong', 1000, json('{"type":"tool","tool":"pty_spawn","state":{"input":{"notifyOnExit":true},"output":"<pty_spawned>\nID: pty_aaaaaaaa\n</pty_spawned>\n"}}')),
  ('part_user_wrong', 'msg_pty_wrong_user', 'ses_pty_wrong', 3000, json('{"type":"text","text":"<pty_exited>\nID: pty_bbbbbbbb\n</pty_exited>"}'));
