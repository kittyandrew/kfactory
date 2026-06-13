{pkgs}: let
  env = import ../e2e/dev-env.nix;
  runner = import ../e2e/regression-runner {inherit pkgs;};
in
  pkgs.writeShellApplication {
    name = "dev-test";
    runtimeInputs = [pkgs.docker-client pkgs.curl pkgs.jq];
    text = ''
      export CLI_CONTAINER=${env.clientContainer}
      export OPENCODE_CONTAINER=${env.opencodeContainer}
      export NTFY_PORT=${toString env.ports.ntfy}
      export NTFY_TOPIC=${env.ntfyTopic}
      exec ${runner}/bin/regression-runner
    '';
  }
