# kfactory

Opencode factory deployment toolkit. Three artifacts you'd otherwise build
yourself if you wanted opencode behind OIDC with workspace-per-repo
dispatch:

- **`kfactory`** -- Go CLI (auth login / list / attach / dispatch / delete).
  OIDC device-flow + POSIX-flock-coordinated refresh. ~1.2k LOC, no NixOS
  assumptions, single static binary.
- **`factory-adapter.ts`** -- opencode `WorkspaceAdapter` plugin (~185 LOC).
  Returns `type:"local"` so opencode's `InstanceStore.provide({directory})`
  dispatches each workspace in-process. One `opencode serve` per host,
  no per-workspace processes.
- **`patches/`** -- three source patches:
  - `opencode-bearer-and-routing.patch` -- adds `--bearer` / `--workspace`
    CLI flags to `opencode attach`, workspace-routing header fallback
    for non-GET requests, and post-`adapter.create` project-id
    re-resolve. ~290 LOC against opencode v1.15.4; the upstreamable
    subset.
  - `opencode-kfactory-refresh.patch` -- layered on top: subprocess
    token refresh via `kfactory auth refresh`, shared file cache for
    the bearer, TUI toast subscription for refresh hints. ~370 LOC;
    kfactory-specific deployment glue.
  - `oauth2-proxy-pkce-no-secret.patch` -- verbatim
    [oauth2-proxy#3168](https://github.com/oauth2-proxy/oauth2-proxy/pull/3168);
    lets the OIDC app run without a client_secret (PKCE-only).

Plus `docs/spec.md` -- portable architectural intent + decisions log,
including the v1->v2 pivot rationale (workers-as-scopes -> single-process
in-process dispatch, ~500 LOC deleted).

## What this is NOT

- **Not** a deployment scaffold. There's no Caddyfile here, no NixOS
  module, no docker-compose. Consumers ship the auth proxy + reverse proxy
  + microvm/host config themselves.
- **Not** prompts / agent personas / `opencode.jsonc`. The runtime
  config is the consumer's call.
- **Not** secrets management. kfactory's defaults are empty; consumers wire
  endpoints via ldflags or operator-typed flags on first login.

## Consuming from a NixOS flake

Two consumption styles — pre-wrapped (ergonomic) or raw (composable).

### Pre-wrapped (recommended for single-deployment use)

`packages.opencode-kfactory` and `packages.oauth2-proxy-kfactory` are
kfactory's pinned upstreams with our patches applied + verified in CI.
Use these when you don't need to bump opencode/oauth2-proxy independently:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    kfactory.url = "github:kittyandrew/kfactory";
  };

  outputs = {nixpkgs, kfactory, ...}: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({pkgs, ...}: let
          # CLI binary with your endpoints baked in via ldflags.
          kfactoryCli = kfactory.packages.x86_64-linux.kfactory.overrideAttrs (old: {
            ldflags =
              (old.ldflags or [])
              ++ [
                "-X main.defaultServer=https://factory.example.com"
                "-X main.defaultIssuer=https://auth.example.com"
                "-X main.defaultClientID=YOUR_OIDC_CLIENT_ID"
                "-X main.defaultAudience=YOUR_OIDC_AUDIENCE"
              ];
          });

          # Plugin file with deployment-specific paths substituted.
          factoryAdapter = kfactory.lib.mkFactoryAdapter {
            inherit pkgs;
            gitBin = "${pkgs.git}/bin/git";
            openSSHBin = "${pkgs.openssh}/bin/ssh";
            workspacesDir = "/var/lib/factory/workspaces";
          };
        in {
          environment.systemPackages = [
            kfactoryCli
            kfactory.packages.x86_64-linux.opencode-kfactory
            kfactory.packages.x86_64-linux.oauth2-proxy-kfactory
          ];
          environment.etc."opencode/plugin/factory-adapter.ts".source = factoryAdapter;
          # You bring the rest: opencode.jsonc, Caddyfile, oauth2-proxy
          # systemd unit, sshd host-key share, ...
        })
      ];
    };
  };
}
```

### Raw patches (stack with your own / pin independently)

`patches.opencode-bearer-and-routing`, `patches.opencode-kfactory-refresh`,
and `patches.oauth2-proxy-pkce-no-secret` are file-path outputs you can
stack with your own patches, or apply to a different opencode/oauth2-proxy
version than kfactory pins. The opencode pair is split so consumers
who don't use kfactory's auth-cache flow can take just the upstreamable
half. Note: CI verifies the patches against kfactory's pinned opencode
source -- if your version drifts, expect to re-diff per
`.claude/rules/020-patches.md`.

```nix
opencodePkg = opencode.packages.x86_64-linux.default.overrideAttrs (old: {
  patches = (old.patches or []) ++ [
    kfactory.patches.opencode-bearer-and-routing
    kfactory.patches.opencode-kfactory-refresh # optional; subprocess refresh
    ./my-local-tweak.patch
  ];
});
oauth2ProxyPkg = pkgs.oauth2-proxy.overrideAttrs (old: {
  patches = (old.patches or []) ++ [kfactory.patches.oauth2-proxy-pkce-no-secret];
});
```

## CI

`nix flake check` builds every `packages.${system}.*` output (registered
as checks in `flake.nix`) plus the bespoke `factory-*` checks defined
in the `checks` attrset. Adding a new package or check auto-registers
it as a CI gate -- no workflow editing needed.

Currently the bespoke checks cover patch-application (`*-patch-applies`),
TypeScript drift against the plugin SDK + against the patched opencode
source (`factory-plugin-typecheck`, `factory-opencode-typecheck`), zsh
completion load (`factory-completion-loads`), and plugin
`@TOKEN@`-placeholder discipline (`factory-plugin-token-discipline`).
The authoritative list lives in `flake.nix`; query at runtime with
`nix eval --json .#checks.x86_64-linux --apply 'attrs: builtins.attrNames attrs'`.

## Layout

```
cmd/kfactory/           Go CLI source (binary name: kfactory)
completions/_kfactory   zsh completion (auto-installed by Nix into share/zsh/site-functions)
plugin/                 factory-adapter.ts + package.json + tsconfig.json
patches/                opencode-bearer-and-routing.patch
                        + opencode-kfactory-refresh.patch
                        + oauth2-proxy-pkce-no-secret.patch
docs/spec.md            architecture intent + decisions log
flake.nix               packages.kfactory, lib.mkFactoryAdapter, patches.*, checks.*
```

## License

AGPLv3. See `LICENSE`.
