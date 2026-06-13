# Interactive dev VM: the factoryGuest profile + in-guest Keycloak,
# bootable rootless via `nix run .#dev-vm` (qemu, user-mode networking).
# Host-side quickstart lives in the README "Local dev VM" section.
#
# Port plan -- host forwards bind 127.0.0.1 and reuse the SAME guest
# numbers, so the OIDC issuer URL (http://127.0.0.1:8080/realms/
# kfactory-test) validates identically from inside the guest and from
# the host browser/CLI:
#   8080  Keycloak (browser device-flow page + token endpoint)
#   4096  opencode serve (web UI + API + kfactory CLI target)
#   2222 -> 22  sshd
#
# Trust boundary: the loopback-only forwards. opencode is intentionally
# NOT proxy-gated here (the Keycloak flake check covers the JWT-validated
# attach path); the fixed dev credentials below are safe ONLY because
# nothing beyond 127.0.0.1 can reach the forwards. Full proxy-gated
# ingress stays deployment-side.
{
  testRepo,
  realmFile,
}: {pkgs, ...}: let
  # The bundled base config defaults to a keyed model (openai/gpt-5.5) that
  # production has a key for; the dev VM has none, so a prompt would die with
  # ProviderModelNotFoundError. Override ONLY the model with one of opencode
  # zen's zero-key free models (deepseek-v4-flash-free: 200k ctx, reasoning +
  # tool calls, $0). opencode merges OPENCODE_CONFIG_CONTENT *on top of* the
  # baked OPENCODE_CONFIG (config.ts load order: global -> OPENCODE_CONFIG ->
  # project -> OPENCODE_CONFIG_CONTENT, deep-merged, last wins), so this tiny
  # patch wins for `model` while the base's plugins/permissions/instructions
  # stay intact -- no config fork, no coupling to the prod model literal.
  devModel = "opencode/deepseek-v4-flash-free";
in {
  microvm = {
    hypervisor = "qemu";
    vcpu = 4;
    mem = 6144;
    interfaces = [
      {
        type = "user";
        id = "dev-vm-net";
        mac = "02:00:00:00:00:43";
      }
    ];
    # host.address pins the forwards to loopback -- qemu slirp binds all
    # host interfaces when it is omitted, which would expose the
    # ungated opencode + fixed-credential Keycloak/sshd to the LAN.
    forwardPorts = [
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 4096;
        guest.port = 4096;
      }
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 8080;
        guest.port = 8080;
      }
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = 2222;
        guest.port = 22;
      }
    ];
    volumes = [
      {
        image = "dev-vm.img";
        mountPoint = "/var/lib/factory";
        size = 20 * 1024;
        fsType = "ext4";
        label = "factory-state";
      }
    ];
  };

  networking.hostName = "kfactory-dev-vm";
  networking.firewall.enable = false; # loopback-forwarded dev guest
  system.stateVersion = "25.11";

  services.kfactory.guest = {
    enable = true;
    bindAddress = "0.0.0.0"; # user-net forwards arrive on the guest NIC
    port = 4096;
    # Layer the free-model override onto the baked base config (see devModel
    # above). agent.build.model too -- the base sets it explicitly, so it
    # won't inherit the top-level default.
    environment.OPENCODE_CONFIG_CONTENT = builtins.toJSON {
      model = devModel;
      agent.build.model = devModel;
    };
  };

  # Pre-stage the device-flow-ready auth endpoints; same realm fixture as
  # the Keycloak flake check, so client ids/audience match it.
  services.keycloak = {
    enable = true;
    initialAdminPassword = "admin-password1234";
    realmFiles = [realmFile];
    database.passwordFile = "${pkgs.writeText "kc-db-password" "keycloak-dev-password"}";
    settings = {
      hostname = "127.0.0.1";
      hostname-strict = false;
      http-enabled = true;
      http-host = "0.0.0.0";
      http-port = 8080;
    };
  };

  # Local bare repo for network-free dispatch (same fixture as the e2e;
  # hyphenated name keeps slug-grammar hyphen support exercised here too).
  systemd.tmpfiles.rules = ["L+ /srv/test-repo.git - - - - ${testRepo}"];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };
  # Loopback-only dev guest; fixed throwaway credential by design.
  users.users.root.initialPassword = "dev";
}
