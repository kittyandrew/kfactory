INSERT INTO session (id, workspace_id) VALUES ('ses_pty_exit', 'wrk_pty_exit');
INSERT INTO message (id, session_id, data) VALUES
  ('msg_pty_exit_spawn', 'ses_pty_exit', json('{"role":"assistant","time":{"created":1000,"completed":2000}}')),
  ('msg_pty_exit_user', 'ses_pty_exit', json('{"role":"user","time":{"created":3000,"completed":3000}}'));
INSERT INTO part (id, message_id, session_id, time_created, data) VALUES
  ('part_spawn_exit', 'msg_pty_exit_spawn', 'ses_pty_exit', 1000, json('{"type":"tool","tool":"pty_spawn","state":{"input":{"notifyOnExit":true},"output":"<pty_spawned>\nID: pty_1234abcd\n</pty_spawned>\n"}}')),
  ('part_user_exit', 'msg_pty_exit_user', 'ses_pty_exit', 3000, json('{"type":"text","text":"<pty_exited>\nID: pty_1234abcd\nExitCode: 0\n</pty_exited>"}'));
