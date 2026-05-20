# Rules
<!-- .claude/rules/000-meta.md -- rule conventions for kfactory -->

All `.md` files under `.claude/rules/` are auto-loaded into every Claude
Code session in this repo. Each file is a directive set for one
narrow concern (plugin editing, patch re-diff workflow, ...). Style:

- One H1 title, one HTML comment with `<!-- path -- keywords -->`.
- Stay under 100 lines per rule. Split if growing.
- Reference code by path (e.g., `cmd/kfactory/auth.go`) not by line
  number -- line numbers go stale silently.
- Detailed "why" lives in `docs/spec.md`; rules are the "what / how".
