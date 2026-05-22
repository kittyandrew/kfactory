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
  decides the workspace's `info.name` (round-trips into opencode's DB
  row, restored on every subsequent adapter call) + its `directory`.
  `create` is what runs the first time a workspace is materialized --
  for us, a git clone. `target` tells opencode HOW to dispatch requests
  for this workspace: either `{type:"local", directory}` (in-process
  via `InstanceStore.provide`) or `{type:"remote", url}` (HTTP proxy to
  a different opencode). We return `local`. `remove` is a no-op (see §5).

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
hunk. A missing/zero `schema_version` on disk is treated as v1 for
back-compat with files written before the field was introduced.

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
     `ServerAuth.header()`) -- does NOT assert. Used to construct the
     static `Authorization` header at attach setup before the refresh
     wrapper is wired in.

Reader 1 runs second; the schema-mismatch throw from reader 1 fires
before any unchecked bearer from reader 2 can be observed by the
server. So the contract is intact today via ordering, not via reader
symmetry. If anyone refactors `attach.ts` to call `validateSession`
(or any other server-hitting code) BEFORE `createBearerRefreshFetch`,
the unchecked read in reader 2 becomes the live failure surface and
the version contract silently degrades. The principled fix is to
mirror the `schema_version` assert in `bearerFromCache` -- deferred
until either: (a) the asymmetry causes a real bug, or (b) the next
opencode bump forces a re-diff of the refresh patch anyway.

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
(`wrk_<ts>`), carries the slug as `info.name`. The KfactoryAdapter
detects the slug shape on subsequent `configure()` calls and
round-trips the name unchanged. There are NO adapter-side state files
-- v1 maintained a parallel JSON index; v2 deleted it entirely. The
DB row IS the state.

`remove()` is a no-op on the adapter. opencode deletes its
WorkspaceTable row when `remove()` returns; the on-disk clone stays.
The operator manually `rm -rf`s the directory when they're done with
the workspace.

### Heal on boot

When the opencode process is killed mid-stream (host restart, OOM,
force-kill), any assistant message in-flight stays in the DB with
`time.completed = null`. The TUI then paints those rows as "still
streaming" forever on the next attach (the sync layer renders a spinner
until a finish marker shows up). A SQLite heal script (consumer-side --
typically wired as a systemd `ExecStartPre`) marks all such orphans as
`finish: "interrupted-by-restart"` before opencode starts, so the TUI
shows a clean "stopped" badge and the operator can re-prompt to
continue.

The heal targets BOTH opencode's v1 `message` table and the v2
`session_message` table. opencode 1.15.4 still routes assistant rows
through v1; v2 is partially implemented (sub-events only today). When
upstream flips assistant storage to v2, the v1 UPDATE becomes a no-op
and the v2 UPDATE takes over -- no gap, no infinite-spinner
regression. Row counts log to the journal so the silent flip is
observable.

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

