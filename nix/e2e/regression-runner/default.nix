{pkgs}:
pkgs.buildGoModule {
  pname = "kfactory-e2e-runner";
  version = "0";
  src = pkgs.lib.cleanSource ../../..;
  vendorHash = "sha256-63dcCbF2VhYJgp/WGlI1Le5qCEHMFzZYYTJKsqBcJ/A=";
  subPackages = ["nix/e2e/regression-runner"];
}
