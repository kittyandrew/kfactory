INSERT INTO session (id, workspace_id) VALUES ('ses_pty_invalid_id', 'wrk_pty_invalid_id');
INSERT INTO message (id, session_id, data) VALUES ('msg_pty_invalid_id', 'ses_pty_invalid_id', json('{"role":"assistant","time":{"created":1000,"completed":2000}}'));
INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (
  'part_spawn_invalid_id',
  'msg_pty_invalid_id',
  'ses_pty_invalid_id',
  1000,
  json('{"type":"tool","tool":"pty_spawn","state":{"input":{"notifyOnExit":true},"output":"<pty_spawned>\nID: pty_nothexzz\nNotifyOnExit: true\n</pty_spawned>\n"}}')
);
