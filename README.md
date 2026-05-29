# kfactory

Run one `opencode serve` behind an OIDC reverse proxy as a personal
coding-agent factory: every repo gets its own workspace, sessions
persist across restarts, and the operator drives everything from
`kfactory` on the CLI.

Not a turnkey deployment -- it's the missing pieces (CLI, plugin, source
patches) you'd otherwise have to write yourself to put opencode behind
a public OIDC proxy with one workspace per repo. You bring the proxy,
the host, the runtime config; kfactory provides the seams.

## What the operator actually does

```
$ kfactory auth login              # OIDC device-flow
kfactory: open https://auth.example.com/ui/v2/login/device?user_code=ABCD-1234
kfactory: code ABCD-1234

$ kfactory dispatch git@github.com:acme/widget.git "fix the flaky drag-drop test"
kfactory: workspace wrk_e3d1150e2001YHvzDNcrSNPSxV
kfactory: dispatched. attach with: kfactory attach wrk_e3d1150e2001YHvzDNcrSNPSxV

$ kfactory list                    # workspaces, most recent first
$ kfactory attach 1                # drops into opencode TUI for that workspace
$ kfactory delete <id|slug|index>
$ kfactory tick 7a3f               # scheduled task: config at /etc/kfactory/scheduled/7a3f.json
$ kfactory tick wrk_e3d115... \    # ad-hoc nudge: exact workspace ID or 4-hex slug suffix
    --prompt "resume your work"
```

Agent loops run server-side and survive client disconnect; close the
TUI, walk away, attach back later. The `permission` ruleset pauses the
agent before any destructive action (commit, push, sudo) so the
operator stays in the loop without babysitting.

## Architecture

```
[ reverse proxy ]              (TLS + OIDC, cookie OR bearer JWT)
      |
      v                        Authorization stripped before forward
[ opencode serve ]             single process, FactoryAdapter plugin
      |                        per-request workspace dispatched in-process
      v
[ workspace's project / session / tools ]
```

One opencode process owns every workspace; per-request dispatch is
in-process via opencode's native experimental workspace machinery.
Workspace-to-workspace isolation is a SOFT boundary (shared UID, netns,
FS); the threat model is "trusted agent, fault containment," NOT
untrusted-code defense. See `docs/spec.md` for the full picture and
the v1→v2 pivot rationale.

## Scope

You bring:
- the reverse proxy + OIDC integration (kfactory is OIDC-agnostic;
  tested against Zitadel),
- the host (VM/microvm, sshd-as-clone-identity, systemd, secrets),
- runtime config (`opencode.jsonc`, permission ruleset, prompts),
- OIDC endpoint defaults via runtime env vars or operator-typed on first
  `kfactory auth login`.

kfactory does NOT ship a Caddyfile, docker-compose, agent prompts,
model selection, or secrets management. kfactory DOES ship two narrow
NixOS modules -- `scheduledTasks` (timer-driven `kfactory tick`) and
`recovery` (opencode-serve restart lifecycle: opencode-heal +
opencode-sync-kick + recovery-sweep) -- because the systemd unit
generation those describe is intrinsically NixOS-shaped and the
operator-facing schema is the natural fit. Everything else stays
module-free.

## Consuming

Flake-only. The default output is a unified runtime: `kfactory` CLI,
patched `opencode`, bundled plugins, `/loop` commands, and the base
opencode JSONC config in one derivation.

**Unified runtime**:

```nix
{pkgs, inputs, ...}: let
  system = pkgs.stdenv.hostPlatform.system;
  factory = inputs.kfactory.packages.${system}.kfactory;
  kfactoryEnv = {
    KFACTORY_SERVER = "https://factory.example.com";
    KFACTORY_OIDC_ISSUER = "https://auth.example.com";
    KFACTORY_OIDC_CLIENT_ID = "YOUR_OIDC_CLIENT_ID";
    KFACTORY_OIDC_AUDIENCE = "YOUR_OIDC_AUDIENCE";
  };
in {
  environment.systemPackages = [
    factory
    inputs.kfactory.packages.${system}.oauth2-proxy-kfactory
  ];

  # Used by `kfactory auth login` unless flags are passed explicitly.
  environment.sessionVariables = kfactoryEnv;

  systemd.services.opencode-kfactory = {
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    environment = kfactoryEnv // {
      # Optional full config replacement. If set, this file must include
      # the desired plugin list and /loop command entries itself.
      # OPENCODE_CONFIG = "/etc/opencode/opencode.jsonc";
    };
    serviceConfig = {
      ExecStart = "${factory}/bin/opencode serve --hostname 127.0.0.1 --port 4096";
      Restart = "always";
    };
  };
}

# Default OPENCODE_CONFIG is generated from nix/shared/opencode-kfactory-base.jsonc;
# set OPENCODE_CONFIG to replace the bundled plugins/commands config.
```

