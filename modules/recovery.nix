# NixOS module: kfactory opencode-serve recovery lifecycle.
#
# Wires three lifecycle hooks into the opencode-serve systemd unit:
#
#   ExecStartPre  = opencode-heal <DB>
#       Sweeps zombie assistant messages (turn was mid-flight when the
#       prior opencode-serve died). Marks them `finish =
#       interrupted-by-restart` and EMITS a JSON queue at
#       /run/kfactory/recovery-queue.json listing the workspace IDs
#       whose sessions had stuck turns.
#
#   ExecStartPost = opencode-sync-kick --base <URL>
#       Pokes the per-workspace status sync that opencode otherwise
#       only triggers on SPA init. Without this, the first session
#       interact after restart shows "Workspace Unavailable."
#
#   ExecStartPost = recovery-sweep
#       Reads the queue file and runs `kfactory tick <ref> --prompt
#       <prompt>` against each workspace whose session was interrupted.
#       The configured `prompt` tells the agent that opencode-serve
#       restarted mid-run; the agent decides how to resume.
#
# Heal + recovery are tightly coupled: recovery only ticks workspaces
# that heal actually found a stuck turn in. Restarts where every
# session was already complete leave the queue empty + recovery is a
# no-op.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.kfactory.recovery;
in {
  options.services.kfactory.recovery = {
    enable = lib.mkEnableOption "kfactory opencode-serve recovery lifecycle (heal + sync-kick + tick-stuck-sessions)";

    packages = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      description = ''
        kfactory's flake `packages.<system>` attrset. Three keys read:
          - `kfactory`        -- CLI used by recovery-sweep to tick stuck workspaces
          - `opencode-heal`   -- ExecStartPre DB-sweep
          - `opencode-sync-kick` -- ExecStartPost workspace-status poke
        Three-in-one because the heal queue file format couples to the
        sweep's reader -- mixing versions across these three is not
        supported. Operators wire one self-consistent flake's outputs:
        `inputs.kfactory.packages.''${system}` (optionally with
        `kfactory` overridden via overrideAttrs/ldflags for their
        endpoint defaults).
      '';
      example = lib.literalExpression "inputs.kfactory.packages.\${pkgs.system}";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        Unprivileged user that recovery-sweep runs as. Must have run
        `kfactory auth login` at least once. Typically matches the
        opencode-serve user.
      '';
      example = "kittyandrew";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      defaultText = lib.literalMD "{option}`services.kfactory.recovery.user`";
      description = ''
        Group that owns `/run/kfactory/` (the tmpfiles-managed directory
        where heal writes the recovery queue). Defaults to `cfg.user`
        because most NixOS users have a same-named primary group (the
        nixpkgs `useDefaultShell`/`isNormalUser` shape creates one).
        Override when the operator's primary group differs from the
        username -- e.g., users created without a per-user group
        whose primary group is the shared `users` group:

          services.kfactory.recovery.group = "users";

        If you don't override and the group doesn't exist, systemd-
        tmpfiles emits "Unknown group" to the journal but doesn't fail
        the unit on its own. The actual blocker is heal's ExecStartPre:
        it tries to write the recovery queue under `/run/kfactory/`,
        that directory doesn't exist (tmpfiles refused to create it),
        the write fails, and opencode-serve fails to start.
      '';
      example = "users";
    };

    opencodeServiceName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of the systemd service running opencode-serve. The
        recovery hooks attach to its ExecStartPre/ExecStartPost via
        a drop-in. Operator names the unit; kfactory doesn't ship
        the opencode-serve unit itself (per the "no NixOS module for
        opencode" stance).
      '';
      example = "opencode";
    };

    opencodeDB = lib.mkOption {
      type = lib.types.path;
      description = ''
        Absolute path to opencode's sqlite DB. opencode-heal
        operates on this file; first-boot (no file) is tolerated.
      '';
      example = "/var/lib/factory/kittyandrew/.local/share/opencode/opencode.db";
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
        opencode-serve was restarted while your turn was in flight. Your
        previous response was interrupted (marked finish=interrupted-by-restart).
        Review your last actions, decide whether the work needs to be
        completed, re-tried, or abandoned, and continue accordingly.
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
    # Recovery-sweep helper. Reads the queue heal emitted; loops over
    # the workspace IDs; ticks each one with `--prompt <recovery-prompt>`.
    # Empty queue (heal found nothing) -> instant no-op via the loop
    # body never running. Failure on a single workspace logs and
    # continues; doesn't block restart of opencode-serve.
    systemd.services.${cfg.opencodeServiceName} = let
      recoverySweep = pkgs.writeShellApplication {
        name = "kfactory-recovery-sweep";
        runtimeInputs = [pkgs.jq pkgs.coreutils cfg.packages.kfactory];
        text = ''
          # Usage: kfactory-recovery-sweep (no args; queue path via
          # KFACTORY_RECOVERY_QUEUE env, recovery prompt via
          # KFACTORY_RECOVERY_PROMPT).

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
      # systemd merges ExecStartPre / ExecStartPost across attribute
      # writes (NixOS concatenates list-shaped fields), so this
      # appends to whatever the operator's opencode-serve unit already
      # has.
      serviceConfig = {
        ExecStartPre = ["${cfg.packages.opencode-heal}/bin/opencode-heal ${lib.escapeShellArg cfg.opencodeDB}"];
        ExecStartPost = [
          "${cfg.packages.opencode-sync-kick}/bin/opencode-sync-kick --base ${cfg.opencodeBaseURL} --health-timeout ${toString cfg.healthTimeoutSeconds}"
          "${recoverySweep}/bin/kfactory-recovery-sweep"
        ];
        # recovery-sweep must run as the user with auth.json. heal +
        # sync-kick inherit the opencode-serve unit's existing User=,
        # which the operator owns.
      };
      # Env vars MERGE into the operator's unit (NixOS treats
      # `.environment` as an attrset, so co-existing keys add rather
      # than overwrite). The earlier serviceConfig.Environment =
      # [...] shape would CLOBBER the operator's existing
      # Environment= line; using `.environment` keeps both halves
      # alive. XDG_CONFIG_HOME points recovery-sweep's
      # `kfactory tick` at the operator's auth.json; the heal +
      # sync-kick steps don't need it (they operate on the local DB
      # / unauthenticated internal API).
      environment = {
        KFACTORY_RECOVERY_QUEUE = cfg.queuePath;
        XDG_CONFIG_HOME = "/home/${cfg.user}/.config";
      };
    };

    # Ensure /run/kfactory exists with the right ownership; heal
    # mkdir's the queue's parent but a tmpfiles rule makes the perms
    # predictable across reboots.
    systemd.tmpfiles.rules = [
      "d ${builtins.dirOf cfg.queuePath} 0755 ${cfg.user} ${cfg.group} -"
    ];
  };
}
