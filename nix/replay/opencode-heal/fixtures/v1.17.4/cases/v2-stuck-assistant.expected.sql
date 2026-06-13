SELECT 'v2 assistant not marked interrupted'
WHERE NOT EXISTS (
  SELECT 1 FROM session_message
  WHERE id = 'smsg_v2_stuck'
    AND json_extract(data, '$.finish') = 'interrupted-by-restart'
    AND json_extract(data, '$.error.name') = 'MessageAbortedError'
    AND json_extract(data, '$.time.completed') IS NOT NULL
);
