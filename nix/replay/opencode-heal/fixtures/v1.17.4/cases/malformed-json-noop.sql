INSERT INTO session (id, workspace_id) VALUES ('ses_bad', 'wrk_bad');
INSERT INTO message (id, session_id, data) VALUES ('msg_bad', 'ses_bad', '{bad json');
INSERT INTO session_message (id, session_id, type, data) VALUES ('smsg_bad', 'ses_bad', 'assistant', '{bad json');
