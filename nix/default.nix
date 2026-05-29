{
  pkgs,
  pluginSrcs,
  pluginPackages,
  pluginRuntimeArtifactChecks,
  opencodeVersion,
  opencodeHeal,
  kfactory,
  opencodePackage,
}: let
  sharedAttrs = import ./shared/attrs.nix {lib = pkgs.lib;};
  inherit (sharedAttrs) mergeDisjointAttrs;
  unitChecks = import ./unit {
    inherit pkgs pluginSrcs pluginPackages opencodePackage;
  };
  propertyChecks = import ./property {
    inherit pkgs pluginSrcs;
  };
  replayChecks = import ./replay {
    inherit pkgs opencodeVersion opencodeHeal;
  };
  e2eChecks = import ./e2e {
    inherit pkgs kfactory opencodePackage;
  };
  ntfyRegressionTests = pkgs.runCommand "factory-ntfy-regression-tests" {} ''
    test -e ${unitChecks.factory-ntfy-plugin-unit}
    test -e ${propertyChecks.factory-ntfy-plugin-property}
    test -e ${unitChecks.factory-ntfy-opencode-inprocess}
    test -e ${pluginRuntimeArtifactChecks."factory-ntfy-runtime-artifact"}
    touch $out
  '';
in
  mergeDisjointAttrs "nix methodology checks" [
    unitChecks
    propertyChecks
    replayChecks
    e2eChecks
    {
      factory-ntfy-regression-tests = ntfyRegressionTests;
    }
  ]