There is intentionally no public CLI-only package; the `kfactory` binary
ships with its matched opencode/config/plugin closure.

Public package API is intentionally small: `packages.${system}.kfactory`
(`default` alias) and `packages.${system}.oauth2-proxy-kfactory`. The
opencode patch stack, plugin derivations, lifecycle helpers, and regression
images are internal implementation details exercised through flake checks.

The ntfy plugin reads its config from
`$XDG_CONFIG_HOME/opencode/notification-ntfy.json` (per-event enable
toggles, shorthand-duration `notifyAfter` debounce, ntfy topic + token).

## Plugins

Three kfactory-owned plugins live under `plugins/<name>/`:

- **`kfactory-adapter`** -- opencode WorkspaceAdapter making one
  `opencode serve` host per-repo workspaces via `InstanceStore.provide`
  in-process. Reads `KFACTORY_ADAPTER_GIT` / `KFACTORY_ADAPTER_OPENSSH_SSH`
  / `KFACTORY_ADAPTER_WORKSPACES_DIR` from env with PATH-resolved defaults.
- **`ntfy`** -- ntfy.sh push notifications for idle (`session.status` with
  `status.type === "idle"`), `session.error`, `permission.asked`. Per-event `notifyAfter` shorthand-
  duration ("3s", "5m", "1h30m") latest-wins debounce window. Notifications
  fire whether or not an operator is connected through TUI or web; reconnecting
  is not a cancel signal. Carved out of
  [lannuttia/opencode-ntfy.sh](https://github.com/lannuttia/opencode-ntfy.sh) +
  [lannuttia/opencode-notification-sdk](https://github.com/lannuttia/opencode-notification-sdk)
  (both MIT; full notice + copyright inlined at the top of every
  vendored source file).
- **`loop`** -- `/loop` slash command. Auto-continues the current root
  session until the exact sentinel appears as the last non-empty assistant
  line. `--max N` caps iterations; `--sentinel "<exact phrase>"` overrides
  the default sentinel. State lives outside the workspace tree at
  `$XDG_STATE_HOME/kfactory-loop/<workspace-hash>.json`; `/loop-stop` stops it.
  Pattern inspired by
  [charfeng1/opencode-ralph-loop](https://github.com/charfeng1/opencode-ralph-loop) (MIT).

Plugins are bundled into `packages.${system}.kfactory`, not exposed as public
flake outputs. Adding a new plugin under `plugins/<name>/` and a corresponding
entry in `pluginSrcs` registers it as an internal build + typecheck CI gate.

### Third-party plugins packaged through Nix

Plugins kfactory doesn't maintain source for also live under
`plugins/<name>/` but with a different shape: only `package.json` +
`package-lock.json` (no `src/`, no `tsconfig.json`). The carrier
manifest declares the npm package + version + locks the transitive
resolution; the actual source lands in `$out` of an internal package at
build time via `mkThirdPartyPlugin`. Adding an entry to
`thirdPartyPluginSrcs` in `flake.nix` auto-registers the
internal package, a `factory-<name>-smoke` flake check, and the
regression-tests opencode.json plugin-list entry -- same auto-reg model as
kfactory-owned plugins, just one extra step (carrier + lockfile generation,
which needs network and so happens out-of-sandbox).
Workflow: `.claude/rules/050-third-party-nix-plugins.md`.

- **`opencode-pty`** -- [JosXa/opencode-pty](https://github.com/JosXa/opencode-pty)
  (MIT). PTY tools for the LLM (`pty_spawn`, `pty_write`, `pty_read`,
  `pty_list`, `pty_kill`) so it can run background processes, dev
  servers, watch modes, and REPLs within a dispatched session. Snapshot
  tools are also packaged. Carrier lives at `plugins/opencode-pty/`;
  `bun-pty`'s prebuilt platform binaries ship in its npm tarball so
  no Cargo toolchain is required at install time. The unified runtime loads it
  by default.
  The Web UI feature (`/pty-open-background-spy`) is opt-in; do not bind
  `PTY_WEB_HOSTNAME` beyond loopback without adding authentication.

## Scheduled tasks + recovery (NixOS modules)

Two opt-in modules at `kfactory.nixosModules.{scheduledTasks,recovery}`.
Both ride on the operator's existing opencode-serve systemd unit;
neither ships its own.

```nix
imports = [
  inputs.kfactory.nixosModules.scheduledTasks
  inputs.kfactory.nixosModules.recovery
];

services.kfactory.scheduledTasks = {
  enable = true;
  package = pkgs.kfactory;           # operator's overridden CLI
  user    = "opencode";              # owns ~/.config/kfactory/auth.json
  # 7a3f = "weekly dep upgrades" (document the mapping in your config)
  tasks."7a3f" = {
    schedule           = "Mon *-*-* 09:00:00";
    repo               = "git@github.com:acme/widget.git";
    mode               = "continue";  # continue | skip-if-dirty | skip-if-exists
    initialPrompt      = "Check for dep upgrades and open a PR.";
    continuationPrompt = "Resume the dep-bump work.";
  };
};

services.kfactory.recovery = {
  enable   = true;
  # Keep CLI + heal/sync hooks from one package; the heal queue couples them.
  package  = inputs.kfactory.packages.${pkgs.system}.kfactory;
  user     = "opencode";
  opencodeServiceName = "opencode";              # operator's unit name
  opencodeDB          = "/var/lib/opencode/.local/share/opencode/opencode.db";
  opencodeBaseURL     = "http://10.0.0.2:4096";  # internal, NOT proxy-fronted
};
```

`scheduledTasks` generates one `systemd.timer` + `systemd.service`
per task; the service runs `kfactory tick <id>` as the operator's
user. Each task's id (`7a3f` above) maps to the stable workspace ID
`wrk_kfactory_7a3f`, so re-firing the same task finds the same workspace
across reboots without using workspace names as identity.

@WARNING: scheduled-task workspace creation must go through `kfactory tick`.
The CLI owns the stable workspace ID and repairs incomplete first runs by
checking for `initialPrompt` in opencode state before continuation modes apply.

`recovery` attaches three hooks to the opencode-serve unit via a
drop-in:

- **ExecStartPre** runs `opencode-heal <DB>` -- sweeps zombie
  assistant turns (`time.completed IS NULL`), marks them
  `finish=interrupted-by-restart`, AND writes the affected
  workspace IDs to `/run/kfactory/recovery-queue.json` so the
  recovery sweep only touches workspaces that actually had a
  mid-flight turn.
- **ExecStartPost** runs `opencode-sync-kick --base <URL>` --
  pokes the per-workspace status sync that opencode otherwise
  only triggers on SPA init.
- **ExecStartPost** runs `kfactory-recovery-sweep` -- reads the
  queue file, runs `kfactory tick <workspace-id> --prompt
  <recovery-prompt>` per workspace. The agent decides how to resume.

`kfactory tick` is the unified verb both paths share: scheduled
fires (`wrk_kfactory_<task-id>`, mode-driven branching) and ad-hoc
nudges (workspace ID or 4-hex slug suffix + `--prompt`). Unlike
`attach` and `delete`, `tick` never resolves by list index.

## CI

`nix flake check` builds public packages, internal plugin/component
derivations, `factory-*` checks (patch-application, opencode typecheck, zsh
completion parse), and per-plugin typechecks (`<name>-typecheck`). Adding a
new internal component, plugin, or check auto-registers as a gate. List with
`nix eval --json .#checks.x86_64-linux --apply 'attrs: builtins.attrNames attrs'`.

## License

AGPLv3. See `LICENSE`.
