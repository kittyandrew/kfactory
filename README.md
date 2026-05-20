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
  kfactory.packages.x86_64-linux.opencode-kfactory       # patched + env-wrapped
  kfactory.packages.x86_64-linux.oauth2-proxy-kfactory
];
environment.etc."opencode/plugin/factory-adapter.ts".source =
  kfactory.lib.mkFactoryAdapter {
    inherit pkgs;
    gitBin = "${pkgs.git}/bin/git";
    openSSHBin = "${pkgs.openssh}/bin/ssh";
    workspacesDir = "/var/lib/factory/workspaces";
  };
```

**Raw patches** (bring your own opencode/oauth2-proxy pin):

```nix
opencodePkg = opencode.packages.x86_64-linux.default.overrideAttrs (old: {
  patches = (old.patches or []) ++ [
    kfactory.patches.opencode-bearer-and-routing      # required
    kfactory.patches.opencode-kfactory-refresh        # optional; only if you use `kfactory attach`
  ];
});
```

⚠️ Patch order matters: the refresh patch is line-pinned against the
bearer-and-routing patch's post-apply hashes. Don't swap them.
Raw-patches consumers must also set
`OPENCODE_EXPERIMENTAL_WORKSPACES=true` in opencode's runtime env (the
`opencode-kfactory` wrapper does this for you).

## CI

`nix flake check` builds every `packages.${system}.*` plus a set of
`factory-*` checks (patch-application, plugin + opencode typecheck, zsh
completion parse, plugin-placeholder discipline). Adding a new package
or check auto-registers as a gate. List with
`nix eval --json .#checks.x86_64-linux --apply 'attrs: builtins.attrNames attrs'`.

## License

AGPLv3. See `LICENSE`.
