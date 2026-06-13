# kfactory regression test environment

Dockerized end-to-end environment for testing the kfactory CLI, plugins,
and opencode integration without the production OIDC stack. Three
Nix-built containers, one Docker bridge network.

```
   host                              docker network: kfactory-devnet
   ┌─────────────────────┐
   │ nix run .#dev-up    │           ┌──────────────────────────┐
   │ docker exec -it ... │     ──>   │ kfactory-client          │
   └─────────────────────┘           │   kfactory + opencode    │
       │                             │   pre-staged auth.json   │
       │ http://localhost:8080       │   /srv/test-repo.git     │
       ▼                             └─────────┬────────────────┘
   ┌─────────────────────┐                     │
   │ ntfy web UI         │ <─── HTTP POST ─────┤
   └─────────────────────┘                     │
       ▲                                       ▼
       │ http://kfactory-ntfy/...   ┌──────────────────────────┐
       └──────────────────────────  │ kfactory-opencode        │
                                    │   opencode serve :4096   │
                                    │   3 plugins loaded       │
                                    │   /srv/test-repo.git     │
                                    └──────────────────────────┘
```

## What it tests

- `kfactory dispatch` end-to-end (POST → adapter clone → session create → prompt).
- `kfactory list` (workspace enumeration + ordering + branch enrichment).
- `kfactory attach` reference resolution (id / slug / index ordering).
- Session isolation (workspace-scoped `/session` + `/experimental/session`),
  `/sync/start` workspace targeting, live SSE event delivery.
- `kfactory tick` scheduled-task create-on-miss, modes, and concurrent
  first-run convergence (8 racers → exactly one initial prompt).
- `ntfy` plugin's idle event → debounce-wait → POST to ntfy.
- `opencode-heal` + recovery-sweep round trip against a staged stuck
  assistant turn (queue emit, row marking, sync-kick, prompt injection).

What it does **NOT** test:

- OIDC device-flow login (`kfactory auth login`). The regression tests skip
  this entirely by pre-staging a bogus token. To test real OIDC, deploy
  against an actual Zitadel (or other) IdP.
- oauth2-proxy / reverse proxy layer. opencode is reached directly.
- Workspace-to-workspace isolation (single-process, single-UID, etc.
  — same as production at single-operator scale).
- Anything requiring real assistant turns or model tool calls: the
  environment ships NO LLM provider, so the `/loop` sentinel run, the
  `permission.asked` notification, and the live opencode-pty phases are
  skipped in the runner (each carries an `@TODO` for a future fake-LLM
  provider). Their contracts are covered by plugin unit tests,
  `nix/unit/opencode/*`, and the `nix/replay` fixtures instead.

## Prerequisites

