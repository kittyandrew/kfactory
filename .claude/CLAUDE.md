# kfactory

Opencode factory deployment toolkit -- standalone CLI (`kfactory`), plugin
(`factory-adapter.ts`), and source patches (opencode + oauth2-proxy) that
together let you run opencode behind an OIDC reverse proxy with one
workspace per repo. Three deliverables, one flake.

## Layout

```
cmd/kfactory/         Go CLI (package main, single binary)
completions/          shell-completion scripts (zsh `_kfactory`)
plugin/               opencode WorkspaceAdapter plugin (TS, pkgs.replaceVars-substituted)
patches/              opencode + oauth2-proxy source patches (line-pinned)
docs/spec.md          architecture intent + decisions log (portable; no kittyos refs)
flake.nix             packages.kfactory + lib.mkFactoryAdapter + patches.* + checks.* + devShells.default
.github/workflows/    ci.yml (two-job: quality + cached build on default branch)
.claude/rules/        rules auto-loaded by Claude Code on every session
```

## Build & test

All linters/tools live in `devShells.default` -- CI uses the same versions
via `nix develop -c <cmd>`. To match CI locally, prefix with `nix develop -c`.

- `nix develop -c alejandra -c .` -- Nix format check.
- `nix develop -c deadnix .` -- Nix dead-code.
- `nix develop -c golangci-lint run --timeout 5m ./...` -- Go lint
  (govet + staticcheck + errcheck + ineffassign + unused; expect 0 issues).
- `nix develop -c gofmt -l cmd/` -- Go format (empty output = clean).
- `nix develop -c actionlint && nix develop -c zizmor .github/workflows`
  -- workflow lint + security audit.
- `nix flake check` -- builds every `packages.${system}.*` (registered
  as checks via `flake.nix`) plus the bespoke `factory-*` checks defined
  in the `checks` attrset. The authoritative list lives in `flake.nix`;
  query at runtime with
  `nix eval --json .#checks.x86_64-linux --apply 'attrs: builtins.attrNames attrs'`.
  Adding a new package or check automatically becomes a CI gate; no
  workflow edit needed.
- `nix build .#kfactory` -- builds the CLI binary. Defaults are empty;
  consumer `overrideAttrs` injects via `-ldflags -X` (see README).
- `nix build .#opencode-kfactory` / `.#oauth2-proxy-kfactory` -- patched
  upstream packages (convenience wrappers for consumers that don't need
  to stack their own patches).
- `go build ./cmd/kfactory` -- direct Go build outside Nix.

Before claiming work done: run `nix flake check`, `golangci-lint`, and
`alejandra -c .` at minimum. CI runs all of the above on every PR.

## Conventions

- License is AGPLv3. Keep this repo portable -- no kittyos / tustan /
  hostnames / personal paths anywhere in code, docs, or comments.
- No external arg parser; CLI is hand-rolled in `cmd/kfactory/main.go`.
  Switch over subcommands -- no top-level aliases like `ls` / `rm`.
- CLI endpoint defaults are EMPTY in source (`defaultServer`, `defaultIssuer`,
  `defaultClientID`, `defaultAudience` in `main.go`). Consumers bake values
  via `overrideAttrs` + `-ldflags -X main.<name>=...`; operators can also
  pass `--server` / `--issuer` / `--client-id` / `--audience` on first
  `kfactory auth login`. **Exception**: `defaultAudienceScopeTemplate`
  ships with the Zitadel URN `urn:zitadel:iam:org:project:id:%s:aud` as
  a default so existing Zitadel deployments keep working without
  ldflags. Non-Zitadel deployers override or empty-string it via
  `-X main.defaultAudienceScopeTemplate=...`.
- Token state: `$XDG_CONFIG_HOME/kfactory/auth.json` (mode 0600),
  cross-process refresh coordinated via POSIX `flock(2)` on
  `auth.json.lock`.
- Patches live under `patches/`. Never hand-edit hunk headers. Always
  use the re-diff workflow -- see `.claude/rules/020-patches.md`.
- Plugin lives under `plugin/`. Editing rules + the at-signed
  placeholder discipline -- see `.claude/rules/010-plugin.md`.

## Upstream pin

`flake.nix` pins `inputs.opencode` to a specific tag because patches are
line-number-pinned to that source. Bumping is documented in
`.claude/rules/020-patches.md`.
