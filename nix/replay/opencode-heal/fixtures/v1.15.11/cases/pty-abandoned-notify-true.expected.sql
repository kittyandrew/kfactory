SELECT 'abandoned pty message not marked interrupted'
WHERE NOT EXISTS (
  SELECT 1 FROM message
  WHERE id = 'msg_pty'
    AND json_extract(data, '$.error.name') = 'MessageAbortedError'
);