- **Three-patch opencode stack.** Upstream opencode v1.15.x's
  `opencode attach` only knows HTTP Basic auth and the plugin API has
  no surface for SSE subscriber lifecycle. Three patches, applied
  in order:
  - `opencode-bearer-and-routing.patch` -- upstreamable subset:
    `--bearer` / `OPENCODE_SERVER_BEARER` for Bearer attach;
    `--workspace` flag plumbed through `tui()` into `SDKProvider`,
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
  - `opencode-session-subscribers.patch` -- publishes
    `kfactory.subscribers.changed` with the ABSOLUTE per-workspace
    count `{count: N}` on every SSE attach / detach in `event.ts`. A
    per-instance counter (keyed on the Bus.Interface via a WeakMap)
    tracks live subscribers; the publish carries the post-change
    total. The instance bus is workspace-scoped so each publish only
    reaches plugins running in the same workspace. Used by
    `plugins/ntfy` to derive a per-workspace "is anyone watching"
    signal so notifications are skipped (or cancelled mid-wait) when
    the operator is attached. Absolute-count semantics eliminates the
    cold-start asymmetry inherent to delta accumulation -- a plugin
    that loads after a subscriber attached can't reconstruct state
    from deltas alone, but trivially assigns from the next published
    count. ~30 LOC; lives in a file neither
    neighbour patch touches, so stacking is mechanical rather than
    line-pinned.
  - `opencode-kfactory-refresh.patch` -- kfactory-specific deployment
    glue, applied on top: `OPENCODE_SERVER_BEARER_CACHE_PATH` env +
    `bearerFromCache()`; subprocess `kfactory auth refresh` spawn via
    `createBearerRefreshFetch`; shared auth.json schema with
    `schema_version` assertion; toast subscription for refresh hints.
  Maintained locally until the upstreamable halves (bearer-and-routing,
  session-subscribers) land upstream. Verified on every opencode bump
  by the `factory-opencode-patch-applies` flake check (all three must
  apply cleanly in order).

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
    in the e2e tests since 2026-05.
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
  notifications via ntfy.sh for `session.idle` / `session.error` /
  `permission.asked` events. Vendored as a subset of two upstream MIT
  projects by Anthony Lannutti:
  [opencode-ntfy.sh](https://github.com/lannuttia/opencode-ntfy.sh) (the
  HTTP backend) and
  [opencode-notification-sdk](https://github.com/lannuttia/opencode-notification-sdk)
  (event routing + subagent suppression + config schema). The two-package
  upstream architecture is collapsed into a single self-contained plugin
  -- the SDK indirection added a layer kfactory doesn't need (we have
  exactly one backend), and inlining the routing makes the
  wait + skip-on-connect modifications below land in one obvious place.
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
  `session.idle` for that session fires a check: read the last assistant
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
  race); subagent idles are filtered via `client.session.get(...).data.parentID`.
  Per-session promise chain serializes concurrent idle handlers. State
  lives at `$XDG_STATE_HOME/kfactory-loop/<hash>.json` (NOT inside the
  workspace tree, so accidental `git add .` doesn't capture it). HTTP
  errors on `prompt` count toward a 3-consecutive-failures cap before
  the loop stops; `messages` errors are recoverable (treated as
  no-sentinel). Slash command markdown files (`commands/loop.md`,
  `commands/loop-stop.md`) are shipped as part of the plugin's flake
  output -- consumers wire them via NixOS module
  (`environment.etc."opencode/command/loop.md".source = ...`); the
  plugin does NOT auto-install (avoids a workspace-scope plugin
  mutating operator-global config on every load). Deliberately
  uncoupled from the `opencode-session-subscribers` patch -- the loop
  fires whether the operator is attached or not. Footgun control is
  the operator's job (`/loop-stop`).

- **`notifyAfter` debounce + always-on subscriber suppression.** The
  ntfy plugin per-event knob in `~/.config/opencode/notification-ntfy.json`:
  - `notifyAfter` (shorthand duration: `"3s"`, `"5m"`, `"1h30m"`; default
    `"0s"`): wait this long before firing. If a previous timer for the
    same `(session, event)` pair is pending, the new event replaces it
    (latest wins).

  Subscriber suppression is **non-configurable** and ALWAYS on: if any
  subscriber is attached at event time the notification is suppressed,
  and if any subscriber attaches mid-wait the pending timer is
  cancelled. Cancellation is per-timer (not per-key) -- a subsequent
  event after the operator detaches schedules a fresh timer normally.
  An earlier shape exposed a `skipWhenWatched` per-event opt-out; we
  dropped it because the plugin's whole purpose is "notify only when
  nobody's watching." An even earlier shape latched the cancel as
  process-lifetime sticky-state; that broke the common case (operator
  peeks at a workspace, comes back hours later, never gets a
  notification again) and is gone.
  Subscriber state is fed by the `opencode-session-subscribers` patch's
  `kfactory.subscribers.changed` bus event. The patch publishes the
  ABSOLUTE per-workspace count `{count: N}` after every SSE attach /
  detach -- counter lives in a `WeakMap<Bus.Interface, number>` so it's
  per-instance (workspace-scoped); plugins assign rather than
  accumulate. Absolute count was chosen over `{delta: ±1}` because
  delta accumulation cannot recover from cold-start asymmetry: a
  plugin that loads after a subscriber attached has no way to know
  the true count from deltas alone, so it'd either miss the first
  +1 (and notify with an operator attached) or clamp negative on the
  first -1 (and stay stuck). Absolute counts make the "is anyone
  watching" decision a single read against the latest published
  value. Without the patch no `kfactory.subscribers.changed` events
  arrive, so the count stays at 0 and notifications fire on every
  `notifyAfter` expiry regardless of who is watching -- acceptable
  degraded mode for development. `fetchTimeout` on ntfy POSTs defaults
  to 10s so a hung ntfy server can't stall the plugin's event hook
  indefinitely.
  Note on session-level granularity: the count is **per-workspace**,
  not per-session, because the bus is workspace-scoped and the
  per-workspace `is anyone watching` signal is what the suppression
  rule needs. A side-effect is that subscribing to ANY session inside
  a workspace suppresses notifications for ALL sessions in that
  workspace. This is intentional (operators typically rotate through
  sessions in a workspace and "watching" is a workspace-level
  concept), but it's worth knowing if you tail one session's events
  in another shell -- you'll miss notifications from concurrent
  sessions in the same workspace.

- **`opencode-pty` packaged as a third-party Nix dependency, NOT
  vendored.** Third-party opencode plugins that kfactory wants to
  ship live under `plugins/<name>/` -- same parent directory as
  kfactory-owned plugins, distinguished by the contents of the
  directory (third-party carriers have only `package.json` +
  `package-lock.json`; kfactory-owned plugins have `src/` +
  `tsconfig.json` + typecheck deps). Each carrier is exposed as a
  `packages.<name>` flake output via `mkThirdPartyPlugin`. For
  shekohex/opencode-pty (MIT) the integration shape is:

  - A thin carrier under `plugins/opencode-pty/` -- `package.json`
    declaring `opencode-pty` as a dep + `package-lock.json` locking
    the transitive resolution. The carrier exists purely so
    `buildNpmPackage` has the manifest pair it needs for an offline
    sandboxed install. NO opencode-pty source lives in our tree.

  - `packages.opencode-pty` runs `buildNpmPackage` with
    `npmInstallFlags = ["--ignore-scripts"]`. The flag is redundant
    with `buildNpmPackage`'s `npmConfigHook`, which already
    hardcodes `--ignore-scripts` into its internal `npm ci` call; we
    keep the explicit flag so the suppression is greppable. What it
    ACTUALLY suppresses (despite an earlier comment to the contrary):
    `msgpackr-extract`'s `install: node-gyp-build-optional-packages`,
    reached transitively through `@opencode-ai/sdk` -> effect ->
    msgpackr -> msgpackr-extract. node-gyp-build-optional-packages is
    a runtime resolver, not a compiler, so the resolver runs again the
    first time the plugin require()s msgpackr -- skipping it is
    benign. It does NOT suppress bun-pty's `prepare: bun run build`:
    npm's `prepare` lifecycle does not fire for tarball installs from
    the registry, only for git-URL installs and local in-tree
    development. The bun-pty Rust build was never going to run here
    regardless of the flag; bun-pty's npm tarball ships prebuilt
    platform binaries for Linux x86_64 + arm64, macOS x86_64 + arm64,
    and Windows.

  - The install layout promotes opencode-pty itself to `$out/` and
    hoists its runtime deps (bun-pty, open, open's transitive
    closure) to `$out/node_modules/` -- so opencode's PluginLoader
    can `await import($out)`, resolve via `package.json#exports."./server"`,
    and the loaded plugin's `require("bun-pty")` etc resolve locally.

  Why under `plugins/<name>/` alongside kfactory's own plugins:
  `plugins/` is "where opencode plugins live for this deployment."
  Both shapes belong there because both ARE opencode plugins; the
  difference is how they're packaged, not what they are. The
  distinction is visible on `ls plugins/<name>/`:

  - kfactory-owned plugin -> `src/`, `tsconfig.json`, `package.json`
    declaring typecheck deps, optional `commands/` for slash command
    markdown.
  - third-party carrier -> ONLY `package.json` + `package-lock.json`
    (no `src/`, no `tsconfig.json`). The carrier declares the npm
    package + version + locks the transitive resolution; the actual
    source lands in `$out` of `packages.<name>` at build time.

  Registry split keeps the build paths cleanly separated: kfactory
  plugins live in `pluginSrcs` and go through `mkPlugin` +
  `mkPluginTypecheck` + `mkPluginIntegrationCheck`. Third-party
  carriers live in `thirdPartyPluginSrcs` and go through
  `mkThirdPartyPlugin` (no typecheck or integration-typecheck --
  upstream owns its own tsc story). The directory location is
  decoupled from the registry: both registries point INTO
  `plugins/<name>/`, but the helper applied to each entry is
  decided by which registry holds it.

  An earlier shape parked third-party carriers under a separate
  top-level `nix/<name>/`. The argument was "grep-conflation" -- but
  agents grep `plugins/` looking for opencode plugins, which is
  exactly what's there in both cases. The shape distinction is
  visible at directory listing level. Reverting that split: one
  directory, one mental model.

  Why this shape over vendoring source:
  - opencode-pty is upstream-actively-maintained; bumping follows the
    procedure in `.claude/rules/050-third-party-nix-plugins.md`
    (carrier package.json version edit + regenerate lockfile + recompute
    npm hash + rebuild smoke check). The lockfile-refresh step is
    non-sandboxed (requires network egress) -- that's a hard
    constraint, not a one-liner.
  - Their npm tarball is self-contained for the entry point (dist/ +
    bun-pty's prebuilt .so), so we don't take on their build chain
    (vite, React, tsc, playwright, jsdom devDependencies). The
    PRODUCTION transitive closure is still non-trivial: typescript,
    fast-check, effect, and others land in $out/node_modules because
    @opencode-ai/sdk declares them as runtime dependencies. The Nix
    store path is ~85MB for that reason (verified via `du -sh $out`);
    that's a cost we accept in exchange for not running upstream's
    build chain.
  - License is MIT; combining with our AGPLv3 is fine in this
    direction. No notice obligation on a Nix-package wrapper that
    doesn't re-distribute their source in our tree.

  Why this shape over `Path 3` (manual fetchurl of the transitive
  closure): the carrier lockfile is a single source of truth for
  every transitive version, and bumping is mechanical. Manual
  fetchurls would mean re-deriving the closure on every upstream
  release.

  Why this shape over `Path 4` (opencode auto-installs on first
  run): non-reproducible (runtime network), non-idempotent across
  container restarts in dev, and breaks the kfactory deploy contract
  that opencode.json points at absolute Nix store paths so the OCI
  image is pinned to its plugin set at build time.

  Layout regressions are caught by the auto-registered
  `factory-<name>-smoke` flake check (see `mkThirdPartyPluginSmoke`
  in flake.nix). The smoke mirrors opencode's PluginLoader algorithm
  faithfully: read package.json, resolve `exports["./server"]`
  (handling object/string forms) with fallback to `main`, import that
  exact file, assert it exposes at least one named export. This
  catches `installPhase hoisted the wrong directory`, `upstream
  removed exports["./server"] without setting main`, and `upstream
  changed exports["./server"] to point at a non-existent file` --
  exactly the classes of failure that would silently break opencode
  load while looking healthy from a casual inspection. The check
  does NOT assert a specific export name (e.g. `PTYPlugin`); that's
  the explicit tradeoff for auto-registration. Per-plugin tightening
  is opt-in via a future registry field. Tool-level behaviour
  (pty_spawn, pty_read, pty_kill) is exercised end-to-end by
  dispatching tasks through the Docker e2e tests when meaningful
  changes land; this isn't currently a flake check because spinning
  the e2e tests inside one would mean docker-in-nix-sandbox
  gymnastics that aren't worth the gate they buy.

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
  commands. Dropped: the permission rules (`git commit *`, `git push *`,
  `rm -rf /*`, `sudo *`, etc.) force the agent to ASK before
  destructive ops, and the operator's approval IS the supervision
  pause point. No separate yield primitive needed.

- **`factory-opencode-typecheck` Nix check.** Reuses the
  `opencode-kfactory` build (patched source + opencode's own
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

- **VM-restart auto-continue for in-flight sessions.** Today the
  heal-on-boot SQLite pass marks interrupted sessions as
  `finish: "interrupted-by-restart"`. The operator must reattach and
  send a fresh prompt to resume the loop. A frontier `kfactory resume`
  subcommand would scan interrupted sessions and POST a continuation
  prompt automatically. Requires design work: which sessions to
  resume, what message to send, idempotency if heal+resume races a
  half-started reply.

## 8. What's in this repo

```
cmd/kfactory/                       Go CLI (auth / list / attach / dispatch / delete)
completions/_kfactory               zsh completion (auto-installed via $out/share/zsh/site-functions)
plugins/kfactory-adapter/           opencode WorkspaceAdapter (env-driven)
  src/index.ts                        KfactoryAdapter export
  package.json + package-lock.json    @kfactory/kfactory-adapter; main + exports.server -> src/index.ts
  tsconfig.json
plugins/ntfy/                       ntfy.sh notification plugin
  src/{index,backend,config}.ts       event dispatch + wait + skip-on-connect / HTTP / config + shorthand-duration parser
                                      (each file inlines the full MIT notice for the vendored subset)
  package.json + package-lock.json    @kfactory/ntfy
  tsconfig.json
plugins/loop/                       /loop auto-continuation plugin
  src/index.ts                        session.idle hook + user-defined sentinel + 3-failures-stop
  commands/{loop,loop-stop}.md        slash command markdown (consumer wires via NixOS module)
  package.json + package-lock.json    @kfactory/loop
  tsconfig.json
plugins/opencode-pty/               third-party carrier (manifest-only) for
                                    shekohex/opencode-pty; pinned through Nix as
                                    packages.opencode-pty (see rule 050)
  package.json + package-lock.json    declares opencode-pty + locks transitive resolution
                                      (NO opencode-pty source in our tree; no src/)
patches/                            opencode-bearer-and-routing.patch
                                    + opencode-session-subscribers.patch
                                    + opencode-kfactory-refresh.patch
                                    + oauth2-proxy-pkce-no-secret.patch
tests/e2e/                          Docker-based E2E test environment
  configs/                            opencode-base.json, notification-ntfy.json, auth.json
  scripts/                            dev-up / dev-down / dev-clean / dev-test (nix run apps)
  *-image.nix + test-repo.nix         OCI image builders + bundled test git repo
default.nix                         kfactory CLI build (empty endpoint defaults; ldflags-injectable)
flake.nix                           packages.kfactory / plugins.* / patches.* / checks.*
.claude/rules/                      plugin editing + patch re-diff + third-party-plugin workflows
```

Wiring (reverse proxy config, oauth2-proxy systemd unit, host/VM
config, secrets management, opencode.jsonc, permission ruleset,
prompts) is the consumer's responsibility. See the README for a
`nixosConfigurations` sketch.
