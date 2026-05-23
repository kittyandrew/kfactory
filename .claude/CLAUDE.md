# kfactory

Opencode factory deployment toolkit -- standalone CLI (`kfactory`),
opencode plugins (`kfactory-adapter` + `ntfy` + `loop`), and source
patches (opencode + oauth2-proxy) that together let you run opencode
behind an OIDC reverse proxy with one workspace per repo. Five
deliverables, one flake.

## Layout

```
cmd/kfactory/                Go CLI (package main, single binary)
completions/                 shell-completion scripts (zsh `_kfactory`)
plugins/kfactory-adapter/    opencode WorkspaceAdapter plugin (TS, env-driven)
plugins/ntfy/                ntfy.sh notification plugin (TS, vendored MIT subset)
plugins/loop/                /loop auto-continuation plugin (TS, slash command + tools)
plugins/opencode-pty/        third-party carrier (manifest-only): package.json +
                             package-lock.json pinning shekohex/opencode-pty.
                             Packaged through Nix via packages.opencode-pty; no
                             upstream source in our tree. See rule 050.
patches/                     opencode + oauth2-proxy source patches (line-pinned)
modules/                     NixOS modules: scheduled-tasks.nix (timer-driven
                             `kfactory tick`) + recovery.nix (opencode-serve
                             lifecycle: heal ExecStartPre + sync-kick & recovery-
                             sweep ExecStartPost). Exposed via flake.nix
                             `nixosModules = { scheduledTasks; recovery; };`
tests/regression/            Docker-based regression test environment + lifecycle
                             scripts (dev-up / dev-down / dev-clean / dev-test) +
                             plugin/auth configs the test images consume
docs/spec.md                 architecture intent + decisions log (portable; no kittyos refs)
flake.nix                    packages.kfactory + plugins.* + patches.* + checks.* + devShells.default
.github/workflows/           check.yml (single job: lint + flake check + attic push on default-branch push)
.claude/rules/                rules auto-loaded by Claude Code on every session
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
- `nix develop -c betterleaks dir . --no-banner --redact` -- secrets
  scan. Allowlist for regression-tests fake-token fixtures in
  `.betterleaks.toml` (prefilter on `tests/regression/configs/` +
  `regression-fake-*` pattern filter).
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

Before claiming work done: run `nix flake check`, `golangci-lint`,
`alejandra -c .`, and `betterleaks dir .` at minimum. CI runs all
of the above on every PR.

## Conventions

- License is AGPLv3. Keep this repo portable -- no kittyos / tustan /
  hostnames / personal paths anywhere in code, docs, or comments.
- No external arg parser; CLI is hand-rolled in `cmd/kfactory/main.go`.
  Switch over subcommands -- no top-level aliases like `ls` / `rm`.
- `kfactory tick <task-id|ref>` is the idempotent-dispatch verb. Two
  shapes: scheduled (config file at `/etc/kfactory/scheduled/<id>.json`
  drives behavior; ref IS the task id which becomes the workspace slug
  suffix) and ad-hoc (`--prompt TEXT` required; ref resolves a
  workspace and the prompt is appended as a new user message in the
  most-recent root session). The same verb services scheduled task
  fires (via `modules/scheduled-tasks.nix`) and VM-reboot recovery
  (via `modules/recovery.nix` -> recovery-sweep). The JSON config
  schema is owned by `cmd/kfactory/tick.go`; the NixOS module emits
  JSON the CLI accepts.
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
- Patches live under `patches/` (a stack of opencode + one oauth2-proxy).
  Stack identity is in `.claude/rules/020-patches.md`. Never hand-edit
  hunk headers; always use the re-diff workflow in
  `.claude/rules/021-patches-rediff.md`. Bumping the opencode pin:
  `.claude/rules/022-patches-bump.md`.
- Plugins live under `plugins/<name>/`. Two shapes share the parent
  directory:
  - **kfactory-owned** -- `src/`, `tsconfig.json`, `package.json`,
    lockfile. Source we maintain (own code or vendored MIT subsets).
    Editing rules in `.claude/rules/010-plugin.md`.
  - **third-party carriers** -- ONLY `package.json` + lockfile, no
    `src/`. Manifest pointing at an upstream npm package; the actual
    source comes from the registry at `buildNpmPackage` time.
    Editing rules in `.claude/rules/050-third-party-nix-plugins.md`.

  Both shapes read config from env vars with sensible defaults; no
  Nix substitution at build time.

## Upstream pin

`flake.nix` pins `inputs.opencode` to a specific tag because patches are
line-number-pinned to that source. Bumping is documented in
`.claude/rules/022-patches-bump.md`.
