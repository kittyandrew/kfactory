# Central config for the regression tests. Dev-only; hardcoded paths and
# "bogus" tokens here are NOT secrets (containers stay on localhost).
{
  # Private bridge; containers reach each other by name.
  network = "kfactory-devnet";

  ntfyContainer = "kfactory-ntfy";
  opencodeContainer = "kfactory-opencode";
  clientContainer = "kfactory-client";

  volumes = {
    # opencode DB + workspace clones; persists across dev-up/dev-down
    # so `attach` resumes prior dispatches. `dev-clean` nukes it.
    opencodeData = "kfactory-opencode-data";
  };

  # Host port mappings (CLI container uses the docker network, not these).
  ports = {
    ntfy = 8080; # web UI: http://localhost:8080/<topic>
    opencode = 4097;
  };

  images = {
    opencode = "kfactory-opencode:dev";
    client = "kfactory-client:dev";
  };

  # ntfy topic the plugin publishes to (open in browser to watch).
  ntfyTopic = "kfactory-regression";
}
