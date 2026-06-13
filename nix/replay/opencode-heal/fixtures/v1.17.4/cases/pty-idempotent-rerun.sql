INSERT INTO session (id, workspace_id) VALUES ('ses_pty_idem', 'wrk_pty_idem');
INSERT INTO message (id, session_id, data) VALUES ('msg_pty_idem', 'ses_pty_idem', json('{"role":"assistant","time":{"created":1000,"completed":2000}}'));
INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (
  'part_spawn_idem',
  'msg_pty_idem',
  'ses_pty_idem',
  1000,
  json('{"type":"tool","tool":"pty_spawn","state":{"input":{"notifyOnExit":true},"output":"<pty_spawned>\nID: pty_1234abcd\n</pty_spawned>\n"}}')
);
