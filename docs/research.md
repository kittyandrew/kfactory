# kfactory research ledger

This ledger compresses the durable conclusions from the 2026-05 opencode bump,
workspace-strategy, upstream-offload, local-hardening, and PTY-packaging research.
Verbose worklogs are intentionally not the primary reader surface; load-bearing
product decisions live in `docs/spec.md`.

## Source baseline

- Upstream opencode reference: `v1.15.11`, rev `d2bd7eaad54bf39de04bf6e279d5953bd1666574`.
- kfactory bump moved from `v1.15.9` to `v1.15.11`.
- Research used throwaway local checkouts of pinned opencode and JosXa
  opencode-pty sources; durable conclusions are below.

## Upstream `v1.15.11` bump facts

- Release range audited: `v1.15.9..v1.15.11`.
- High-risk kfactory drift areas were TUI lifecycle, project/workspace identity, HTTP API optional bodies, provider config/types, plugin lifecycle, task tool status semantics, and Nix fixed-output dependency churn.
- Project identity changed around remote-backed project IDs and cached project identity preservation. kfactory must keep workspace-specific behavior keyed on `workspace_id`, not `project_id`.
- Provider config gained `options.headerTimeout`; OpenAI defaults it to `10000` ms. Model `modalities.input` and `modalities.output` became independently optional.
- LLM/OpenAI Responses behavior changed around encrypted reasoning: use `include: ["reasoning.encrypted_content"]`; GPT-5 Responses defaults request encrypted reasoning; split reasoning summaries stream as separate blocks and fold for continuation.
- Runtime flags changed so `OPENCODE_EXPERIMENTAL_NATIVE_LLM` is separate from umbrella `OPENCODE_EXPERIMENTAL`, and experimental flags can override the umbrella.
- Plugin API gained a `dispose` hook. Local plugins now implement or account for teardown where needed.
- Dynamic MCP disconnects, user-info fallback, Google tool-calling regressions, orphaned interrupted tools, and shell timeout disclosure had upstream bugfixes that affected nearby tests or baselines.
- `task_status` expectations are stale after upstream background-agent changes. Do not mention or test for it.
- Fixed-output hashes after bump: opencode narHash `sha256-SIRE+x1YCSAX1L89237RN9owJkC4hgCIy1Q93Iy9GzM=`, opencode `node_modules` hash `sha256-FT8N4SBP7OmVu73OwNyPJvBoxFd2+IXzNnFubB8y6J0=`.

## Workspace strategy conclusions

- opencode already has the right primitives: `InstanceStore.provide({directory})`, local `WorkspaceAdapter.target`, workspace routing middleware, workspace IDs on sessions, routed `/vcs`, routed `/vcs/status`, sync/replay/steal/warp control-plane APIs, and caller-provided workspace IDs.
- kfactory should stay thin: one `opencode serve`, a clone-producing adapter, reverse-proxy auth, and CLI/operator workflows.
- Durable partition key is `WorkspaceTable.id` and `SessionTable.workspace_id`. `project_id` remains useful for project-wide views but is unsafe as the kfactory workspace partition.
- `opencode attach --workspace` remains local because upstream SDK supports `experimental_workspaceID`, but attach/TUI do not expose or seed it.
- Non-GET workspace routing remains local because the SDK emits `x-opencode-workspace` for non-GET while the upstream server reads only query workspace selectors.
- Workspace-scoped legacy `/session` and `/experimental/session` remain local because upstream still filters by `project_id` first or ignores accepted workspace query fields.
- `/sync/start?workspace=` remains local because upstream accepts the query shape but starts sync by project ID only.
- Plugin adapter global registration/fallback remains local because upstream documents global adapter registration but plugin registration and lookup do not make it visible across routed projects.
- Scheduled idempotency belongs in kfactory: send stable `id = "wrk_kfactory_<task-id>"` to upstream create. Do not revive `extra.slugSuffix` coalescing or opencode-core create policy patches.
- Branch and dirty display belong in kfactory: call upstream `/vcs?workspace=<id>` and `/vcs/status?workspace=<id>`. Empty status array is clean; non-empty is dirty; request errors skip/fail according to command semantics.
- Bearer attach is client/proxy plumbing. Do not claim opencode server validates Bearer.

