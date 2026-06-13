{
  description = "kfactory -- opencode factory deployment toolkit: kfactory CLI + kfactory-adapter & ntfy plugins + opencode/oauth2-proxy patches";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Patch stack is pinned to this opencode tag; bump/rediff workflows live in
    # .claude/rules/{022-patches-bump,021-patches-rediff}.md.
    # Follow top-level nixpkgs so the CLI, patched opencode, and checks share
    # one nixpkgs pin.
    opencode = {
      url = "github:anomalyco/opencode/v1.17.4";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Backs nixosModules.factoryGuest + the bundled dev VM (nix/dev-vm).
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    opencode,
    microvm,
  }: let
    forAllSystems = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"];
    sharedSources = import ./nix/shared/sources.nix;
    inherit (sharedSources) opencodePatchStack opencodeVersion pluginSrcs thirdPartyPluginSrcs;

    kfactoryComponentsFor = system:
      import ./nix/shared/components.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        lib = nixpkgs.lib;
        inherit system opencode pluginSrcs thirdPartyPluginSrcs opencodePatchStack;
      };
  in {
    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);

    # `nix develop` -- CI and local hacking share the same toolchain
    # versions; .github/workflows/ci.yml invokes everything via
    # `nix develop -c`.
    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = import ./nix/shared/dev-shell.nix {inherit pkgs;};
    });

    # Public package API: the unified runtime and the oauth2-proxy sibling.
    # Components/plugins/patches stay internal so the CLI, opencode, config,
    # and plugins move as one tested closure.
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      components = kfactoryComponentsFor system;
    in {
      kfactory = components.unified;
      default = self.packages.${system}.kfactory;

      oauth2-proxy-kfactory = pkgs.oauth2-proxy.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./patches/oauth2-proxy-pkce-no-secret.patch];
      });
    });

    # Docker-based e2e lifecycle (see nix/e2e/README.md).
    apps = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      components = kfactoryComponentsFor system;
      scripts = import ./nix/scripts {
        inherit pkgs;
        opencodeImage = components.opencodeImage;
        clientImage = components.kfactoryClientImage;
      };
      mkApp = drv: name: {
        type = "app";
        program = "${drv}/bin/${name}";
      };
    in {
      dev-up = mkApp scripts.dev-up "dev-up";
      dev-down = mkApp scripts.dev-down "dev-down";
      dev-clean = mkApp scripts.dev-clean "dev-clean";
      dev-test = mkApp scripts.dev-test "dev-test";

      # Interactive microvm (x86_64 guest; see nix/dev-vm/default.nix).
      dev-vm = {
        type = "app";
        program = "${self.nixosConfigurations.dev-vm.config.microvm.declaredRunner}/bin/microvm-run";
      };
      dev-vm-login = mkApp (pkgs.writeShellApplication {
        name = "dev-vm-login";
        runtimeInputs = [components.unified];
        text = ''
          # Keycloak rejects Zitadel's audience-scope URN; empty template =
          # issuer default (same shape the Keycloak flake check uses).
          export KFACTORY_OIDC_AUDIENCE_SCOPE_TEMPLATE=""
          exec kfactory auth login \
            --server http://127.0.0.1:4096 \
            --issuer http://127.0.0.1:8080/realms/kfactory-test \
            --client-id kfactory \
            --audience kfactory
        '';
      }) "dev-vm-login";
    });

    # NixOS modules for the kfactory pieces that are intrinsically
    # NixOS-shaped (per-task timers, opencode-serve lifecycle hooks, the
    # serve-unit guest profile). The proxy/secrets/host layer above stays
    # module-free. Each defaults `package` to packages.${system}.kfactory
    # for zero-config use; endpoint defaults are runtime env vars.
    nixosModules = {
      scheduledTasks = {pkgs, ...}: {
        imports = [./modules/scheduled-tasks.nix];
        services.kfactory.scheduledTasks.package =
          nixpkgs.lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.kfactory;
      };
      recovery = {pkgs, ...}: {
        imports = [./modules/recovery.nix];
        services.kfactory.recovery.package =
          nixpkgs.lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.kfactory;
      };
      # Reusable guest core (serve unit + worker user + state layout +
      # recovery + scheduledTasks); see modules/factory-guest.nix.
      factoryGuest = {pkgs, ...}: {
        imports = [./modules/factory-guest.nix ./modules/recovery.nix ./modules/scheduled-tasks.nix];
        services.kfactory.guest.package =
          nixpkgs.lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.kfactory;
        services.kfactory.scheduledTasks.package =
          nixpkgs.lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.kfactory;
      };
    };

    # Interactive dev VM (x86_64; port plan + quickstart in
    # nix/dev-vm/default.nix and the README).
    nixosConfigurations.dev-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        microvm.nixosModules.microvm
        self.nixosModules.factoryGuest
        (import ./nix/dev-vm {
          testRepo = nixpkgs.legacyPackages.x86_64-linux.callPackage ./nix/e2e/test-repo.nix {};
          realmFile = ./nix/e2e/kfactory-test-realm.json;
        })
      ];
    };

    # CI gate registry: package/plugin attrs auto-promote to checks; bespoke
    # checks cover patch application, type drift, methodology tests, and completions.
    checks = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      components = kfactoryComponentsFor system;
    in
      import ./nix/shared/checks.nix {
        inherit pkgs system opencode opencodePatchStack opencodeVersion pluginSrcs thirdPartyPluginSrcs components;
        lib = nixpkgs.lib;
        packageAttrs = self.packages.${system};
      });
  };
}
