# Central config for the kfactory dev e2e tests.
#
# Container names, pinned image versions, Docker volumes + network in
# one place so the lifecycle scripts and the image-build files share a
# single source of truth.
#
# Everything here is dev-only. Hardcoded paths + "bogus" tokens are NOT
# secrets; the e2e tests run on the operator's host, the containers
# don't expose anything past localhost.
{
  # Docker network -- a private bridge connecting all three containers.
  # ntfy + opencode + kfactory-cli reach each other by container name.
  network = "kfactory-devnet";

  # Container names.
  ntfyContainer = "kfactory-ntfy";
  opencodeContainer = "kfactory-opencode";
  cliContainer = "kfactory-cli";

  # Named Docker volumes -- managed by Docker, no host permission issues.
  volumes = {
    # opencode's SQLite DB + workspace clones live here. Persists between
    # dev-up/dev-down so an attach test can resume the workspaces a prior
    # dispatch created. `dev-clean` nukes it.
    opencodeData = "kfactory-opencode-data";
  };

  # Host port mappings. Operator interacts via these.
  ports = {
    # ntfy web UI + REST API. Open http://localhost:8080/<topic> to see
    # notifications arrive in real time.
    ntfy = 8080;
    # opencode HTTP server. Direct API access for debugging; the CLI
    # container talks to opencode via the container network, not this.
    opencode = 4096;
  };

  # Image tags built by Nix. Loaded into Docker by `dev-up`.
  images = {
    opencode = "kfactory-opencode:dev";
    cli = "kfactory-cli:dev";
  };

  # Topic the ntfy plugin publishes to. Operator opens this in a browser
  # to see the test notifications.
  ntfyTopic = "kfactory-e2e";
}
