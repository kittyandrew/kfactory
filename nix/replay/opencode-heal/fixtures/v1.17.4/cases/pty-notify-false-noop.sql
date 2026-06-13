INSERT INTO session (id, workspace_id) VALUES ('ses_pty_false', 'wrk_pty_false');
INSERT INTO message (id, session_id, data) VALUES ('msg_pty_false', 'ses_pty_false', json('{"role":"assistant","time":{"created":1000,"completed":2000}}'));
INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (
  'part_spawn_false',
  'msg_pty_false',
  'ses_pty_false',
  1000,
  json('{"type":"tool","tool":"pty_spawn","state":{"input":{"notifyOnExit":false},"output":"<pty_spawned>\nID: pty_1234abcd\n</pty_spawned>\n"}}')
);
