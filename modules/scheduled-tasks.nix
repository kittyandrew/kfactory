# NixOS module: kfactory scheduled tasks.
#
# Generates one systemd timer + service pair per declared task.
# Schedule entries write their config to /etc/kfactory/scheduled/<id>.json
# (consumed by `kfactory tick <id>` at fire time -- schema defined in
# cmd/kfactory/tick.go's scheduledTaskConfig struct).
#
# This is the only NixOS module kfactory ships. Its existence is the
# exception to the "no NixOS module" stance: per-task systemd unit
# generation is intrinsically NixOS-shaped and the operator-facing
# attribute schema is the natural fit. See docs/spec.md decisions log.
{
  config,
  lib,
  ...
}: let
  cfg = config.services.kfactory.scheduledTasks;

  # Per-task JSON shape mirrors scheduledTaskConfig in tick.go. Keep
  # the two in sync; CLI is the schema authority but the module is the
  # ergonomic surface.
  taskJSON = task:
    builtins.toJSON {
      repo = task.repo;
      mode = task.mode;
      initial_prompt = task.initialPrompt;
      continuation_prompt = task.continuationPrompt;
    };

  # Validate task-id matches the 4-hex slug-suffix shape enforced by
  # both the kfactory-adapter (SLUG_RE) and the CLI (taskIDPattern in
  # tick.go). The same shape is what random ad-hoc dispatches mint, so
  # scheduled-task workspaces are indistinguishable from random ones
  # at the slug level -- one structural invariant everywhere. Caught
  # at eval time so the error blames the operator's NixOS config, not
  # a runtime tick failure.
  validTaskID = id:
    builtins.match "[a-f0-9]{4}" id != null;

  taskOpts = {
    options = {
      schedule = lib.mkOption {
        type = lib.types.str;
        description = ''
          systemd OnCalendar= expression (e.g. "Mon *-*-* 09:00:00",
          "*-*-* 03:00:00", "weekly"). See systemd.time(7).
        '';
        example = "Mon *-*-* 09:00:00";
      };
      repo = lib.mkOption {
        type = lib.types.str;
        description = "Git repo URL passed to the kfactory-adapter on first dispatch.";
        example = "git@github.com:acme/widget.git";
      };
      mode = lib.mkOption {
        type = lib.types.enum ["skip-if-exists" "skip-if-dirty" "continue"];
        default = "skip-if-dirty";
        description = ''
          All three modes CREATE the workspace + fire initialPrompt
          when no workspace with this task-id exists. The mode only
          decides what happens when one already does -- in every
          dispatching mode the continuation lands in the EXISTING
          root session (no new sessions, no orphan workspaces):

            skip-if-exists - no-op. Useful for "set up once, leave
                             alone" tasks.
            skip-if-dirty  - dispatch ONLY if the workspace's git
                             working tree is clean. Dirty = uncommitted
                             or untracked files; the prompt is skipped
                             so the agent's in-flight work isn't
                             clobbered. Default + safest.
            continue       - unconditional dispatch. No safety net.
        '';
      };
      initialPrompt = lib.mkOption {
        type = lib.types.str;
        description = "Prompt fired into the freshly-created session on the FIRST tick.";
      };
      continuationPrompt = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Prompt fired into the existing session when the mode
          dispatches (skip-if-dirty + clean, OR continue). Empty
          string defaults to initialPrompt.
        '';
      };
      randomizedDelay = lib.mkOption {
        type = lib.types.str;
        default = "0";
        description = ''
          systemd RandomizedDelaySec= -- jitter applied to the timer
          fire time to avoid thundering-herd if many tasks share a
          schedule. "0" disables. "5m" adds 0-5 min uniform random delay.
        '';
        example = "5m";
      };
      persistent = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          systemd Persistent=true -- catch up missed ticks if the
          system was off when the timer would have fired. Recommended
          for daily/weekly tasks; disable for high-frequency timers
          where catch-up would be noisy.
        '';
      };
    };
  };
in {
  options.services.kfactory.scheduledTasks = {
    enable = lib.mkEnableOption "kfactory scheduled-task timers";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        kfactory CLI package used in generated systemd units. Operators
        typically wire `pkgs.kfactory` (overridden with their endpoint
        defaults via ldflags); the module doesn't bake in a default.
      '';
      example = lib.literalExpression "pkgs.kfactory";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        Unprivileged user that the timer services run as. Must have
        run `kfactory auth login` at least once so $XDG_CONFIG_HOME/
        kfactory/auth.json exists. Multi-user deployments use one
        scheduledTasks instance per user.
      '';
      example = "kittyandrew";
    };

    tasks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule taskOpts);
      default = {};
      description = ''
        Map of taskID -> task config. The taskID becomes the workspace
        slug suffix (e.g. taskID "7a3f" -> workspace name
        "<owner>--<repo>--7a3f"). Must match the regex
        `[a-f0-9]{4}` -- exactly four lowercase hex chars. Same shape
        as a random workspace slug suffix, so scheduled-task
        workspaces are indistinguishable from random ones at the slug
        level. Operators document the taskID -> human-name mapping in
        their NixOS config so a "what is 7a3f" lookup is one grep
        away.
      '';
      example = lib.literalExpression ''
        {
          # 7a3f = "weekly dep upgrades"
          "7a3f" = {
            schedule           = "Mon *-*-* 09:00:00";
            repo               = "git@github.com:acme/widget.git";
            mode               = "continue";
            initialPrompt      = "Check for dep upgrades and open a PR.";
            continuationPrompt = "Resume the dep-bump work.";
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Eval-time guards: catch obvious mistakes before systemd-rebuild.
    assertions =
      lib.mapAttrsToList (id: _task: {
        assertion = validTaskID id;
        message = ''
          services.kfactory.scheduledTasks.tasks.${id}: task id must
          match `[a-f0-9]{4}` exactly (4 lowercase hex chars). This is
          the same shape as a random workspace slug suffix, so
          scheduled-task workspaces are indistinguishable from random
          ones at the slug level. Pick a stable 4-hex identifier per
          task (e.g. "0001", "7a3f"); document the mapping in your
          NixOS module so operators can grep config for "what is task
          7a3f".
        '';
      })
      cfg.tasks;

    environment.etc = lib.mapAttrs' (id: task:
      lib.nameValuePair "kfactory/scheduled/${id}.json" {
        text = taskJSON task;
        mode = "0644";
      })
    cfg.tasks;

    # One .service + .timer per task.
    systemd.services = lib.mapAttrs' (id: _task:
      lib.nameValuePair "kfactory-tick-${id}" {
        description = "kfactory scheduled task: ${id}";
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          # XDG_CONFIG_HOME locates kfactory/auth.json. Resolve via
          # `users.users.<name>.home` -- non-/home deployments (e.g.
          # `/var/lib/factory/<user>`) place auth.json outside `/home/`.
          Environment = "XDG_CONFIG_HOME=${config.users.users.${cfg.user}.home}/.config";
          # Restart=no: failed ticks logged (journalctl), not retried
          # within the unit -- the next scheduled fire re-attempts;
          # transient failures self-heal at cron tempo.
          Restart = "no";
        };
        script = "${cfg.package}/bin/kfactory tick ${id}";
      })
    cfg.tasks;

    systemd.timers = lib.mapAttrs' (id: task:
      lib.nameValuePair "kfactory-tick-${id}" {
        description = "kfactory scheduled task timer: ${id}";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = task.schedule;
          Persistent = task.persistent;
          RandomizedDelaySec = task.randomizedDelay;
          Unit = "kfactory-tick-${id}.service";
        };
      })
    cfg.tasks;
  };
}
