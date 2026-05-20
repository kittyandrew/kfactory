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
- **`patches/`** -- two source patches:
  - `opencode-bearer-auth.patch` -- adds `--bearer` / `--workspace` CLI
    flags to `opencode attach`, plumbing for subprocess token refresh
    via `kfactory auth refresh`, workspace-routing header fallback for
    non-GET requests, and post-`adapter.create` project-id re-resolve.
    ~525 LOC against opencode v1.15.4. Roughly half is upstream-PR-worthy.
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

`patches.opencode-bearer-auth` and `patches.oauth2-proxy-pkce-no-secret`
are file-path outputs you can stack with your own patches, or apply to
a different opencode/oauth2-proxy version than kfactory pins. Note: CI
verifies the patches against kfactory's pinned opencode source -- if
your version drifts, expect to re-diff per `.claude/rules/020-patches.md`.

```nix
opencodePkg = opencode.packages.x86_64-linux.default.overrideAttrs (old: {
  patches = (old.patches or []) ++ [
    kfactory.patches.opencode-bearer-auth
    ./my-local-tweak.patch
  ];
});
oauth2ProxyPkg = pkgs.oauth2-proxy.overrideAttrs (old: {
  patches = (old.patches or []) ++ [kfactory.patches.oauth2-proxy-pkce-no-secret];
});
```

## CI

`nix flake check` builds every `packages.${system}.*` output (registered
as checks in `flake.nix`) plus two explicit checks:

- `kfactory` -- the CLI binary build (Go).
- `opencode-kfactory` -- kfactory's pinned opencode with the bearer-auth
  patch applied (full bun bundle).
- `oauth2-proxy-kfactory` -- kfactory's nixpkgs oauth2-proxy with the
  PKCE-no-secret patch applied (Go compile).
- `factory-plugin-typecheck` -- `tsc --noEmit` against the published
  `@opencode-ai/plugin` types. Catches `WorkspaceAdapter` API drift on
  plugin SDK releases.
- `factory-opencode-patch-applies` -- `patch -p1 --dry-run` of the
  bearer-auth patch against the locked opencode source. Redundant with
  `opencode-kfactory` building but several orders of magnitude faster;
  gives fast-fail feedback on line-number drift.

Adding a new package to the flake auto-registers it as a CI gate -- no
workflow editing needed.

**What's NOT caught by CI**: type-semantic drift in the bearer-auth
patch. bun's bundler doesn't run `tsc` -- it strips types and bundles.
On every `nix flake update opencode`, manually run `bun install &&
bun turbo typecheck` against the patched source. See `docs/spec.md`
§7 for the frontier item that would close this gap.

## Layout

```
cmd/kfactory/           Go CLI source (binary name: kfactory)
completions/_kfactory   zsh completion (auto-installed by Nix into share/zsh/site-functions)
plugin/                 factory-adapter.ts + package.json + tsconfig.json
patches/                opencode-bearer-auth.patch + oauth2-proxy-pkce-no-secret.patch
docs/spec.md            architecture intent + decisions log
flake.nix               packages.kfactory, lib.mkFactoryAdapter, patches.*, checks.*
```

## License

AGPLv3. See `LICENSE`.
