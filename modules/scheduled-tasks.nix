# Generates per-task systemd timers whose JSON config is consumed by
# `kfactory tick`. Schema authority: cmd/kfactory/tick.go; rationale:
# docs/spec.md scheduled-task decisions.
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

  # Same 4-hex slug-suffix invariant as kfactory-adapter and tick.go;
  # validate at eval time so bad task IDs blame the NixOS config.
  validTaskID = id:
    builtins.match "[a-f0-9]{4}" id != null;

  nonBlank = value:
    builtins.match ".*[^ \t\n\r].*" value != null;

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
          Missing workspaces create and receive initialPrompt; incomplete
          first runs are repaired before mode-specific continuation behavior:

            skip-if-exists - no-op. Useful for "set up once, leave
                             alone" tasks.
            skip-if-dirty  - dispatch ONLY if the workspace's git
                             working tree is clean. Dirty = uncommitted
                             or untracked files; the prompt is skipped
                             so the agent's in-flight work isn't
                             clobbered. Default + safest.
            continue       - unconditional dispatch. No safety net.

          `kfactory tick` serializes overlapping fires with a per-task
          mutex; first-run completion is derived from opencode state, not
          cache file contents.
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
        kfactory runtime package used in generated systemd units. Endpoint
        defaults are runtime environment (`KFACTORY_SERVER`,
        `KFACTORY_OIDC_ISSUER`, `KFACTORY_OIDC_CLIENT_ID`,
        `KFACTORY_OIDC_AUDIENCE`) or persisted auth state; the module
        doesn't bake in a default.
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
      example = "opencode";
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
    assertions = lib.concatLists (lib.mapAttrsToList (id: task: [
        {
          assertion = validTaskID id;
          message = ''
            services.kfactory.scheduledTasks.tasks.${id}: task id must
            match `[a-f0-9]{4}` exactly; pick a stable 4-hex identifier
            and document its human meaning next to the task.
          '';
        }
        {
          assertion = nonBlank task.repo;
          message = "services.kfactory.scheduledTasks.tasks.${id}.repo must not be empty or whitespace-only";
        }
        {
          assertion = nonBlank task.initialPrompt;
          message = "services.kfactory.scheduledTasks.tasks.${id}.initialPrompt must not be empty or whitespace-only";
        }
        {
          assertion = task.continuationPrompt == "" || nonBlank task.continuationPrompt;
          message = "services.kfactory.scheduledTasks.tasks.${id}.continuationPrompt must be empty or non-whitespace";
        }
      ])
      cfg.tasks);

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
          # Resolve config/lock paths from the user's actual home; deployments
          # may not live under /home.
          Environment = [
            "XDG_CONFIG_HOME=${config.users.users.${cfg.user}.home}/.config"
            "KFACTORY_LOCK_DIR=${config.users.users.${cfg.user}.home}/.cache/kfactory/locks"
          ];
          # Do not retry within the unit; the next timer fire is the retry boundary.
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
