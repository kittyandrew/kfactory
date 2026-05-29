INSERT INTO session (id, workspace_id) VALUES ('ses_pty_user_prose', 'wrk_pty_user_prose');
INSERT INTO message (id, session_id, data) VALUES
  ('msg_pty_user_prose_spawn', 'ses_pty_user_prose', json('{"role":"assistant","time":{"created":1000,"completed":2000}}')),
  ('msg_pty_user_prose', 'ses_pty_user_prose', json('{"role":"user","time":{"created":3000,"completed":3000}}'));
INSERT INTO part (id, message_id, session_id, time_created, data) VALUES
  ('part_spawn_user_prose', 'msg_pty_user_prose_spawn', 'ses_pty_user_prose', 1000, json('{"type":"tool","tool":"pty_spawn","state":{"input":{"notifyOnExit":true},"output":"<pty_spawned>\nID: pty_1234abcd\n</pty_spawned>\n"}}')),
  ('part_user_prose', 'msg_pty_user_prose', 'ses_pty_user_prose', 3000, json('{"type":"text","text":"The operator mentioned <pty_exited> ID: pty_1234abcd </pty_exited> inline; this is prose, not a lifecycle block."}'));
