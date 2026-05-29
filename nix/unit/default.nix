{
  pkgs,
  pluginSrcs,
  pluginPackages,
  opencodePackage,
}: let
  mkOpencodeNodeModulesConfigurePhase = import ../shared/opencode-node-modules.nix;
  loopSpec = pluginSrcs.loop;
  ntfySpec = pluginSrcs.ntfy;
  stageOpencodeNodeModules = mkOpencodeNodeModulesConfigurePhase {
    nodeModules = opencodePackage.node_modules;
  };

  mkOpencodeBunTest = {
    pname,
    testFile,
    testName,
    env ? {},
    extraNativeBuildInputs ? [],
  }:
    opencodePackage.overrideAttrs (old: {
      inherit pname;
      kfactoryTestFile = testFile;
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ extraNativeBuildInputs;
      configurePhase = stageOpencodeNodeModules;
      buildPhase = ''
        runHook preBuild
        mkdir -p packages/opencode/test/kfactory
        cp "$kfactoryTestFile" packages/opencode/test/kfactory/${testName}
        export HOME=$TMPDIR
        ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (name: value: "export ${name}=${pkgs.lib.escapeShellArg value}") env)}
        cd packages/opencode
        bun test test/kfactory/${testName}
        cd ../..
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        touch $out
        runHook postInstall
      '';
      postInstall = "";
      postFixup = "";
      doInstallCheck = false;
    });

  loopPluginUnit = pkgs.buildNpmPackage {
    pname = "factory-loop-plugin-unit";
    version = "0";
    src = loopSpec.src;
    npmDepsHash = loopSpec.npmDepsHash;
    dontNpmBuild = true;
    nativeBuildInputs = [pkgs.bun];
    buildPhase = ''
      runHook preBuild
      bun test test/*.test.ts
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      touch $out
      runHook postInstall
    '';
  };

  ntfyPluginUnit = pkgs.buildNpmPackage {
    pname = "factory-ntfy-plugin-unit";
    version = "0";
    src = ntfySpec.src;
    npmDepsHash = ntfySpec.npmDepsHash;
    dontNpmBuild = true;
    nativeBuildInputs = [pkgs.bun];
    buildPhase = ''
      runHook preBuild
      bun test --test-name-pattern '^(?!property:)' test/*.test.ts
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      touch $out
      runHook postInstall
    '';
  };

  ntfyOpencodeInprocess = mkOpencodeBunTest {
    pname = "factory-ntfy-opencode-inprocess";
    testFile = ./opencode/ntfy-plugin-inprocess.test.ts;
    testName = "ntfy-plugin-inprocess.test.ts";
    extraNativeBuildInputs = [pkgs.git];
    env.KFACTORY_NTFY_PLUGIN_PATH = "${pluginPackages.ntfy}";
  };

  kfactoryContracts = mkOpencodeBunTest {
    pname = "factory-opencode-kfactory-contracts";
    testFile = ./opencode/kfactory-patch-contracts.test.ts;
    testName = "kfactory-patch-contracts.test.ts";
    extraNativeBuildInputs = [pkgs.git];
  };

  kfactoryAdapterPluginInteraction = mkOpencodeBunTest {
    pname = "factory-kfactory-adapter-plugin-interaction";
    testFile = ./opencode/kfactory-adapter-plugin-interaction.test.ts;
    testName = "kfactory-adapter-plugin-interaction.test.ts";
    extraNativeBuildInputs = [pkgs.git pkgs.openssh];
    env = {
      KFACTORY_ADAPTER_PLUGIN_PATH = "${pluginPackages.kfactory-adapter}";
      KFACTORY_ADAPTER_GIT = "${pkgs.git}/bin/git";
      KFACTORY_ADAPTER_OPENSSH_SSH = "${pkgs.openssh}/bin/ssh";
      OPENCODE_EXPERIMENTAL_WORKSPACES = "true";
    };
  };

  tuiAttachSmoke = mkOpencodeBunTest {
    pname = "factory-opencode-tui-attach-smoke";
    testFile = ./opencode/tui-attach-smoke.test.ts;
    testName = "tui-attach-smoke.test.ts";
    extraNativeBuildInputs = [pkgs.git pkgs.util-linux];
    env.OPENCODE_EXPERIMENTAL_WORKSPACES = "true";
  };
in {
  factory-opencode-tui-attach-smoke = tuiAttachSmoke;
  factory-loop-plugin-unit = loopPluginUnit;
  factory-ntfy-plugin-unit = ntfyPluginUnit;
  factory-ntfy-opencode-inprocess = ntfyOpencodeInprocess;
  factory-opencode-kfactory-contracts = kfactoryContracts;
  factory-kfactory-adapter-plugin-interaction = kfactoryAdapterPluginInteraction;
}
