# opencode factory adapter -- spec

A thin shell around opencode's experimental workspace machinery that turns
one `opencode serve` process into a per-repo, per-workspace coding-agent
host behind your reverse proxy + OIDC.

This spec captures **intent + load-bearing decisions** that apply to any
deployment. For paths, configs, and wiring specific to your deployment,
**read the code** -- the artifacts in this repo are the source of truth.
Deployment-specific bring-up procedures (DNS, secrets, host topology,
operator runbook) belong in your consuming repo, not here.

## 0. Upstream primitives we lean on

The factory adapter is a thin shell around opencode's experimental
workspace machinery. Understanding the three primitives below is the
difference between reading this spec as "kfactory invented in-process
multi-tenancy" and reading it as "opencode already did the hard work;
the adapter is ~185 LOC of glue".

- **`InstanceStore.provide({directory}, effect)`** -- opencode's native
  control-plane API for running an Effect Service computation in a
  specific workspace's context. Every HTTP/WS request that hits the
  server goes through this. The adapter's job is to make `directory`
  mean "a per-repo clone" instead of "the process's cwd."

- **`WorkspaceAdapter` callback contract** -- the four methods the plugin
  implements (`configure`, `create`, `target`, `remove`). `configure`
  decides the workspace's `info.name` from explicit producer inputs + its
  `directory`. `create` is what runs the first time a workspace is
  materialized -- for us, a git clone. `target` tells opencode HOW to
  dispatch requests for this workspace: either `{type:"local", directory}`
  (in-process via `InstanceStore.provide`) or `{type:"remote", url}` (HTTP
  proxy to a different opencode). We return `local`. `remove` deletes the
  clone and must fail closed before opencode drops metadata (see §5).

- **`workspace-routing.ts` dispatch** -- opencode's per-request middleware
  picks the workspace from `x-opencode-workspace` HTTP header OR
  `?workspace=` query string, looks up `target()`, and either dispatches
  in-process (`local`) or proxies (`remote`). The bearer-auth patch
  widens this to read the header on non-GET requests too (the SDK only
  rewrites header -> query for GET/HEAD; POST/PUT/DELETE keep the
  header verbatim).

The whole architecture is: opencode's primitives + a tiny adapter that
points `directory` at a git clone + an auth boundary at your reverse
proxy. Everything else in this doc is decisions ABOUT that shape, or
operator-facing scaffolding the consumer wires up.

## 1. What it is

One `opencode serve` process runs with the experimental workspace
machinery enabled. That process owns every workspace as a
`directory`-rooted Effect context, dispatched in-process via
`InstanceStore.provide`. Auth happens at your reverse proxy; the
opencode server itself runs unauthenticated and is only reachable
through that proxy.

```
[ reverse proxy ]
      |
      v  (cookie OR bearer JWT; Authorization stripped before forward)
[ opencode serve (single process) ]
      |
      |  workspace-routing.ts picks ws from header or query
      v
[ InstanceStore.provide({directory: <workspaces-dir>/<slug>}, effect) ]
      |
      v
[ Effect runs against that workspace's project / session / tools ]
```

Workspace identity is an `<owner>--<repo>--<4hex>` slug. Multi-instance
per repo via different random suffixes -- the agent's working branch is
whatever state the git clone has at the time. Client disconnect does
NOT abort the agent loop -- the loop owns the request lifecycle on the
server side, not the WebSocket.

### Workflows

- **Persistent multi-session work.** One workspace, one session,
  reprompted over weeks. Agent never auto-publishes; operator reviews
  + says "commit X, continue with Y."
- **Idea-spawned session.** Operator runs `kfactory dispatch <repo>
  <prompt>`. The adapter clones, opens a fresh session, fires the
  prompt asynchronously; kfactory prints the workspace id and returns.
  Agent works until it hits a permission-gated action (commit, push,
  etc.) -- that's the natural pause point.

Common shape: never auto-publishes, multi-session in flight,
supervision via opencode's `permission` ruleset pause points (§3).
The 16-bit slug suffix gives 65536 collisions-free workspaces per repo;
birthday paradox hits ~256, which is far past steady-state for a
single-operator deployment.

### Threat model: trusted agent, fault containment

NOT adversarial-code defense. The factory shape protects the host from
agent accidents (rm -rf in the wrong dir, runaway processes, FD
exhaustion) and keeps the public internet from reaching opencode
directly. Workspace-to-workspace isolation is a SOFT boundary --
they share a process (§3). Defense layers, in order of strictness:

1. Reverse proxy + OIDC -- gates all external reach. No bypass paths.
2. opencode `permission` ruleset -- pre-execution checks on every
   bash / edit / write tool call.
3. Optional layers your deployment adds (microVM kernel boundary,
   cgroup memory/task limits, network egress allowlist, etc.) -- not
   part of this repo, but the architecture is designed to layer them on.

Out of scope: untrusted-code execution (would escalate to nested
microVM per workspace plus restored process-level isolation). See §7
for the frontier.

## 2. Architecture layers

| layer | what runs |
|-------|-----------|
| host | Reverse proxy at the edge + your OIDC IdP integration. Opencode binds to a private interface only; external reach blocked at the proxy layer. |
| opencode serve | One process, KfactoryAdapter plugin loaded in (registered as workspace type `"kfactory"`). Owns the workspaces dir and the opencode SQLite DB. |
| in-process workspace context | `InstanceStore.provide({directory: <workspaces-dir>/<slug>}, effect)` switches the Effect Service tree per request. Same OS process, same UID, same netns -- isolation is `directory` + opencode's `permission` rules, nothing more. |

There are no per-workspace processes, no per-workspace memory caps, no
per-workspace task caps. A single workspace that runs the host out of
memory takes everyone down. Accepted at single-operator scale; layer
hardening if you need more.

## 3. Boundaries

| boundary | mechanism | enforces | does NOT enforce |
|----------|-----------|----------|------------------|
| public internet -> host | reverse proxy (TLS) | TLS termination, OIDC validation (cookie OR bearer JWT), Authorization-header strip before forward | anything inside the host's private network |
| proxy -> opencode | private bind + (optionally) VM/netns boundary | opencode only reachable from the proxy; external reach blocked by network position | other processes on the host that can route to the same private network |
| in-process workspace context | `InstanceStore.provide({directory}, effect)` + opencode permission rules + cwd | each request's Effect tree is rooted at its workspace's directory; tool calls (bash/edit/write) hit the permission gate | OS-level isolation -- one workspace CAN read another's files via absolute paths if a tool call bypasses the permission rules. There is no UID, netns, or filesystem boundary between workspaces. |

