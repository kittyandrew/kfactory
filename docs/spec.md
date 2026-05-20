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
| opencode serve | One process, FactoryAdapter plugin loaded in. Owns the workspaces dir and the opencode SQLite DB. |
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
(`wrk_<ts>`), carries the slug as `info.name`. The FactoryAdapter
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

- **FactoryAdapter `target: {type:"local"}` returns clone directory.**
  opencode dispatches via `InstanceStore.provide({directory}, effect)`
  in-process. No HTTP proxy, no worker URL, no port. The adapter is
  ~185 LOC end-to-end.

- **kfactory CLI shape.** Subcommands: `auth login/logout/status/refresh`,
  `list`, `attach <id|slug|#>`, `dispatch <repo> <prompt>`, `delete`.
  Token state persists at `$XDG_CONFIG_HOME/kfactory/auth.json` (mode
  0600). Operator runs kfactory in their own terminal -- the CLI stays
  out of window management.

- **Split opencode patches.** Upstream opencode v1.15.x's
  `opencode attach` only knows HTTP Basic auth. Two patches, applied
  in order:
  - `opencode-bearer-and-routing.patch` -- upstreamable subset:
    `--bearer` / `OPENCODE_SERVER_BEARER` for Bearer attach;
    `--workspace` flag plumbed through `tui()` into `SDKProvider`,
    `ProjectProvider`, AND `validateSession` (so the pre-attach probe
    runs against the requested workspace); workspace-routing header
    fallback for non-GET requests (the SDK only rewrites header ->
    query for GET/HEAD); post-`adapter.create` project re-resolve in
    `Workspace.create`.
  - `opencode-kfactory-refresh.patch` -- kfactory-specific deployment
    glue, applied on top: `OPENCODE_SERVER_BEARER_CACHE_PATH` env +
    `bearerFromCache()`; subprocess `kfactory auth refresh` spawn via
    `createBearerRefreshFetch`; shared auth.json schema with
    `schema_version` assertion; toast subscription for refresh hints.
  Maintained locally until the upstreamable half lands upstream.
  Verified on every opencode bump by the `factory-opencode-patch-applies`
  flake check (both patches must apply cleanly in order).

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

- **Patch opencode `Workspace.create` to re-resolve project from
  workspace directory after adapter.create.** Upstream opencode copies
  the requesting instance's `project.id` into the new workspace row at
  insert time. For an unscoped `POST /experimental/workspace` that
  resolves to the front-opencode's cwd-based project (`global`,
  non-git), and every workspace ends up sharing
  `project_id = global`. Cascades into broken session lists
  (`Session.list` filters by project), broken SPA "review changes"
  widget (reads `project.vcs`), and broken workspace-scoped
  `--continue`. The patch hunk runs `Project.fromDirectory(info.directory)`
  after `WorkspaceAdapterRuntime.create` resolves and UPDATEs the
  workspace row's `project_id` to the git-root OID. ~25 LOC TS in the
  bearer-auth patch. Upstream-PR-worthy.

- **Plugin file is `.ts`, not `.ts.in`, with constants block
  discipline.** Placeholders live inside string literals at a single
  dedicated constants block near the top of `factory-adapter.ts` --
  syntactically valid TS, so tsc/biome work directly. `@TOKEN@`
  patterns must NEVER appear anywhere else in the file (comments, tag
  comments, JSDoc examples, string content outside the constants
  block): `pkgs.replaceVars`'s `checkPhase` fails the build on any
  leftover `@xxx@` pattern, regardless of context.

- **Plugin typecheck via flake check.** `checks.factory-plugin-typecheck`
  runs `tsc --noEmit` against the plugin with `@opencode-ai/plugin` +
  `@types/node` resolved offline via `buildNpmPackage`. Catches
  WorkspaceAdapter API drift on every `nix flake check`. See
  `.claude/rules/010-plugin.md`.

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
cmd/kfactory/         Go CLI (auth / list / attach / dispatch / delete)
completions/_kfactory zsh completion (auto-installed via $out/share/zsh/site-functions)
plugin/               factory-adapter.ts + package.json + tsconfig.json
patches/              opencode-bearer-and-routing.patch
                      + opencode-kfactory-refresh.patch
                      + oauth2-proxy-pkce-no-secret.patch
default.nix           kfactory CLI build (empty endpoint defaults; ldflags-injectable)
flake.nix             packages.kfactory / lib.mkFactoryAdapter / patches.* / checks.*
.claude/rules/        plugin editing + patch re-diff workflows
```

Wiring (reverse proxy config, oauth2-proxy systemd unit, host/VM
config, secrets management, opencode.jsonc, permission ruleset,
prompts) is the consumer's responsibility. See the README for a
`nixosConfigurations` sketch.