- Docker (or Docker-compatible runtime: podman with `alias docker=podman`).
- Nix with flakes enabled. The regression tests are invoked via `nix run`.
- ~3 GB of disk (Nix builds + Docker images + opencode's bundled bun runtime).

## Lifecycle

| Command | What it does |
|---|---|
| `nix run .#dev-up` | Build both OCI images, load into Docker, create network + volume, start ntfy + opencode + kfactory-client. Waits for each to be healthy. |
| `nix run .#dev-down` | Stop + remove containers. **Preserves** the named volume (opencode SQLite + workspaces persist). |
| `nix run .#dev-clean` | Stop containers + remove volume + remove network + remove images. Full wipe. |
| `nix run .#dev-test` | Scripted validation sequence (run AFTER `dev-up`). |

## Manual test walkthrough

```bash
# 1. Boot the regression tests.
nix run .#dev-up
# ... waits for ntfy + opencode + kfactory-client ...

# 2. Open ntfy in your browser BEFORE dispatching, so you see
#    notifications arrive in real time.
xdg-open http://localhost:8080/kfactory-regression  # or whatever opener

# 3. Drop into the kfactory-client container.
docker exec -it kfactory-client bash

# Inside the container (everything is pre-configured):
$ kfactory auth status
kfactory auth status
  server:    http://kfactory-opencode:4096
  issuer:    http://regression-fake-idp
  ...
  access:    valid, expires in [...]
  refresh:   present
  ...
# (The pre-staged token has a far-future expiry; auth status confirms
#  it's "valid" and the server is reachable. No actual OIDC happens.)

$ kfactory list
kfactory: no workspaces. create one with `kfactory dispatch <repo-url>`

# 4. Dispatch three workspaces. Each creates a workspace + session +
#    fires a prompt asynchronously.
$ kfactory dispatch file:///srv/test-repo.git "say hi and stop"
kfactory: creating workspace for file:///srv/test-repo.git
kfactory: workspace wrk_xxx (test-repo--<slug>)
kfactory: opening session
kfactory: session ses_yyy
kfactory: sending prompt (async)
kfactory: dispatched. attach with: kfactory attach wrk_xxx
wrk_xxx

$ kfactory dispatch file:///srv/test-repo.git "echo done"
$ kfactory dispatch file:///srv/test-repo.git "list files"
$ kfactory list
#  ID                                  NAME                       LAST USED
1  wrk_<id1>                           test-repo--<slug1>         <ts>
2  wrk_<id2>                           test-repo--<slug2>         <ts>
3  wrk_<id3>                           test-repo--<slug3>         <ts>

# 5. Attach. THIS is the workflow you're debugging. Verify the TUI
#    opens against the correct workspace + session.
$ kfactory attach 1
# (opencode TUI launches inside the container; you see it because of
#  `docker exec -it`. The TUI should open against wrk_<id1>'s most
#  recent session, NOT some other workspace.)

# 6. Test /loop. Inside the TUI:
/loop --max 3 --sentinel "<promise>EXHAUSTIVELY COMPLETED</promise>" count to three then stop

# After 2-3 turns the agent emits the sentinel, the loop terminates.
# Verify state file is cleared:
$ docker exec kfactory-client ls /root/.local/state/kfactory-loop/
# (Empty = loop completed.)

# 7. Watch ntfy: each session.idle fires a notification after a
#    3-second wait. The ntfy plugin's subscriber-suppression logic
#    only cancels pending notifications when an SSE client is
#    attached to the workspace; during dev-test nothing attaches,
#    so the count stays at 0 and notifications go through. Browser
#    view at http://localhost:8080/kfactory-regression shows the messages.

# 8. Tear down.
nix run .#dev-down       # stop, preserve volume
# OR
nix run .#dev-clean      # full wipe
```

## Configuration knobs (`nix/e2e/configs/`)

| File | Purpose |
|---|---|
| `opencode-base.json` | Non-plugin opencode config (permissive `permission` for dev). The packaged unified runtime supplies the plugin list used by the regression image. |
| `notification-ntfy.json` | ntfy plugin config: topic `kfactory-regression`, server `http://kfactory-ntfy:80`, `notifyAfter: 3` seconds on session.idle. Subscriber-aware cancellation is non-configurable and ALWAYS on -- there's no opt-out knob. The regression tests see notifications fire because dev-test does not attach an SSE subscriber. |
| `auth.json` | Bogus kfactory tokens with far-future expiry. `ensureFresh` accepts them and skips the OIDC refresh path. |

## Debugging the kfactory attach bug

When you reproduce the wrong-workspace / wrong-session behavior, capture
the request the CLI actually sends:

```bash
# Tail opencode's stderr in real time (workspace-routing logs fire here):
docker logs -f kfactory-opencode

# In another shell, drive kfactory:
docker exec -it kfactory-client kfactory attach <ref>
```

The workspace-routing patch logs the workspace ID it dispatches against
in `workspace-routing.ts:planRequest`; if the resolved workspace
disagrees with what `kfactory list` shows for that ref, the bug is in
the CLI's resolution path (`cmd/kfactory/client.go:resolveWorkspace`).
If they agree but the TUI opens a different session, the bug is on the
opencode side (`tui()` + `validateSession` + `ProjectProvider`).

## Bumping image pins

The ntfy upstream image is the public `binwiederhier/ntfy:latest` -- not
pinned by digest yet because the regression tests are dev-only. To pin (and avoid
silent breakage on a future bump):

```bash
docker pull binwiederhier/ntfy:latest
docker inspect binwiederhier/ntfy:latest | jq '.[0].RepoDigests'
# Paste the @sha256:... into nix/scripts/dev-up.nix
```

## Layout

```
nix/e2e/
  README.md                  -- this file
  configs/
    opencode-base.json       -- non-plugin opencode config (plugin list generated by Nix)
    notification-ntfy.json   -- ntfy plugin config (3s wait, free of OIDC)
    auth.json                -- pre-staged bogus kfactory tokens
  dev-env.nix                -- central config (container names, ports, network)
  opencode-image.nix         -- builds kfactory-opencode:dev OCI image
  kfactory-client-image.nix  -- builds kfactory-client:dev OCI image
  test-repo.nix              -- shared bare git repo, mounted in both images
  regression-runner/
    main.go                  -- Go regression runner; owns behavioral assertions

nix/scripts/
  default.nix                -- dev app registry
  dev-up.nix                 -- spin up
  dev-down.nix               -- spin down (preserve volume)
  dev-clean.nix              -- wipe everything
  dev-test.nix               -- runs the Go validation sequence
```
