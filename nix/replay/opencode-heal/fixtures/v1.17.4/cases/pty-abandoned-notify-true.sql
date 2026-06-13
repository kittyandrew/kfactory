INSERT INTO session (id, workspace_id) VALUES ('ses_pty', 'wrk_pty');
INSERT INTO message (id, session_id, data) VALUES ('msg_pty', 'ses_pty', json('{"role":"assistant","time":{"created":1000,"completed":2000}}'));
INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (
  'part_spawn',
  'msg_pty',
  'ses_pty',
  1000,
  json('{"type":"tool","tool":"pty_spawn","state":{"input":{"notifyOnExit":true},"output":"<pty_spawned>\nID: pty_1234abcd\nNotifyOnExit: true\n</pty_spawned>\n"}}')
);
