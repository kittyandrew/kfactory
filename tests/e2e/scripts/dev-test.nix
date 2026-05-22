{pkgs}: let
  env = import ../dev-env.nix;
  # Each phase lives in its own .sh file under ./dev-test/. The
  # driver below sets a small set of exported vars (so shellcheck
  # running on the concatenated script can resolve names across
  # phases) and then concatenates every phase's body in order.
  # Splitting was a ThermoNuclear S2 finding: the previous
  # 458-line monolithic text block buried phase [9/9] (the recovery
  # canary) at the bottom of one giant procedure with implicit
  # mutable state. Now each phase is reviewable in isolation, but
  # writeShellApplication's shellcheck still runs against the WHOLE
  # concatenated script -- so cross-phase name references stay
  # gated.
  # Read every *.sh in dev-test/ and sort lexicographically. The
  # filenames carry their own ordering prefix (00- ... 09-), so the
  # sort IS the execution order; adding a new phase is a single file
  # drop, no Nix edit required.
  phases = let
    dir = ./dev-test;
    entries = builtins.readDir dir;
    files =
      builtins.filter
      (n: builtins.match ".*\\.sh" n != null)
      (builtins.attrNames entries);
    sorted = builtins.sort (a: b: a < b) files;
  in
    map (n: builtins.readFile (dir + "/${n}")) sorted;
in
  pkgs.writeShellApplication {
    name = "dev-test";
    # writeShellApplication bakes shellcheck into the build, so this
    # is the gate that catches bash issues across all phases.
    # runtimeInputs: docker-client (`docker exec` / `docker ps`),
    # curl (per-workspace probes), jq (response parsing).
    runtimeInputs = [pkgs.docker-client pkgs.curl pkgs.jq];
    text = ''
      # Eval-time bindings from dev-env.nix exported as shell vars so
      # the per-phase scripts can reference them without each one
      # carrying Nix string-interpolation. Single source of truth in
      # dev-env.nix; phases speak shell only.
      export CLI_CONTAINER=${env.cliContainer}
      export OPENCODE_CONTAINER=${env.opencodeContainer}
      export NTFY_PORT=${toString env.ports.ntfy}
      export NTFY_TOPIC=${env.ntfyTopic}

      ${builtins.concatStringsSep "\n" phases}
    '';
  }
