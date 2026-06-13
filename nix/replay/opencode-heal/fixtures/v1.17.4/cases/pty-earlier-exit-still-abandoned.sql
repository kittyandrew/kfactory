INSERT INTO session (id, workspace_id) VALUES ('ses_pty_early', 'wrk_pty_early');
INSERT INTO message (id, session_id, data) VALUES
  ('msg_pty_early_user', 'ses_pty_early', json('{"role":"user","time":{"created":500,"completed":500}}')),
  ('msg_pty_early_spawn', 'ses_pty_early', json('{"role":"assistant","time":{"created":1000,"completed":2000}}'));
INSERT INTO part (id, message_id, session_id, time_created, data) VALUES
  ('part_user_early', 'msg_pty_early_user', 'ses_pty_early', 500, json('{"type":"text","text":"<pty_exited>\nID: pty_1234abcd\n</pty_exited>"}')),
  ('part_spawn_early', 'msg_pty_early_spawn', 'ses_pty_early', 1000, json('{"type":"tool","tool":"pty_spawn","state":{"input":{"notifyOnExit":true},"output":"<pty_spawned>\nID: pty_1234abcd\n</pty_spawned>\n"}}'));