## Patch stack status

- Current opencode patch stack is split by ownership: `opencode-bun-version-relax.patch`, `opencode-static-bearer.patch`, `opencode-workspace-routing.patch`, `opencode-kfactory-refresh.patch`.
- `opencode-bun-version-relax.patch` is temporary packaging relief until nixpkgs Bun satisfies upstream `packageManager: "bun@1.3.14"`. A self-expiring check fails once the relaxation is no longer needed.
- `opencode-static-bearer.patch` adds generic Bearer client emission via flag/env. It is optional deployment plumbing while reverse-proxy JWT attach is required.
- `opencode-workspace-routing.patch` is the upstreamable correctness set: attach workspace propagation, strict query/header selector handling, workspace-primary session listing, workspace-filtered `/experimental/session`, workspace-targeted `/sync/start`, global plugin adapter registration/fallback, failed-create rollback, and remove cleanup-before-metadata deletion.
- `opencode-kfactory-refresh.patch` is kfactory-specific deployment glue: shared auth cache schema, cache-file Bearer read, subprocess `kfactory auth refresh`, fetch wrapper, and refresh-failure toasts.
- Patch application is exact: `factory-opencode-patch-applies` uses no fuzz/offset tolerance.
- Branch/dirty list enrichment and scheduled slugSuffix/idempotency patches were deleted because kfactory can use upstream APIs and caller-provided workspace IDs directly.

## Upstream PR order

- Workspace selector parity and invalid selector behavior for query plus `x-opencode-workspace`.
- `opencode attach --workspace` with TUI SDK/project seeding and validation path propagation.
- Workspace-primary session listing, including `/experimental/session?workspace=`.
- Workspace-targeted `/sync/start` for restart/status recovery.
- Global plugin workspace adapter registration/fallback with project-specific override.
- Workspace create/remove atomicity around adapter resources.
- Generic create idempotency only if upstream wants raw API idempotency as a product contract.

## Local hardening results

- Scheduled create fails closed on create errors and only caller-provided stable workspace IDs provide idempotency.
- Scheduled first-run proof now gates existing-workspace modes via canonical opencode state: the root session must contain `initial_prompt`. The lock file is mutex-only; missing first-run state is repaired by sending `initial_prompt` instead of applying continuation modes to a partial first run.
- Scheduled config parsing rejects trailing JSON, whitespace-only repo/initial prompt, and whitespace-padded mode.
- Auth writers are serialized through the same file lock for login, refresh, save, and logout.
- Go auth cache loading and TS readers both fail closed on malformed schema/token/expiry/endpoint state.
- `kfactory-adapter` treats directory as a witness, verifies slug owner/repo against `repoUrl`, rejects lossy segments, requires absolute workspaces root, and clones into a temp dir before final rename.
- `ntfy` has strict config/event decoding, dispose cleanup for delayed notifications, upstream VCS usage, `session.status` idle handling, PTY unknown-state suppression with warnings, and property tests.
- `loop` captures the owning root session at start, rejects child/subagent starts, strict-validates durable state, ignores deprecated `session.idle`, checks status on init, uses a run ID to prevent stale writes, and stops after consecutive prompt failures.
- The PTY transcript bridge is stricter but still temporary: exact newline-delimited `<pty_spawned>` and `<pty_exited>` records, `pty_` + 8 lowercase hex IDs, per-ID matching, prose ignored.

## PTY replacement and packaging

