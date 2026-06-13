SELECT 'v1 assistant not marked interrupted'
WHERE NOT EXISTS (
  SELECT 1 FROM message
  WHERE id = 'msg_v1_stuck'
    AND json_extract(data, '$.finish') = 'interrupted-by-restart'
    AND json_extract(data, '$.error.name') = 'MessageAbortedError'
    AND json_extract(data, '$.time.completed') IS NOT NULL
);
