# Reusable factory guest profile: one opencode-serve unit (the unified
# kfactory runtime) + worker user + state-dir layout + recovery lifecycle.
# Extracted from a production microvm deployment; everything
# deployment-specific (bind network, secrets delivery, persona files,
# hypervisor/shares/volumes) stays with the consumer. The bundled dev VM
# (nix/dev-vm/) and production hosts import the same module.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.kfactory.guest;
  # Single source of truth for the worker's home: the NixOS user record.
  # When we create the user we set its home to cfg.home; otherwise the
  # operator's existing record owns it. recovery.nix and scheduled-tasks.nix
  # also key XDG_CONFIG_HOME off this same record, so deriving the state
  # layout + XDG trees from it here means the three can never diverge --
  # there is nothing to reconcile and nothing to assert.
  homeDir =
    config.users.users.${cfg.user}.home
    or (throw "services.kfactory.guest: user `${cfg.user}` is not defined; set createUser = true or define the user (its home owns the state layout).");
in {
  options.services.kfactory.guest = {
    enable = lib.mkEnableOption "kfactory factory guest (opencode serve + worker user + recovery)";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        Unified kfactory runtime package (bin/opencode + bin/kfactory).
        The flake's nixosModules.factoryGuest wrapper defaults this to
        packages.<system>.kfactory.
      '';
      example = lib.literalExpression "inputs.kfactory.packages.\${pkgs.stdenv.hostPlatform.system}.kfactory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "factory";
      description = "Worker user the opencode serve process runs as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "factory";
      description = "Primary group of the worker user.";
    };

    createUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Create the worker user/group. Disable when the consumer manages
        the user (e.g. an existing operator user with extra config).
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/factory";
      description = ''
        Root of all factory state: worker home, workspaces, opencode
        SQLite DB. On a microvm deployment this is typically the mount
        point of a persistent volume; the opencode unit orders after its
        mount (RequiresMountsFor).
      '';
    };

    home = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.stateDir}/${cfg.user}";
      defaultText = lib.literalMD "{option}`stateDir`/{option}`user`";
      description = ''
        Worker user home (XDG trees + opencode DB live under it). Used as
        the created user's home when {option}`createUser` is true; when
        false, the existing user record's home owns the layout and this
        option is ignored.
      '';
    };

    workspacesDir = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.stateDir}/workspaces";
      defaultText = lib.literalMD "{option}`stateDir`/workspaces";
      description = "Per-workspace git clones root (kfactory-adapter target).";
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address opencode serve binds. Production typically binds a
        VM-internal bridge IP behind a reverse proxy; the dev VM binds
        0.0.0.0 so qemu user-net port-forwards reach it.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4096;
      description = "Port opencode serve listens on.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment for the serve unit (e.g. OPENCODE_* toggles).";
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        EnvironmentFile entries for the serve unit. Prefix with `-` for
        optional files (e.g. a secrets mount that may lag the unit on
        cold boot).
      '';
    };

    unitAfter = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra After= units (e.g. a persona-deployment service).";
    };

    unitRequires = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra Requires= units that must fail the serve unit loudly.";
    };

    recovery.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Wire services.kfactory.recovery (heal + sync-kick + sweep) onto the serve unit.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups = lib.mkIf cfg.createUser {${cfg.group} = {};};
    users.users = lib.mkIf cfg.createUser {
      ${cfg.user} = {
        isNormalUser = true;
        inherit (cfg) home group;
        createHome = false; # tmpfiles below owns the home layout under stateDir
      };
    };

    systemd.services."factory-opencode" = {
      description = "opencode factory: single serve, multi-workspace via kfactory-adapter";
      after = ["network-online.target" "local-fs.target"] ++ cfg.unitAfter;
      requires = cfg.unitRequires;
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      # `pkgs.git` FIRST and explicit: opencode's own project/VCS
      # resolution shells out to `git` from PATH (core/git.ts
      # ChildProcess.make("git", ...)). Without it, Project.resolve
      # treats every workspace clone as non-git and collapses it to the
      # "global" project (worktree "/") -- so workspaces never appear as
      # projects in `GET /project` and the web SPA (which lists sessions
      # per project directory) shows nothing. The kfactory-adapter clones
      # via an absolute KFACTORY_ADAPTER_GIT path and is unaffected, which
      # is why this stays invisible until you open the browser. git is a
      # hard dependency of the guest, not a consumer-supplied nicety.
      #
      # config.system.path then supplies the rest of the agent's bash-tool
      # toolchain (ssh/nix/...) -- a sanitized unit PATH would otherwise
      # ENOENT the adapter's and bash tool's spawns.
      path = [pkgs.git config.system.path];
      environment =
        {
          XDG_DATA_HOME = "${homeDir}/.local/share";
          XDG_CACHE_HOME = "${homeDir}/.cache";
          # Authoritative XDG_CONFIG_HOME for the serve unit and the recovery
          # hooks that run inside it. recovery.nix sets the same value at
          # mkDefault priority for its standalone use, so this normal-priority
          # set wins without a merge conflict and also covers recovery.enable
          # = false (where recovery sets nothing).
          XDG_CONFIG_HOME = "${homeDir}/.config";
          KFACTORY_ADAPTER_WORKSPACES_DIR = cfg.workspacesDir;
        }
        // cfg.environment;
      # Cold-boot retry budget: survive volume/secret mounts and ordering
      # chains that the default 5-burst/10s limit burns through.
      startLimitBurst = 30;
      startLimitIntervalSec = 300;
      unitConfig.RequiresMountsFor = cfg.stateDir;
      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        EnvironmentFile = cfg.environmentFiles;
        # Journald owns stderr; the default inherit would swallow every
        # stack trace opencode writes there.
        StandardError = "journal";
        # Pin project resolution: starting in `/` would scope the adapter
        # registration under an arbitrary project. The directory layout
        # comes from tmpfiles below (which create homeDir, not cfg.home) --
        # WorkingDirectory applies to ExecStartPre too, so a prestart can't
        # bootstrap its own cwd.
        WorkingDirectory = homeDir;
        ExecStart = "${cfg.package}/bin/opencode serve --hostname ${cfg.bindAddress} --port ${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    # Worker home + XDG trees + workspaces root, created before units run
    # (each level listed: tmpfiles `d` does not create parents). On a
    # volume-backed stateDir these land after the mount.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 root root -"
      "d ${homeDir} 0700 ${cfg.user} ${cfg.group} -"
      "d ${homeDir}/.config 0700 ${cfg.user} ${cfg.group} -"
      "d ${homeDir}/.config/opencode 0700 ${cfg.user} ${cfg.group} -"
      "d ${homeDir}/.local 0700 ${cfg.user} ${cfg.group} -"
      "d ${homeDir}/.local/share 0700 ${cfg.user} ${cfg.group} -"
      "d ${homeDir}/.local/share/opencode 0700 ${cfg.user} ${cfg.group} -"
      "d ${homeDir}/.cache 0700 ${cfg.user} ${cfg.group} -"
      "d ${cfg.workspacesDir} 0755 ${cfg.user} ${cfg.group} -"
    ];

    services.kfactory.recovery = lib.mkIf cfg.recovery.enable {
      enable = true;
      inherit (cfg) user group package;
      opencodeServiceName = "factory-opencode";
      opencodeDB = "${homeDir}/.local/share/opencode/opencode.db";
      opencodeBaseURL = "http://${cfg.bindAddress}:${toString cfg.port}";
    };
  };
}
