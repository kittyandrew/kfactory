# Lifecycle scripts for the kfactory test harness.
#
# Mirrors mautrix-viber/nix/scripts/default.nix -- one file per command,
# registered here. `nix run .#dev-up` etc. resolve through flake.nix's
# `apps` attrset.
{pkgs}: {
  dev-up = import ./dev-up.nix {inherit pkgs;};
  dev-down = import ./dev-down.nix {inherit pkgs;};
  dev-clean = import ./dev-clean.nix {inherit pkgs;};
  dev-test = import ./dev-test.nix {inherit pkgs;};
}
