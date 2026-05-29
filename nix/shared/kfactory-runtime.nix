{
  pkgs,
  lib ? pkgs.lib,
  kfactoryCli,
  opencodePackage,
  plugins,
  thirdPartyPlugins,
  opencodeHeal,
  opencodeSyncKick,
  configTemplate,
  loopCommandFile,
  loopStopCommandFile,
}: let
  stripCommandFrontmatter = file: let
    text = builtins.readFile file;
    body = lib.removePrefix "---\n" text;
    parts = lib.splitString "\n---\n" body;
    template =
      if lib.hasPrefix "---\n" text && builtins.length parts >= 2
      then lib.concatStringsSep "\n---\n" (builtins.tail parts)
      else text;
  in
    lib.removePrefix "\n" template;

  bundledConfig = pkgs.replaceVars configTemplate {
    PLUGIN_KFACTORY_ADAPTER = "${plugins.kfactory-adapter}";
    PLUGIN_NTFY = "${plugins.ntfy}";
    PLUGIN_LOOP = "${plugins.loop}";
    PLUGIN_OPENCODE_PTY = "${thirdPartyPlugins.opencode-pty}";
    LOOP_COMMAND_TEMPLATE = builtins.toJSON (stripCommandFrontmatter loopCommandFile);
    LOOP_STOP_COMMAND_TEMPLATE = builtins.toJSON (stripCommandFrontmatter loopStopCommandFile);
  };

  envWrapperArgs = lib.concatStringsSep " " [
    "--set-default KFACTORY_ADAPTER_GIT ${lib.escapeShellArg "${pkgs.git}/bin/git"}"
    "--set-default KFACTORY_ADAPTER_OPENSSH_SSH ${lib.escapeShellArg "${pkgs.openssh}/bin/ssh"}"
    "--set-default KFACTORY_ADAPTER_WORKSPACES_DIR ${lib.escapeShellArg "/var/lib/factory/workspaces"}"
  ];

  wrappedOpencode = opencodePackage.overrideAttrs (old: {
    postFixup =
      (old.postFixup or "")
      + ''
        wrapProgram $out/bin/opencode \
          --set-default OPENCODE_EXPERIMENTAL_WORKSPACES true \
          --set-default OPENCODE_CONFIG ${bundledConfig} \
          ${envWrapperArgs}
      '';
  });

  runtime = pkgs.symlinkJoin {
    name = "kfactory-runtime";
    paths = [kfactoryCli wrappedOpencode];
    passthru = {
      opencode = wrappedOpencode;
      opencodeConfig = bundledConfig;
      configFile = bundledConfig;
      inherit plugins thirdPartyPlugins opencodeHeal opencodeSyncKick;
    };
    meta = {
      description = "Unified kfactory runtime: CLI, patched opencode, bundled config, and plugins";
      mainProgram = "kfactory";
      license = lib.licenses.agpl3Only;
    };
  };
in
  runtime
