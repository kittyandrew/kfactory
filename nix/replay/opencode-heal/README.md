# opencode-heal Fixtures

These tests replay small SQLite fixtures through the packaged
`opencode-heal` binary. The schema is derived from the pinned opencode
source, then minimized to the tables `opencode-heal` reads and mutates.

Use `generate-fixtures.sh` after an opencode bump to refresh
`fixtures/v1.15.11/schema.sql`, then review the diff as an upstream schema
contract change. Use `record-live-fixture.sh` to normalize rows from a
real opencode DB into deterministic fixture inserts.

The fixtures are not a replacement for the Docker recovery regression;
they make edge cases deterministic: v1/v2 stuck rows, queue dedupe,
malformed JSON tolerance, abandoned PTY anchoring, and idempotency.
