# Adds opencode-serve lifecycle hooks:
#   ExecStartPre:  opencode-heal <DB> writes the recovery queue.
#   ExecStartPost: opencode-sync-kick refreshes workspace status.
#   ExecStartPost: recovery-sweep ticks queued workspaces with the restart prompt.
# Empty queue = no recovery work.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.kfactory.recovery;
  opencodeServiceUser = config.systemd.services.${cfg.opencodeServiceName}.serviceConfig.User or null;
in {
  options.services.kfactory.recovery = {
    enable = lib.mkEnableOption "kfactory opencode-serve recovery lifecycle (heal + sync-kick + tick-stuck-sessions)";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        Unified kfactory runtime package. The package supplies the CLI used by
        recovery-sweep and exposes the matched `opencode-heal` and
        `opencode-sync-kick` hooks through passthru. Mixing versions across
        these three is not supported because the heal queue file format couples
        to the sweep's reader. Endpoint defaults are runtime environment or
        persisted auth state, not package overrides.
      '';
      example = lib.literalExpression "inputs.kfactory.packages.\${pkgs.stdenv.hostPlatform.system}.kfactory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        Unprivileged user that recovery-sweep runs as. Must have run
        `kfactory auth login` at least once. Typically matches the
        opencode-serve user.
      '';
      example = "opencode";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      defaultText = lib.literalMD "{option}`services.kfactory.recovery.user`";
      description = ''
        Group that owns `/run/kfactory/`, where heal writes the recovery
        queue. Defaults to `cfg.user`; override when the operator's
        primary group differs from the username, for example:

          services.kfactory.recovery.group = "users";

        If the group does not exist, tmpfiles will not create the queue
        directory and heal's ExecStartPre will fail.
      '';
      example = "users";
    };

    opencodeServiceName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of the systemd service running opencode-serve. The
        recovery hooks attach to its ExecStartPre/ExecStartPost via
        a drop-in. The operator names the unit (or uses the
        `factoryGuest` module, which wires this automatically to its
        own `factory-opencode` unit).
      '';
      example = "opencode";
    };

    opencodeDB = lib.mkOption {
      type = lib.types.path;
      description = ''
        Absolute path to opencode's sqlite DB. opencode-heal
        operates on this file; first-boot (no file) is tolerated.
      '';
      example = "/var/lib/opencode/.local/share/opencode/opencode.db";
    };

    opencodeBaseURL = lib.mkOption {
      type = lib.types.str;
      description = ''
        Base URL opencode binds. opencode-sync-kick uses this to poll
        health + iterate workspaces. Internal API only -- this is
        typically a loopback or VM-internal address, NOT the
        reverse-proxy-fronted public URL.
      '';
      example = "http://10.0.0.2:4096";
    };

    healthTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Seconds to wait for opencode /global/health 2xx before sync-kick gives up.";
    };

    prompt = lib.mkOption {
      type = lib.types.str;
      default = ''
        Opencode just restarted while your turn was in flight. Pick up
        where you left off and continue accordingly as you were.
      '';
      description = ''
        Prompt injected into each workspace's most-recent session by
        the recovery-sweep step. Sensible default; override to match
        your deployment's agent persona / convention.
      '';
    };

    queuePath = lib.mkOption {
      type = lib.types.str;
      default = "/run/kfactory/recovery-queue.json";
      description = ''
        Path heal writes (and recovery-sweep reads) the affected-
        workspace-ID list to. Must be writable by the opencode-serve
        unit's user. /run/ default is tmpfs-backed and clears on boot,
        which is correct -- a fresh boot has no pending recovery work
        until heal runs.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = opencodeServiceUser == cfg.user;
        message = ''
          services.kfactory.recovery.user (${cfg.user}) must match
          systemd.services.${cfg.opencodeServiceName}.serviceConfig.User
          (${
            if opencodeServiceUser == null
            then "<unset>"
            else opencodeServiceUser
          }).
          Recovery hooks run inside the opencode service unit, so queue ownership
          and kfactory auth lookup split if these users diverge.
        '';
      }
    ];

    # Per-workspace failure logs + continues; never blocks restart.
    systemd.services.${cfg.opencodeServiceName} = let
      recoverySweep = pkgs.writeShellApplication {
        name = "kfactory-recovery-sweep";
        runtimeInputs = [pkgs.jq pkgs.coreutils cfg.package];
        text = ''
          QUEUE=''${KFACTORY_RECOVERY_QUEUE:-${cfg.queuePath}}
          if [ ! -f "$QUEUE" ]; then
            echo "kfactory-recovery-sweep: no queue at $QUEUE; nothing to do"
            exit 0
          fi
          PROMPT=''${KFACTORY_RECOVERY_PROMPT:-${lib.escapeShellArg cfg.prompt}}

          ticked=0
          while IFS= read -r wid; do
            if kfactory tick "$wid" --prompt "$PROMPT"; then
              ticked=$((ticked + 1))
            else
              echo "kfactory-recovery-sweep: failed to tick $wid" >&2
            fi
          done < <(jq -r '.[]' < "$QUEUE")
          echo "kfactory-recovery-sweep: ticked $ticked workspace(s)"
        '';
      };
    in {
      # ExecStartPre/Post are list-shaped: NixOS concatenates rather
      # than clobbers, so this appends to the operator's unit.
      # recovery-sweep needs auth.json (mode 0600) so it must run as
      # cfg.user; heal + sync-kick inherit the unit's User= and only
      # need DB / internal-API access (no auth.json read).
      serviceConfig = {
        ExecStartPre = ["${cfg.package.passthru.opencodeHeal}/bin/opencode-heal ${lib.escapeShellArg cfg.opencodeDB}"];
        ExecStartPost = [
          "${cfg.package.passthru.opencodeSyncKick}/bin/opencode-sync-kick --base ${cfg.opencodeBaseURL} --health-timeout ${toString cfg.healthTimeoutSeconds}"
          "${recoverySweep}/bin/kfactory-recovery-sweep"
        ];
      };
      # `.environment` (attrset, merges) not `serviceConfig.Environment`
      # (list, clobbers) -- preserves operator's existing Environment=.
      # XDG_CONFIG_HOME via `users.users.<name>.home` handles non-/home
      # deployments (e.g. persistent-volume `/var/lib/factory/<user>`).
      # mkDefault so a co-located factoryGuest (which sets the same value at
      # normal priority on this unit) wins without a merge conflict; standalone
      # recovery on an operator's own unit still gets it from here.
      environment = {
        KFACTORY_RECOVERY_QUEUE = cfg.queuePath;
        XDG_CONFIG_HOME = lib.mkDefault "${config.users.users.${cfg.user}.home}/.config";
      };
    };

    # heal mkdir's the queue parent, but tmpfiles owns the perms
    # (predictable across reboots, independent of unit umask).
    systemd.tmpfiles.rules = [
      "d ${builtins.dirOf cfg.queuePath} 0755 ${cfg.user} ${cfg.group} -"
    ];
  };
}