The takeaway: **the process boundary IS the workspace isolation
boundary.** All workspaces share one `opencode serve`, one UID, one
network namespace, one workspaces tree. Separation is `directory` +
permission rules, which is enough for "this agent's tools target this
clone's files" but not enough for adversarial code. v1 of the original
design spent ~500 LOC of adapter code modeling workspaces as
separately-scoped worker processes; v2 deletes that complexity because
the threat model never asked for it.

## 4. Auth model

**No opencode-side password. All auth at the reverse proxy.** The
opencode server is unauthenticated by design; your proxy is the trust
boundary.

Two paths into the deployment, both terminating at the proxy where
OIDC is the only identity authority:

- **Browser**: `<your-domain>` -> proxy forward_auth -> oauth2-proxy ->
  IdP OIDC+PKCE -> session cookie -> request forwarded to opencode.
  WebSocket upgrades take the same path with the proxy-specific
  Connection/Upgrade-header workaround.
- **CLI / launcher**: OAuth 2.0 Device Authorization Grant (RFC 8628)
  + refresh tokens. kfactory holds no long-lived secrets. First run
  pops the IdP's device-confirmation page; subsequent runs use the
  cached access token (silent refresh against the IdP token endpoint
  when stale). The user-tied JWT access token is sent as `Bearer` to
  the opencode host. The proxy validates the JWT locally via the IdP's
  JWKS (no per-request introspection). The OIDC app is the same PKCE
  public client the browser path uses; the CLI just additionally
  requests Device Code + Refresh Token grants on the same app.

PATs and JWT-Profile service-account flows were considered and
rejected: PATs are opaque (the proxy's JWT validator can't validate
them via JWKS); JWT-Profile/SA requires a long-lived RSA private key on
every operator desktop with no real benefit over device-code-plus-refresh
for a single-operator use case.

The `oauth2-proxy-pkce-no-secret.patch` in this repo is verbatim
[oauth2-proxy#3168](https://github.com/oauth2-proxy/oauth2-proxy/pull/3168);
it lets a "PKCE / none" public OIDC app (no client_secret) work without
crashloops. Maintained locally until the upstream PR merges; reviewed
on every oauth2-proxy bump.

Process boundary equals workspace boundary: once a request crosses the
proxy, all workspaces in opencode see the same authenticated identity.
There is no per-workspace credential check inside opencode. Accepted
under the trusted-agent threat model.

### Shared auth-cache schema (Go ↔ patched TUI)

The Go CLI and the patched opencode TUI both read and write
`$XDG_CONFIG_HOME/kfactory/auth.json` (mode 0600). The schema is
versioned via the top-level `schema_version` integer; both sides assert
they understand it before using the contents.

Authoritative definition: the `tokenFile` Go struct in
`cmd/kfactory/auth.go` (and the `authFileSchemaVersion` constant next
to it). The TS reader in `patches/opencode-kfactory-refresh.patch`
(`AuthFile` interface in the attach.ts hunk) mirrors a SUBSET of the
fields it actually consumes (`schema_version`, `access_token`,
`expires_at`); the rest are opaque to TS.

Version bumps: either side adding a non-backward-compatible field must
bump `authFileSchemaVersion` (Go) AND the matching constant in the TS
hunk. A missing/zero `schema_version` on disk is invalid; operators
must re-run `kfactory auth login` with a matching binary rather than
letting either side guess a schema.

**Bootstrap mismatch caveat**: the TUI reads the file synchronously at
`createBearerRefreshFetch` wire-up, BEFORE the toast-bus subscription
in `app.tsx` has mounted. A schema version mismatch at that moment
throws out of `opencode attach` with a clear `auth.json schema_version
N != supported M` line on stderr rather than a toast hint. This is
acceptable -- the failure mode is loud and the operator's recourse
(`kfactory auth login` on a binary that matches the TUI version) is
direct -- but it is NOT the same surface as runtime refresh failures
that DO get a toast. Operators upgrading kfactory must coexist with a
TUI built against the new schema.

**Asymmetric reader caveat**: there are TWO readers of `auth.json`
inside the patched opencode process:

  1. `createBearerRefreshFetch` (in `attach.ts`) -- asserts
     `schema_version === AUTH_FILE_SCHEMA_VERSION` and throws on
     mismatch. Used to build the dynamic refresh-fetch wrapper.
  2. `bearerFromCache` (in `server/auth.ts`, called from
     `ServerAuth.header()`) -- asserts the same schema and token fields.
     Used to construct the static `Authorization` header at attach setup
     before the refresh wrapper is wired in.

Both readers fail closed when `OPENCODE_SERVER_BEARER_CACHE_PATH` is
configured and the cache is missing required fields, malformed, or
unreadable. Continuing with stale or absent auth would hide a broken
producer and turn the reverse proxy's later 401 into the first visible
signal.

The cross-component exit-code contract for `kfactory auth refresh`
(spawned by the TUI as a subprocess) is documented next to the named
exit-code constants in `cmd/kfactory/exit.go` and mirrored in the
TS-side `spawnKfactoryRefresh` comment in the patch.

## 5. Persistence contract

**Workspace DATA is never auto-deleted.** Workspace clones,
per-workspace sessions, snapshots, and manual files in the workspace
tree survive process restarts, host reboots, and opencode binary
upgrades. The operator is the only one who can delete workspace data.

The opencode SQLite DB is the source of truth for workspace identity.
Specifically: opencode's `WorkspaceTable` row, keyed by `info.id`
(`wrk_<ts>`), carries the slug as `info.name`. The KfactoryAdapter mints
that slug during `configure()` from `extra.repoUrl` plus optional valid
`extra.slugSuffix`; it does not preserve caller-supplied names as a second
identity surface. There are NO adapter-side state files -- v1 maintained a
parallel JSON index; v2 deleted it entirely. The DB row IS the state.

`remove()` deletes the on-disk clone. Adapter cleanup must succeed before
opencode deletes the WorkspaceTable row or related session/sync state. A
metadata-only delete would need to be a separately named operation such as
`forget`, not a swallowed failure inside normal `remove`.

### Heal on boot (heal + recovery)

When the opencode process is killed mid-stream (host restart, OOM,
force-kill), any assistant message in-flight stays in the DB with
`time.completed = null`. The TUI then paints those rows as "still
streaming" forever on the next attach (the sync layer renders a spinner
until a finish marker shows up). The `opencode-heal` SQLite script
(shipped with `packages.kfactory`, wired via `services.kfactory.recovery` as
ExecStartPre) marks all such orphans
before opencode starts so the TUI's interrupted-badge renders:

- `data.time.completed = now()` -- unblocks the spinner.
- `data.finish = "interrupted-by-restart"` -- informational; the
  upstream UI ignores `finish` for rendering.
- `data.error = {name: "MessageAbortedError", data: {message: "..."}}`
  -- THIS is what triggers opencode's "Interrupted" badge: the
  upstream timeline renderer checks `m.error?.name ===
  "MessageAbortedError"` (see the `MessageAbortedError` branch in
  `packages/app/src/pages/session/message-timeline.data.ts` of the
  locked opencode source). Pre-2026-05, heal only set `finish`;
  healed turns visually looked completed-normal. Now they show as
  interrupted.

Heal is also the FIRST step of the broader recovery flow: it doesn't
just mark rows, it also EMITS the workspace IDs whose sessions had
stuck turns to a JSON queue at `/run/kfactory/recovery-queue.json`.
The `recovery-sweep` step (ExecStartPost) reads that queue and runs
`kfactory tick <workspace-id> --prompt <recovery-prompt>` per workspace --
injecting the operator-supplied recovery prompt as a new user message
in each affected session's most-recent root session. Without the
queue file, recovery either pings every workspace (noisy prompts in
sessions that did finish) or leaves cleaned rows without an operator nudge.
Heal + recovery are tightly coupled by design: empty queue (no stuck
rows) = recovery-sweep no-op.

**Abandoned-PTY pass (kfactory-specific).** opencode-pty's PTY state
is purely in-memory (`SessionLifecycleManager.sessions: Map<id, Session>`
in `dist/src/plugin/pty/session-lifecycle.js`). On restart the bun
process dies; child PTY processes die with it; the `process.onExit`
JS handler that would have injected `<pty_exited>` is gone. The
spawning assistant turn was `time.completed=set` when the tool
returned, so heal's `time.completed IS NULL` predicate doesn't match
-- recovery queue stays empty, operator's task silently dropped.

