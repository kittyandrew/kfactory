{
  pkgs,
  lib ? pkgs.lib,
  system,
  opencode,
  pluginSrcs,
  thirdPartyPluginSrcs,
  opencodePatchStack,
}: let
  builders = import ./builders.nix;
  inherit (builders) mkPlugin mkThirdPartyPlugin;
  kfactoryRuntime = import ./kfactory-runtime.nix;
  opencodeComponents = import ./opencode-components.nix {
    inherit pkgs system opencode opencodePatchStack;
  };
  inherit (opencodeComponents) opencodePatched opencodeHeal opencodeSyncKick;

  pluginPackages =
    lib.mapAttrs
    (name: spec: mkPlugin pkgs ({inherit name;} // spec))
    pluginSrcs;
  thirdPartyPackages =
    lib.mapAttrs
    (name: spec: mkThirdPartyPlugin pkgs ({inherit name;} // spec))
    thirdPartyPluginSrcs;
  kfactoryCli = pkgs.callPackage ../.. {};
  unified = kfactoryRuntime {
    inherit pkgs lib kfactoryCli opencodeHeal opencodeSyncKick;
    opencodePackage = opencodePatched;
    plugins = pluginPackages;
    thirdPartyPlugins = thirdPartyPackages;
    configTemplate = ./opencode-kfactory-base.jsonc;
    loopCommandFile = ../../plugins/loop/commands/loop.md;
    loopStopCommandFile = ../../plugins/loop/commands/loop-stop.md;
  };
  testRepo = pkgs.callPackage ../e2e/test-repo.nix {};
in {
  inherit pluginPackages thirdPartyPackages kfactoryCli opencodePatched opencodeHeal opencodeSyncKick unified;
  opencodeImage = pkgs.callPackage ../e2e/opencode-image.nix {
    kfactory = unified;
    inherit testRepo;
  };
  kfactoryClientImage = pkgs.callPackage ../e2e/kfactory-client-image.nix {
    kfactory = unified;
    inherit testRepo;
  };
}
