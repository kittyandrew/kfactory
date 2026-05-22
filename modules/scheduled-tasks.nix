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
        type = lib.types.enum ["continue" "skip-if-exists" "fresh"];
        default = "continue";
        description = ''
          Behavior when a workspace for this task already exists:
            continue       - post continuationPrompt to the most-recent root session
            skip-if-exists - log + exit 0 (block until workspace is deleted)
            fresh          - mint a new workspace each tick (operator must clean up the old one)
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
          Prompt fired into the existing session on subsequent ticks
          (when mode = "continue"). Empty string defaults to initialPrompt.
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

    # Write one JSON config file per task. /etc/kfactory/scheduled/<id>.json
    # is the path `kfactory tick <id>` reads at fire time.
    environment.etc = lib.mapAttrs' (id: task:
      lib.nameValuePair "kfactory/scheduled/${id}.json" {
        text = taskJSON task;
        mode = "0644";
      })
    cfg.tasks;

    # Generate one .service + .timer per task. The service is one-shot;
    # the timer fires on the configured schedule. The unit's User= is
    # the configured operator; XDG_CONFIG_HOME points at their config
    # so ensureFresh can locate auth.json.
    systemd.services = lib.mapAttrs' (id: _task:
      lib.nameValuePair "kfactory-tick-${id}" {
        description = "kfactory scheduled task: ${id}";
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          # XDG_CONFIG_HOME locates kfactory/auth.json; same path the
          # operator's interactive `kfactory auth login` writes to.
          Environment = "XDG_CONFIG_HOME=/home/${cfg.user}/.config";
          # The default systemd hardening profile is fine here -- this
          # is a network-bound CLI invocation, no privileged ops.
          # Restart=no: failed ticks are reported (journalctl), not
          # retried within the unit. The next scheduled fire will
          # re-attempt; transient failures self-heal at cron tempo.
          Restart = "no";
        };
        # Pass the task-id positional; tick reads the JSON at
        # /etc/kfactory/scheduled/<id>.json (default path).
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