heal's second pass closes this: a TEMP TABLE `abandoned_pty` collects
`(message_id, session_id, workspace_id, spawn_time, pty_id)` for every
`pty_spawn(notifyOnExit=true)` tool part with a structured
`<pty_spawned>` block and a `pty_` + 8 lowercase hex id, then DELETEs
entries that DO have a matching user-role structured `<pty_exited>`
block after the spawn. What remains is the set of abandoned PTYs. Each gets
its containing message marked with the same `MessageAbortedError`
shape (different `data.message`: "opencode-pty session killed by
opencode-serve restart") and its workspace queued for recovery-sweep.
Per-pty_id anchoring (not just `</pty_exited>`-substring) closes the
multi-PTY-per-session false-negative class: pty_A's exit message
can't accidentally resolve pty_B.

@WARNING: abandoned-PTY recovery is coupled to JosXa opencode-pty transcript
records: `<pty_spawned>\nID: pty_<8-hex>` and matching synthetic-user
`<pty_exited>\nID: pty_<8-hex>`. The TS parser lives in
`plugins/ntfy/src/pty-lifecycle.ts`; `opencode-heal` mirrors it in SQL.
Until the §6 durable PTY lifecycle ledger exists, bumping
`thirdPartyPluginSrcs.opencode-pty.version` must re-verify regression cases
5d and 10.

Between heal and recovery-sweep, an `opencode-sync-kick` ExecStartPost
HTTP-pokes the per-workspace status sync that opencode otherwise only
triggers on SPA init. Without this, the first session interact after
restart shows "Workspace Unavailable."

Heal targets BOTH opencode's v1 `message` table and v2 `session_message`
table; absent tables are no-ops. At the pinned opencode version, assistant
tool parts still live in the v1 table, so the abandoned-PTY pass is v1-only.

The heal log is a stable single-line JSON object on stdout:
`opencode-heal: {"v1_message":N, "v2_session_message":M,
"abandoned_pty":P, "affected_workspaces":W}` for monitoring and scripted
consumers.

## 6. Decisions log

Choices that shaped the design. Each entry is `result + why`. Only
v2 (current) decisions are kept here; the v1 design's
process-per-workspace architecture is gone and its history isn't
relevant to a consumer.

- **Single `opencode serve` per host (the pivot).** opencode already
  multi-tenants via `InstanceStore.provide`. Spawning a process per
  workspace duplicates that machinery and brings every cost of process
  management (port pools, scope lifecycle, polkit grants, FD limits,
  reconcile loops, spawn-env credential plumbing) for zero benefit at
  single-operator scale. Deleted ~500 LOC of adapter + module code.
  The trade is workspace-to-workspace process isolation -- accepted
  under the trusted-agent threat model.

- **KfactoryAdapter `target: {type:"local"}` returns clone directory.**
  opencode dispatches via `InstanceStore.provide({directory}, effect)`
  in-process. No HTTP proxy, no worker URL, no port. The adapter is
  ~185 LOC end-to-end. Registered with opencode's experimental workspace
  API under the key `"kfactory"`; the CLI POSTs `{"type":"kfactory"}` to
  `/experimental/workspace` to invoke it.

- **kfactory CLI shape.** Subcommands: `auth login/logout/status/refresh`,
  `list`, `attach <id|slug|#>`, `dispatch <repo> <prompt>`, `delete`.
  Token state persists at `$XDG_CONFIG_HOME/kfactory/auth.json` (mode
  0600). Operator runs kfactory in their own terminal -- the CLI stays
  out of window management.

- **Dispatch prompt-file arguments are path-shaped and local to dispatch.**
  `kfactory dispatch <repo-url> <prompt...>` treats the prompt as a file
  only when the prompt position is exactly one argument, the argument starts
  with `./`, `../`, `/`, or `~/`, and it contains no whitespace. Existing
  regular files are read and dispatched as the prompt; missing path-shaped
  files error with the absolute path plus an inline-prompt hint; directories
  error clearly; `~/...` expands through the current user's home directory.
  Bare names such as `prompt.txt`, normal multi-word prompts, and `kfactory
  tick --prompt` stay inline text. The zsh completion offers file paths only
  after the dispatch prompt argument already looks path-shaped.

- **Four-patch opencode stack.** Upstream opencode v1.15.x's
  `opencode attach` only knows HTTP Basic auth and its workspace routing
  defaults to project scope. Four patches, applied in order:
  - `opencode-bun-version-relax.patch` -- bun-version build workaround. opencode
    v1.15.5+ pins `packageManager: "bun@1.3.14"` and the build script
    enforces `^${version}`. nixpkgs currently ships bun 1.3.13 because
    bun 1.3.14 produces segfaulting binaries when used to build
    downstream packages (see nixpkgs PR #519796, in DRAFT). opencode's
    bun bump (anomalyco/opencode#27648) was metadata-only -- no new bun-API
    calls in the runtime path, just a future-proofing pin against the
    upcoming Rust-rewrite Bun 2.x line. This patch relaxes the range
    to `>=1.3.13` so the build accepts the bun nixpkgs has. Drop the
    patch when nixpkgs ships bun 1.3.14+.
  - `opencode-static-bearer.patch` -- generic client-side Bearer header
    plumbing: `--bearer` / `OPENCODE_SERVER_BEARER` for Bearer attach.
    Server-side opencode still does not validate Bearer; deployments use
    this with a JWT-validating reverse proxy.
  - `opencode-workspace-routing.patch` -- upstreamable workspace
    correctness subset: `--workspace` flag plumbed through `tui()` into `SDKProvider`,
    `ProjectProvider`, AND `validateSession` (so the pre-attach probe
    runs against the requested workspace); workspace-routing header
    fallback for non-GET requests (the SDK only rewrites header ->
    query for GET/HEAD); `Session.listGlobal` filter by workspace_id
    so `--continue` and session-list scope to the attached workspace
    (sidesteps upstream's project_id-based scoping, which collapsed
    when multiple workspaces shared a project_id); plugin-adapter
    registration scoped to `ProjectID.global` rather than the boot
    instance's `ctx.project.id` (so per-request workspaces can find
    the adapter regardless of which project the plugin loader ran in).
  - `opencode-kfactory-refresh.patch` -- kfactory-specific deployment
    glue, applied on top: `OPENCODE_SERVER_BEARER_CACHE_PATH` env +
    `bearerFromCache()`; subprocess `kfactory auth refresh` spawn via
    `createBearerRefreshFetch`; shared auth.json schema with
    `schema_version` assertion; toast subscription for refresh hints.
  Maintained locally until the upstreamable workspace-routing work lands
  upstream. Verified on every opencode bump by the
  `factory-opencode-patch-applies` flake check (all re-diffable patches
  must apply cleanly in order).

- **Subprocess-delegated token refresh (kfactory owns; TUI spawns).**
  kfactory (Go) is the single source of truth for OIDC token refresh:
  acquires a POSIX `flock(2)` on `~/.config/kfactory/auth.json.lock`,
  re-reads under the lock, POSTs the IdP token endpoint with the
  refresh_token, atomic-renames the new tokens, releases the lock
  (kernel-released on process exit, so SIGTERM doesn't leak it).
  The patched opencode TUI doesn't replicate any of that -- when the
  access token is near expiry the TUI spawns `kfactory auth refresh`,
  captures its stderr (NOT inherits -- inheriting would corrupt the
  Ink alternate-screen mid-render), and branches on the exit code
  (`exitOK`/`exitNotLoggedIn`/`exitOther` per `cmd/kfactory/exit.go`).
  Refresh outcomes feed into an in-process pub/sub channel
  (`refreshHintSubscribers`); an `onMount` subscription in `app.tsx`
  surfaces a single error toast (`toast.show({variant: "error",
  duration: 8000, ...})`) per failure mode per TUI session for
  `not_logged_in` / `spawn_error` / `other_error`. Concurrent
  attaches against the same operator desktop are serialized by
  kfactory's flock regardless of which process initiated the refresh.
  This keeps refresh logic in one place (Go, with its own tests) and
  shrinks the TS patch vs an alternative file-cache-in-TS design. See
  `cmd/kfactory/auth.go:runAuthRefresh` and the TS fetch wrapper at
  `packages/opencode/src/cli/cmd/tui/attach.ts:createBearerRefreshFetch`
  in `patches/opencode-kfactory-refresh.patch`.

- **Real IdP auth integration owns expired-token refresh coverage.**
  The authoritative refresh regression is a NixOS VM flake check with a
  real Keycloak service, the real `kfactory` binary, real `opencode serve`,
  and real PTY-backed `opencode attach`. Fast TUI smoke tests may cover
  explicit bearer and fresh-cache attach behavior, but they must not fake
  `kfactory auth refresh`, OIDC discovery, device authorization, token, or
  refresh endpoints. The Keycloak check drives OAuth device login through
  the provider's returned verification URL, expires only `expires_at` in
  `auth.json`, asserts real `kfactory auth refresh` rotates/futures the
  token, then asserts the patched TUI-spawned refresh makes the recording
  proxy observe the refreshed bearer and never the expired one. Refresh
  initializes the relying party without scopes because Keycloak rejects
  refresh-token requests that repeat the original login scopes.

- **Bearer token is env-only / cache-file-only (never on argv).**
  kfactory passes `OPENCODE_SERVER_BEARER_CACHE_PATH` to the TUI; the
  TUI reads the current access token from that file via
  `bearerFromCache` in the patched `server/auth.ts`. No CLI flag, no
  `OPENCODE_SERVER_BEARER` env (the patch's `--bearer` flag still
  exists for non-cache-file users but kfactory doesn't use it). Token
  never appears in `/proc/<pid>/cmdline`, and the cache-file path
  means the SDK's first request after a refresh always sees the
  freshest token.

- **Slug = `<owner>--<repo>--<4hex>`.** 4hex random suffix gives
  65536 slug-space per repo; birthday paradox at ~256 workspaces but
  irrelevant at single-operator scale. Decouples slug from git state
  (branch can change after clone). Round-trips via `info.name`.

- **SQLite heal on boot for orphan assistant messages.** Process
  restart / OOM / SIGKILL skips opencode's graceful `time.completed`
  marking, leaving rows in a "still streaming" state. The consumer
  wires an ExecStartPre that marks them `interrupted-by-restart` so
  the TUI shows a clean "stopped" badge.

- **Dual-table heal: v1 `message` AND v2 `session_message`.**
  opencode 1.15.4 routes assistant rows through v1; v2 is partially
  implemented. Running UPDATE against both tables means the silent
  flip to v2 happens without a regression; row counts log so the flip
  is observable.

- **Patch opencode `Session.listGlobal` AND `Session.list` to filter
  by workspace_id.** Upstream opencode copies the requesting
  instance's `project.id` into the new workspace row at insert time.
  For an unscoped `POST /experimental/workspace` that resolves to the
  front-opencode's cwd-based project (`global`, non-git), every
  workspace ends up sharing `project_id = global`. Upstream's
  session-list paths filtered by `project_id`, so `--continue` and
  root-session listing collapsed across workspaces -- attaching to
  workspace A would resume the globally-most-recently-touched session
  regardless of where it lived.

  The patch:
  1. Adds an optional `workspaceID` filter to `listGlobal` applying
     `where SessionTable.workspace_id = workspaceID`, plumbed
     through the `/experimental/session` handler from the request's
     `?workspace=` query param.
  2. Makes the `Session.list` Service method read
     `InstanceState.workspaceID` (set by the workspace-routing
     middleware via `WorkspaceRef`) and pass it into `listByProject`
     -- which already supported the filter parameter upstream but
     never had it populated. This is the path the TUI takes on
     `--continue`: `GET /session?directory=<wsDir>` with the
     `x-opencode-workspace` header.

  Sessions get scoped by the workspace they actually belong to,
  independent of project_id. ~30 LOC TS in the bearer-auth patch.
  Upstream-PR-worthy.

  Verification trail:
  - `/experimental/session?workspace=<id>` verified workspace-scoped
    in the regression tests since 2026-05.
  - `/session` (the TUI's actual endpoint) was NOT verified initially
    -- the earlier harness test asserted only on `/experimental/session`,
    which goes through `listGlobal`. The TUI goes through `listByProject`.
    The first deployment hit this gap (same session on every
    `kfactory attach`) and the harness regression now covers both
    paths in step `[4b/6]` of `dev-test.nix`. The adversarial probe
    (mismatched x-opencode-workspace header + directory) confirms the
    workspace header wins.

  An earlier draft of the patch took a different approach:
  post-`adapter.create` re-resolve via `Project.fromDirectory(info.directory)`
  + UPDATE workspace.project_id. Architect review found it dead-weight
  once `listGlobal` filtered by workspace_id -- no downstream consumer
  actually requires per-workspace unique project_id. That hunk is
  gone; this note exists so the next reader doesn't re-derive it.

  Possible residual: the SPA "review changes" widget reads
  `project.vcs` via the workspace's `project_id`. If the SPA path
  exposes a per-workspace VCS view, it'd see whatever project_id
  ended up on the row at insert time (typically `global` for the
  kfactory CLI flow). The kfactory CLI doesn't exercise the SPA path
  so this is invisible to the current product surface; revisit if a
  future deployment surfaces the SPA widget.

- **Plugins read config from env vars, not Nix-substituted placeholders.**
  Earlier plugins ran through `pkgs.replaceVars` to inject `@GIT@` etc.
  as absolute Nix store paths at build time. Gone -- replaced with
  `process.env.KFACTORY_ADAPTER_GIT` (and friends), defaulting to PATH-
  resolved binaries (`git`, `ssh`) and `/var/lib/factory/workspaces`.
  Consumers wrap opencode with the env vars they want (typically
  absolute store paths so PATH lookup isn't load-bearing at runtime).
  This eliminates the build-step indirection (`lib.mkFactoryAdapter` is
  gone), keeps the plugin source greppable + tsc-clean, and matches the
  user-supplied convention for `plugins/<name>/` packages.

- **Per-plugin typechecks via flake check.** Every plugin under
  `plugins/<name>/` ships its own `package.json` + lockfile + tsconfig
  and gets a `<name>-typecheck` flake check (`tsc --noEmit` against
  `@opencode-ai/plugin` + `@types/node` resolved offline via
  `buildNpmPackage`). Adding a new plugin under `plugins/<name>/` plus
  an entry in `pluginSrcs` registers it automatically. See
  `.claude/rules/010-plugin.md`.

- **Carved-out ntfy plugin under `plugins/ntfy/`.** Sends push
  notifications via ntfy.sh for idle (`session.status` with
  `status.type === "idle"`), `session.error`, and `permission.asked`
  events. Vendored as a subset of two upstream MIT
  projects by Anthony Lannutti:
  [opencode-ntfy.sh](https://github.com/lannuttia/opencode-ntfy.sh) (the
  HTTP backend) and
  [opencode-notification-sdk](https://github.com/lannuttia/opencode-notification-sdk)
  (event routing + subagent suppression + config schema). The two-package
  upstream architecture is collapsed into a single self-contained plugin
  -- the SDK indirection added a layer kfactory doesn't need (we have
  exactly one backend), and inlining the routing keeps kfactory-specific
  gates and debounce in one obvious place.
  Each vendored source file inlines the full MIT permission notice +
  Anthony Lannutti's copyright (per-file headers ARE the MIT notice;
  there is no separate LICENSE-MIT). Upstream commit pins + the
  "kfactory modifications" list live in the same header so a future
  bump's diff stays greppable. Project LICENSE stays AGPLv3 (more
  restrictive than MIT, combining direction is fine).

- **`plugins/loop/` `/loop` auto-continuation plugin.** Minimal
  in-process loop driver inspired by
  [charfeng1/opencode-ralph-loop](https://github.com/charfeng1/opencode-ralph-loop)
  (MIT) and Anthropic's ralph-wiggum technique. After the operator runs
  `/loop --max 50 --sentinel "ALL DONE" <task>`, every subsequent
  `session.status` idle for that session fires a check: read the last assistant
  message, compare the LAST non-empty line (trimmed) against the
  configured sentinel for case-sensitive equality. If it doesn't match
  and `iteration < max`, inject a continuation prompt via
  `client.session.prompt`. Default sentinel
  `<promise>EXHAUSTIVELY COMPLETED</promise>` is intentionally verbose
  so the model is unlikely to emit it speculatively. Last-line equality
  (rather than substring-anywhere) means a model that mentions the
  sentinel mid-response -- in a plan, a paraphrase, a quoted prompt --
  does NOT terminate the loop; only a clean trailing sentinel does.
  Trailing punctuation ("ALL DONE." instead of "ALL DONE") also leaves
  the loop running, which is intentional: the matcher demands a clean
  emission so the operator's contract with the model is unambiguous.
  The session that owns the loop is captured
  at `loop-start` time from `ToolContext.sessionID` (no first-idle latch
  race); child/subagent starts are refused and subagent idles are filtered via
  `client.session.get(...).data.parentID` for pre-existing state. Deprecated
  `session.idle` events are ignored so upstream's duplicate idle publication
  cannot double-prompt. On plugin initialization, active durable state is checked
  against upstream `client.session.status`; missing status entries are treated as
  idle because upstream stores only non-idle statuses in the status map.
  Per-session promise chain serializes concurrent idle handlers. State
  lives at `$XDG_STATE_HOME/kfactory-loop/<hash>.json` (NOT inside the
  workspace tree, so accidental `git add .` doesn't capture it). HTTP
  errors on `prompt` count toward a 3-consecutive-failures cap before
  the loop stops; `messages` errors are recoverable (treated as
  no-sentinel). Slash command markdown files (`commands/loop.md`,
  `commands/loop-stop.md`) are inlined into the unified runtime's generated
  default `OPENCODE_CONFIG`. The plugin does NOT write operator-global config on load.
  The loop fires whether the operator is attached or not. Footgun control
  is the operator's job (`/loop-stop`).

- **`notifyAfter` debounce + always-send notification semantics.** The
  ntfy plugin per-event knob in `~/.config/opencode/notification-ntfy.json`:
  - `notifyAfter` (shorthand duration: `"3s"`, `"5m"`, `"1h30m"`; default
    `"0s"`): wait this long before firing. If a previous timer for the
    same `(session, event)` pair is pending, the new event replaces it
    (latest wins).

  Notifications intentionally fire whether or not an operator is
  attached through the TUI or web UI. Reconnecting is not a cancel
  signal; the phone alert is still useful as a durable completion marker
  and keeps behavior independent of opencode's subscriber lifecycle.
  `fetchTimeout` on ntfy POSTs defaults to 10s so a hung ntfy server
  can't stall the plugin's event hook indefinitely.

  **PTY-pending idle suppression.** When the agent uses opencode-pty's
  `pty_spawn(notifyOnExit=true)` (the plugin's documented async
  pattern), the tool returns immediately and the LLM turn completes;
  `session.idle` fires while the PTY is still running. Without
  intervention, ntfy fires a misleading "Agent Idle" notification
  3s later. The PTY's own onExit callback eventually injects a
  `<pty_exited>` user message that wakes the agent for turn 2 --
  the "idle" was transient.

  ntfy suppresses idle when the shared PTY lifecycle parser reports pending
  notify-on-exit PTYs; parser boundary: `plugins/ntfy/src/pty-lifecycle.ts`.
  The parser reads exact records, not prose mentions, and matches per PTY ID
  to avoid multi-PTY false negatives. Same third-party-format contract as the
  heal abandoned-PTY pass.

  @WARNING: PTY idle suppression scans full session history per
  `session.idle` (O(N) HTTP + walk). Acceptable at current scale; replace both
  heal + ntfy transcript parsing when the durable PTY lifecycle ledger lands.

- **`opencode-pty` packaged as a third-party Nix dependency, NOT
  vendored.** `plugins/opencode-pty/` is a manifest-only carrier for
  `@josxa/opencode-pty@0.7.1`; no upstream source lives in this tree.
  The internal `mkThirdPartyPlugin` package maps the local attr name to the
  scoped npm `packageName`. The builder promotes the scoped package itself to `$out/` and hoists
  runtime deps to `$out/node_modules/`, matching opencode's package loader
  with `exports["./server"]` plus `main` fallback. `npmInstallFlags =
  ["--ignore-scripts"]` is kept for greppability; the skipped
  `msgpackr-extract` resolver is reached through runtime deps and is not
  a compiler for this package. Registry tarballs already ship JosXa's
  built `dist/` and prebuilt `bun-pty` binaries. The packaged artifact
  patches `isQuickInterrupt()` to return `false` because elapsed time
  alone is not an interrupt signal, and JosXa 0.7.1 otherwise aborts the
  parent opencode session for any notify-on-exit process exiting within
  two seconds. Carrier lockfiles are the transitive-version source of
  truth; runtime auto-install and manual fetchurl closures are rejected as
  non-reproducible or higher-maintenance.

- **Future PTY bridge contract is an append-only lifecycle ledger.** A
  kfactory-owned PTY bridge must write JSONL records instead of making chat
  transcript text canonical lifecycle state. Schema v1 records require
  `schema_version: 1`, non-empty `workspace_id`, `session_id`, `message_id`,
  `pty_id`, `event`, and integer epoch-ms `time`; `pty_id` remains
  `pty_` + 8 lowercase hex chars until heal, ntfy, fixtures, and persisted
  records migrate together. `event` is exactly `spawned` or `exited`.
  `spawned` requires `notify_on_exit`; `exited` copies `notify_on_exit` and
  adds `exit_code`, `timed_out`, and a bounded output summary. The bridge
  writes `spawned` before reporting `pty_spawn` success and writes `exited`
  before any notify-on-exit wakeup prompt. Unknown-version, malformed,
  missing, or order-invalid data is `unknown`, not `clear`; ntfy suppresses
  idle notifications on `pending` or `unknown` and emits an operator-visible
  warning for `unknown`; heal treats pending records across restart as
  abandoned PTYs and queues recovery. Transcript parsing is not part of the
  ledger contract; remove it once heal and ntfy consume ledger records in tests.

- **`packages.kfactory` is the unified runtime package.** It contains the
  kfactory CLI plus patched opencode, sets
  `OPENCODE_EXPERIMENTAL_WORKSPACES=true`, bakes adapter tool/env defaults,
  and sets default `OPENCODE_CONFIG` to a Nix-substituted copy of
  `nix/shared/opencode-kfactory-base.jsonc`. That JSONC contains the base
  model/instruction/permission policy plus plugin store paths
  (`kfactory-adapter`, `ntfy`, `loop`, JosXa `opencode-pty`) and `/loop`
  slash-command templates. Operators can replace it at runtime by setting
  `OPENCODE_CONFIG`; a replacement file must include any desired plugins and
  commands itself. There is no public CLI-only package; the `kfactory` binary
  must move with its matched opencode/config/plugin closure.

- **Public flake API is deliberately small.** Public package outputs are only
  `packages.kfactory` (`default` alias) and `packages.oauth2-proxy-kfactory`.
  Plugins, third-party plugin packages, local opencode patches, lifecycle
  helpers, and regression images are internal values promoted into `checks`,
  not consumer-facing flake outputs.

- **Permissions live in the JSONC base config, not Nix data.** opencode's
  permission engine preserves JSON object order and evaluates the last
  matching rule. The checked-in JSONC file is therefore the durable policy
  surface; Nix must not model that policy as unordered attrsets.

- **Upstream-contract watch list.** opencode is EXPERIMENTAL (gated by
  `OPENCODE_EXPERIMENTAL_WORKSPACES`); re-verifying these on every
  opencode bump is mandatory. The plugin typecheck catches API SHAPE
  drift; the patch-applies check catches patch-against-source drift;
  neither catches behavior changes. Watch:
  - `info.name` round-trips: opencode writes our slug into the DB row
    persisted from `configure()`'s return; restored on every
    subsequent adapter call. If opencode ever stops persisting it,
    slugs drift.
  - WorkspaceAdapter optional method set (`list?`, `init?`, etc.). We
    intentionally don't implement `list?`; opencode's workspace table
    drives enumeration.
  - `?workspace=<id>` query and `x-opencode-workspace` header routing
    semantics in workspace-routing.ts (the SDK only rewrites the
    header to a query string on GET/HEAD; the bearer-auth patch makes
    the server read both for all methods).
  - `WorkspaceAdapter.remove` caller set. The plugin's `remove()`
    does `rm -rf` of the workspace directory, trusting opencode to
    only invoke it via operator-initiated DELETE
    `/experimental/workspace/<id>`. A future upstream feature that
    calls `remove()` from a different path (orphan GC, rollback after
    failed create, etc.) would silently wipe clones contrary to the
    persistence contract (§5). Audit the call sites on every bump.

- **No slash commands; permission rules ARE the supervision
  mechanism.** Earlier designs had `/commit` and `/yield` slash
  commands. Dropped: the permission rules (`gh pr *`, `gh release *`,
  `git reset --hard*`, `rm -rf /`, `sudo *`, etc.) force the agent to ASK
  before selected outward-facing or destructive ops, and the operator's
  approval IS the supervision pause point. No separate yield primitive needed.

- **`kfactory tick` as the unified idempotent-dispatch verb.** Two
  shapes share the same subcommand: scheduled fire (when
  `/etc/kfactory/scheduled/<id>.json` exists, ref is a task id, mode
  drives behavior) and ad-hoc nudge (ref is the target workspace ID or
  4-hex slug suffix, `--prompt` required). `tick` deliberately does
  NOT resolve by list index or arbitrary slug prefix: exact workspace
  IDs support recovery queues and scheduled identity, while 4-hex slug
  suffixes remain an ad-hoc operator handle for existing workspaces. The
  alternative would be two subcommands
  (`kfactory schedule-fire` + `kfactory nudge`) that share 95% of their
  plumbing.

- **Stable scheduled workspace ID.** Scheduled creates also send
  `id = "wrk_kfactory_<task-id>"` in `POST /experimental/workspace`.
  That is the only scheduled identity. Workspace names/slugs are display
  labels, not identity, and scheduled ticks do not reuse suffix-only rows.
  A failed create remains a failure; kfactory does not infer success from
  a listed row after a generic create error. Ad-hoc `dispatch` still
  omits `id` and uses opencode's normal random workspace IDs.

- **Scheduled first-run proof.** Existing-workspace scheduled modes run only
  after canonical opencode state shows the workspace's root session contains
  the configured `initial_prompt`. The per-task lock is only a mutex; cache
  file contents are never first-run proof. If a stable workspace exists but
  the initial prompt is absent, `kfactory tick` repairs the first run by
  sending `initial_prompt` to the existing root session, or by creating a root
  session in the existing workspace when none exists.

- **Branch/dirty status stays in kfactory.** `kfactory list` enriches
  display rows with upstream `GET /vcs?workspace=<id>`. `kfactory tick`
  implements `skip-if-dirty` with upstream
  `GET /vcs/status?workspace=<id>`: an empty status array is clean,
  a non-empty array is dirty, and request errors skip the dispatch. This
  keeps opencode's `/experimental/workspace` list unmodified.

- **Scheduled-task creation is serialized at the CLI and opencode API
  boundary.** Scheduled workspaces are keyed by caller-provided workspace
  ID `wrk_kfactory_<task-id>`; workspace names/slugs are display labels,
  not identity. `kfactory tick <id>` takes a per-task local file lock so
  overlapping systemd/manual fires converge through one list/create/continue
  path. A waiter no-ops only after opencode state shows the root session
  contains `initial_prompt`, and it still prints the workspace ID for
  operator visibility. For later non-overlapping runs, the same canonical
  state gates existing-workspace modes. A failed create remains a failure;
  kfactory does not list workspaces after a generic create error and infer
  success from a matching row.

- **Tests are checks-first.** `nix flake check` is the primary verification
  surface. Durable harnesses should be exposed as flake checks, either
  individual checks or grouped aggregate checks; local helper apps may
  remain for operator workflows, but checks are the blocking CI/review
  contract. Methodology-owned checks live under `nix/<methodology>/default.nix`
  and aggregate through `nix/default.nix`; this repo's real-process, VM,
  and Docker regression checks classify as fixed-example checks under
  `nix/unit/`, not a separate `nix/e2e/` methodology. Real TUI workflows
  need PTY-backed process coverage with server-observed request behavior as
  the primary oracle. Patch-stack behavior needs semantic contract tests
  before ownership splits. Docker behavioral assertions live in the Go
  regression runner, with shell retained only for lifecycle wrappers.

- **Heal + recovery coupled via heal-emitted queue.** Heal does two
  things: marks stuck rows AND writes the affected-workspace IDs to
  a queue file at `/run/kfactory/recovery-queue.json`. Recovery
  reads that queue and ticks ONLY those workspaces. Without the queue,
  recovery either iterates ALL workspaces (noisy prompts injected into
  finished sessions) or skips prompt injection entirely (rows cleaned but no
  nudge surfaced). Empty queue (heal found nothing) -> empty
  recovery sweep. The tight coupling is the design: heal answers
  "what's stuck", recovery answers "what to do about it", neither
  half is useful alone.

- **`scheduledTasks` + `recovery` as the only NixOS modules.** Two
  pieces of the deployment surface are intrinsically NixOS-shaped:
  per-task systemd timer generation, and ExecStartPre/ExecStartPost
  drop-ins on the opencode-serve unit. Both surface
  attribute-schemas that read naturally as NixOS options. The CLI
  defines the JSON config schema; the module emits JSON the CLI
  accepts. Everything else stays module-free -- operators wire the unified
  runtime and oauth2-proxy sibling into their own host/reverse-proxy configs
  (per the "no Caddyfile / no docker-compose" stance in the README).

- **`factory-opencode-typecheck` Nix check.** Reuses the patched opencode
  component (patched source + opencode's own
  `node_modules.nix`-built deps) and runs `tsc --noEmit` against
  `packages/opencode/`. Uses standard `tsc` rather than `tsgo` (which
  needs a postinstall-downloaded native binary that opencode's
  `bun install --ignore-scripts` skips). A baseline-diff filter
  excludes opencode-upstream noise (e.g. missing `@types/mime-types`
  in `packages/core/src/filesystem.ts`); any new patch-induced type
  error fails the check. Closes the type-semantic drift gap the
  original v1 of this spec listed as frontier work.

## 7. Scope frontier

What's deferred (not "what's broken" -- bugs live in your consuming
repo's runbook, not in this spec):

- **Per-workspace network policy.** Currently shared netns; future:
  per-workspace netns + veth + egress allowlist. Requires
  reintroducing some form of per-workspace process isolation (or
  per-workspace nsenter for tool calls). Not free, but the
  architecture is positioned as the layer to build on.

- **Untrusted-code execution sandbox.** v1 is fault containment only.
  For real adversary defense: per-workspace netns AND per-workspace
  process (back to systemd-scope or similar) AND bwrap mount-ns,
  layered onto v2. Escalate to nested microVM per workspace (~80 MB
  RSS, ~150 ms boot) if needed. Multi-step regression of v2's
  simplicity; only worth it once the workload demands it.

- **Multi-machine federation.** The adapter's `{type:"remote", url}`
  return IS the federation primitive -- factory-adapter today returns
  `local` but could mix `local` for local workspaces with `remote`
  for workspaces living on a sibling host. Single-host today;
  layering federation later is a few lines on the existing primitive.

- **Theme customization.** Default opencode SPA theme is fine for v1.
  Future: investigate opencode's theme-loading hooks; may be a `theme`
  field in `opencode.jsonc` or CSS injection via the embedded UI's
  options.

- **Observability sidecars.** No observability primitives ship in this
  repo. Future: `subscribeAll` bus sidecar to capture an event log;
  llm-trace + permission-trace JSONL per workspace for later
  analysis. Implementation belongs in the consumer.

- ~~**VM-restart auto-continue for in-flight sessions.**~~ Shipped.
  See the "heal + recovery via heal-emitted queue" decision below
  for the design + the `services.kfactory.recovery` module wiring.

## 8. What's in this repo

```
cmd/kfactory/                       Go CLI (auth / list / attach / dispatch / delete)
completions/_kfactory               zsh completion (auto-installed via $out/share/zsh/site-functions)
plugins/kfactory-adapter/           opencode WorkspaceAdapter (env-driven)
  src/index.ts                        KfactoryAdapter export
  package.json + package-lock.json    @kfactory/kfactory-adapter; main + exports.server -> src/index.ts
  tsconfig.json
plugins/ntfy/                       ntfy.sh notification plugin
  src/{index,backend,config}.ts       event dispatch + debounce / HTTP / config + shorthand-duration parser
                                      (each file inlines the full MIT notice for the vendored subset)
  package.json + package-lock.json    @kfactory/ntfy
  tsconfig.json
plugins/loop/                       /loop auto-continuation plugin
  src/index.ts                        session.status idle hook + user-defined sentinel + 3-failures-stop
  commands/{loop,loop-stop}.md        slash command markdown (bundled into unified runtime config)
  package.json + package-lock.json    @kfactory/loop
  tsconfig.json
plugins/opencode-pty/               third-party carrier (manifest-only) for
                                    @josxa/opencode-pty; packaged internally
                                    by the unified runtime (see rule 050)
  package.json + package-lock.json    declares @josxa/opencode-pty + locks transitive resolution
                                      (NO opencode-pty source in our tree; no src/)
patches/                            opencode-static-bearer.patch
                                    + opencode-workspace-routing.patch
                                    + opencode-kfactory-refresh.patch
                                    + oauth2-proxy-pkce-no-secret.patch
nix/e2e/                            Docker-based e2e images/configs + behavioral runner
  *-image.nix + test-repo.nix         OCI image builders + bundled test git repo
  configs/                            opencode-base.json, notification-ntfy.json, auth.json
nix/scripts/                        dev-up / dev-down / dev-clean / dev-test (nix run apps)
nix/shared/kfactory-runtime.nix      unified runtime + plugin/command overlay wrapper
nix/shared/opencode-kfactory-base.jsonc  base opencode config, permissions, model, instructions
default.nix                         internal kfactory CLI build (runtime env endpoint defaults)
flake.nix                           public packages: kfactory + oauth2-proxy-kfactory; checks + dev apps
.claude/rules/                      plugin editing + patch re-diff + third-party-plugin workflows
```

Wiring (reverse proxy config, oauth2-proxy systemd unit, host/VM
config, secrets management, opencode.jsonc, permission ruleset,
prompts) is the consumer's responsibility. See the README for a
`nixosConfigurations` sketch.
