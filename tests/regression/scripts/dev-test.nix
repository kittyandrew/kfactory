{pkgs}: let
  env = import ../dev-env.nix;
  # Each phase is a .sh under ./dev-test/. Driver exports a small
  # set of vars then concatenates every phase in lexicographic-by-
  # filename order (00-/01-/.../09-) -- filenames carry the ordering
  # so adding a phase is a single file drop. shellcheck runs against
  # the concatenated whole so cross-phase variable references gate.
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
    # writeShellApplication's shellcheck is the gate across all phases.
    runtimeInputs = [pkgs.docker-client pkgs.curl pkgs.jq];
    text = ''
      # Eval-time bindings exported once; phases speak shell only.
      export CLI_CONTAINER=${env.cliContainer}
      export OPENCODE_CONTAINER=${env.opencodeContainer}
      export NTFY_PORT=${toString env.ports.ntfy}
      export NTFY_TOPIC=${env.ntfyTopic}

      ${builtins.concatStringsSep "\n" phases}
    '';
  }