- Current carrier pins `@josxa/opencode-pty@0.7.1`.
- Core tools preserved: `pty_spawn`, `pty_write`, `pty_read`, `pty_list`, `pty_kill`.
- JosXa adds snapshot tools plus Web UI/WebSocket support.
- Contract differences: `timeoutSeconds` support is gone; `pty_list` no longer reports timeout fields; `notifyOnExit` originally aborted the parent session for processes exiting within two seconds.
- Source-confirmed abort path: `pty_spawn` records `parentSessionId` and `notifyOnExit`; on exit, `NotificationManager.sendExitNotification` calls `client.session.abort` when elapsed time is `<= 2000` ms and no snapshot waiter exists; opencode abort cancels active runner work if the parent session is busy.
- Packaged artifact patches `isQuickInterrupt()` to return `false`. The risk is timing-dependent but real; elapsed time alone is not an interrupt signal.
- Carrier lockfile hash after replacement: `sha256-cO5SFt3hJdNmLiGZ3EJeFOAFT6BVQai4cLAFWJ/ICYg=`.
- `mkThirdPartyPlugin` accepts `packageName ? name`; opencode-pty is packaged internally while npm package is scoped.
- `packages.kfactory` sets a default generated `OPENCODE_CONFIG` containing all bundled plugin store paths and slash-command templates. Operators overriding `OPENCODE_CONFIG` must list desired bundled plugins themselves.
- Do not remove transcript parsing until a kfactory-owned PTY bridge writes durable lifecycle records and heal/ntfy consume them in tests.

## Testing and verification policy

- `nix flake check --max-jobs 1 --print-build-logs` is the durable gate.
- CI timeout budget: `quality` 20 minutes plus `cache` 10 minutes maximum.
- Testing methodology directories under `./nix/` are catalog slugs plus `shared`; no `nix/e2e/`.
- Real TUI checks use PTY-backed process coverage and server-observed request behavior as the oracle.
- Real OIDC refresh behavior belongs to the Keycloak VM check. Do not fake `kfactory auth refresh` or OIDC endpoints for expired-token refresh coverage.
- Patch ownership splits require semantic contract tests first, then patch re-diffing.
- Docker behavioral assertions moved toward the Go regression runner; shell remains lifecycle glue.
- Regression output should be inline/actionable rather than hidden artifact directories.

## Blockers and unresolved design choices

- Scheduled repo/config identity remains blocked on operator choice: repo-only identity, full task-config identity, or stable task-id-only identity.
- Loop `promptAsync` simplification is blocked until continuation cursor/message correlation and failure semantics are designed. `promptAsync` offloads waiting but loses direct prompt failure counting.
- Plugin event decoder deletion is blocked until upstream `@opencode-ai/plugin` hook types expose the actual bus/v2 event union, including `permission.asked`, `session.deleted`, `session.status`, PTY events, and VCS events.
- PTY bridge implementation is blocked on parity for operator-facing PTY tools and explicit approval for changing the tool/package boundary.
- Auth refresh patch deletion path is a kfactory-owned loopback proxy or an upstream generic dynamic auth-provider hook; neither exists yet.
- Upstream extraction/upstreaming of local opencode patch slices is future work.

## Tooling caveats discovered

- Run opencode validation commands with isolated `HOME`, `XDG_CONFIG_HOME`,
  `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, and
  `OPENCODE_TEST_MANAGED_CONFIG_DIR`; `opencode debug config` can mutate
  bootstrap/project state.

## Verification trail

- `nix develop -c go test ./cmd/kfactory` passed during scheduled/auth/list/dispatch work.
- `factory-opencode-patch-applies` passed with exact patch application.
- `factory-opencode-typecheck` passed after the `v1.15.11` node_modules hash update.
- `factory-opencode-kfactory-contracts`, `factory-kfactory-adapter-plugin-interaction`, `factory-opencode-tui-attach-smoke`, `factory-kfactory-auth-keycloak-integration`, `factory-ntfy-plugin-unit`, `factory-loop-plugin-unit`, `factory-opencode-heal-fixtures`, and `factory-opencode-pty-smoke` passed in targeted runs during the implementation passes.
- `nix build .#checks.x86_64-linux.opencode-pty --no-link --print-build-logs` passed.
- `nix build .#checks.x86_64-linux.factory-opencode-kfactory --no-link --print-build-logs` passed.
- Latest full gate after PTY/package work: `nix flake check --max-jobs 1 --print-build-logs`, all checks passed.
- Whitespace gates passed before this compression pass: `git diff --check` and `git diff --cached --check`.
