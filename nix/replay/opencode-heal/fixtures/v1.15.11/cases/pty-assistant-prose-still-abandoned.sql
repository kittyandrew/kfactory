INSERT INTO session (id, workspace_id) VALUES ('ses_pty_assistant', 'wrk_pty_assistant');
INSERT INTO message (id, session_id, data) VALUES
  ('msg_pty_assistant_spawn', 'ses_pty_assistant', json('{"role":"assistant","time":{"created":1000,"completed":2000}}')),
  ('msg_pty_assistant_prose', 'ses_pty_assistant', json('{"role":"assistant","time":{"created":3000,"completed":3000}}'));
INSERT INTO part (id, message_id, session_id, time_created, data) VALUES
  ('part_spawn_assistant', 'msg_pty_assistant_spawn', 'ses_pty_assistant', 1000, json('{"type":"tool","tool":"pty_spawn","state":{"input":{"notifyOnExit":true},"output":"<pty_spawned>\nID: pty_1234abcd\n</pty_spawned>\n"}}')),
  ('part_assistant_prose', 'msg_pty_assistant_prose', 'ses_pty_assistant', 3000, json('{"type":"text","text":"The literal block <pty_exited>\nID: pty_1234abcd\n</pty_exited> is documentation, not a plugin wakeup."}'));
