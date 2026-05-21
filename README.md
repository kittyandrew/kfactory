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
- OIDC endpoint defaults at build time via ldflags or operator-typed on
  first `kfactory auth login`.

kfactory does NOT ship a Caddyfile / NixOS module / docker-compose,
agent prompts, model selection, or secrets management.

## Consuming

Flake-only. Two styles depending on whether you want kfactory to pin
opencode + oauth2-proxy for you.

**Pre-wrapped** (single deployment):

```nix
environment.systemPackages = [
  (kfactory.packages.x86_64-linux.kfactory.overrideAttrs (old: {
    # Operators can override on first login; ldflags bake the defaults.
    ldflags = (old.ldflags or []) ++ [
      "-X main.defaultServer=https://factory.example.com"
      "-X main.defaultIssuer=https://auth.example.com"
      "-X main.defaultClientID=YOUR_OIDC_CLIENT_ID"
      "-X main.defaultAudience=YOUR_OIDC_AUDIENCE"
    ];
  }))
  (kfactory.packages.x86_64-linux.opencode-kfactory.overrideAttrs (old: {
    # Plugins read config from env vars. Wrap opencode with absolute
    # store paths for predictability (no PATH dependency at runtime).
    postFixup = (old.postFixup or "") + ''
      wrapProgram $out/bin/opencode \
        --set KFACTORY_ADAPTER_GIT "${pkgs.git}/bin/git" \
        --set KFACTORY_ADAPTER_OPENSSH_SSH "${pkgs.openssh}/bin/ssh" \
        --set KFACTORY_ADAPTER_WORKSPACES_DIR "/var/lib/factory/workspaces"
    '';
  }))
  kfactory.packages.x86_64-linux.oauth2-proxy-kfactory
];

# Generate opencode.json from the NixOS module so the plugin store paths
# are interpolated at evaluation time. opencode's PluginLoader accepts
# absolute directory paths and resolves package.json's exports["./server"]
# to find the entrypoint -- no `/etc` indirection needed.
environment.etc."opencode/opencode.json".text = builtins.toJSON {
  plugin = [
    "${kfactory.plugins.x86_64-linux.kfactory-adapter}"
    "${kfactory.plugins.x86_64-linux.ntfy}"
    "${kfactory.plugins.x86_64-linux.loop}"
  ];
  # ... the rest of your opencode config (permission, providers, etc.)
};

# Loop plugin slash commands -- wire each command markdown file from
# the plugin's flake output into opencode's command dir. Plugins do not
# auto-install commands; this keeps the workspace-vs-global boundary
# explicit.
environment.etc."opencode/command/loop.md".source =
  "${kfactory.plugins.x86_64-linux.loop}/commands/loop.md";
environment.etc."opencode/command/loop-stop.md".source =
  "${kfactory.plugins.x86_64-linux.loop}/commands/loop-stop.md";
```

The ntfy plugin reads its config from
`$XDG_CONFIG_HOME/opencode/notification-ntfy.json` (per-event enable
toggles, shorthand-duration `notifyAfter` debounce, ntfy topic + token).

**Raw patches** (bring your own opencode/oauth2-proxy pin):

```nix
opencodePkg = opencode.packages.x86_64-linux.default.overrideAttrs (old: {
  patches = (old.patches or []) ++ [
    kfactory.patches.opencode-bearer-and-routing      # required
    kfactory.patches.opencode-session-subscribers     # optional; only if you use plugins/ntfy
    kfactory.patches.opencode-kfactory-refresh        # optional; only if you use `kfactory attach`
  ];
});
```

⚠️ Patch order matters and is fixed: the refresh patch is line-pinned
against the post-apply hashes of the patches above it. Don't swap them.
Raw-patches consumers must also set
`OPENCODE_EXPERIMENTAL_WORKSPACES=true` in opencode's runtime env (the
`opencode-kfactory` wrapper does this for you).

## Plugins

Three plugins live under `plugins/<name>/`:

- **`kfactory-adapter`** -- opencode WorkspaceAdapter making one
  `opencode serve` host per-repo workspaces via `InstanceStore.provide`
  in-process. Reads `KFACTORY_ADAPTER_GIT` / `KFACTORY_ADAPTER_OPENSSH_SSH`
  / `KFACTORY_ADAPTER_WORKSPACES_DIR` from env with PATH-resolved defaults.
- **`ntfy`** -- ntfy.sh push notifications for `session.idle`,
  `session.error`, `permission.asked`. Per-event `notifyAfter` shorthand-
  duration ("3s", "5m", "1h30m") debounce window; if any operator attaches
  via TUI or web during the window, the pending notification is cancelled
  (always-on, not configurable). Carved out of
  [lannuttia/opencode-ntfy.sh](https://github.com/lannuttia/opencode-ntfy.sh) +
  [lannuttia/opencode-notification-sdk](https://github.com/lannuttia/opencode-notification-sdk)
  (both MIT; full notice + copyright inlined at the top of every
  vendored source file).
- **`loop`** -- `/loop` slash command. Auto-continues the current
  session until a user-defined sentinel string appears as the LAST
  non-empty line of the assistant's response. Configurable via
  `--max N` (iteration cap, default 100, range [1, 10000]) and
  `--sentinel "<exact phrase>"` (last-line trimmed equality,
  case-sensitive; default `<promise>EXHAUSTIVELY COMPLETED</promise>`).
  Mid-response mentions of the sentinel do NOT terminate -- only a
  clean trailing match does. State persisted at
  `$XDG_STATE_HOME/kfactory-loop/<workspace-hash>.json`
  (outside the workspace tree). Session captured from `ToolContext.sessionID`
  at start time; subagent idles filtered out. Slash command markdown is
  shipped as part of the plugin's flake output -- consumers wire it via
  NixOS module (no auto-install). No coupling to the
  session-subscribers patch -- the loop runs on `session.idle` alone.
  Pattern inspired by
  [charfeng1/opencode-ralph-loop](https://github.com/charfeng1/opencode-ralph-loop) (MIT).

Each plugin is a `flake.nix` output (`plugins.${system}.<name>`).
Adding a new plugin under `plugins/<name>/` and a corresponding entry
in `pluginSrcs` registers it automatically as a build + typecheck CI gate.

## CI

`nix flake check` builds every `packages.${system}.*` + every
`plugins.${system}.*` plus a set of `factory-*` checks (patch-application,
opencode typecheck, zsh completion parse) and per-plugin typechecks
(`<name>-typecheck`). Adding a new package, plugin, or check
auto-registers as a gate. List with
`nix eval --json .#checks.x86_64-linux --apply 'attrs: builtins.attrNames attrs'`.

## License

AGPLv3. See `LICENSE`.
