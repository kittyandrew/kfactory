# Testing fixtures
<!-- .claude/rules/060-testing-fixtures.md -- recorded fixtures, real runtimes, fakes -->

When adding durable tests for opencode internals, prefer:

1. **Real runtime first** when the pinned unified runtime can exercise the
   behavior: TUI boot, workspace creation, sync/start, session routing.
2. **Recorded fixtures second** for expensive or timing-sensitive states:
   crash-mid-stream, abandoned PTY, DB migration drift. Derive from the
   pinned schema/DB and replay deterministically.
3. **Protocol fakes only at boundaries** outside repo ownership or unsuitable
   for Nix checks. Do not fake in-repo executables or opencode itself when a
   real isolated runtime is practical; capture proxies are fine when they only
   observe or route traffic.

Recorded fixture rules:

- Check in the recorder/generator next to the fixtures. A fixture must be
  regenerable from checked-in scripts plus pinned source/schema context.
- Fixtures must cite the source they were derived from: pinned opencode
  version, migration path, or live DB recorder script.
- Normalize IDs, timestamps, paths, and secrets. Keep only rows/columns
  the contract needs.
- Replay tests must run the packaged binary or script under test, not a
  copied implementation. For heal, use the internal flake check wiring so PATH
  and runtime inputs are covered.
- If recorded fixture replay fails after an upstream bump, treat it as
  drift signal. Regenerate fixtures only after deciding whether behavior
  should change.

TUI test rules:

- Use a real PTY (`script`/equivalent) and real `opencode attach`.
- Prefer server-observed request/state assertions over full terminal
  snapshots. Only assert tiny stable output strings when the UI text is
  the actual contract.
- For auth refresh, use real `kfactory auth refresh`. If OIDC is involved,
  use a real isolated IdP service in a NixOS VM/integration check rather
  than a fake token endpoint.
