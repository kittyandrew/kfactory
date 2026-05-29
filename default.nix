# kfactory CLI. Endpoint defaults are runtime env vars:
# KFACTORY_SERVER, KFACTORY_OIDC_ISSUER, KFACTORY_OIDC_CLIENT_ID,
# KFACTORY_OIDC_AUDIENCE.
#
# Refresh vendorHash after go.mod/go.sum changes: set to lib.fakeHash,
# `nix build`, copy the hash from the error.
{
  buildGoModule,
  installShellFiles,
  lib,
  # Short `kf` alias: real symlink in $out/bin (not a shell alias) so it
  # works in scripts, non-interactive shells, and completion contexts.
  # Same shape as nixpkgs vim/vi. Toggle off when `kf` collides with
  # another binary on the host (e.g. Cloud Foundry's kf CLI).
  enableShortAlias ? true,
}:
buildGoModule {
  pname = "kfactory";
  version = "0.0.1";
  src = lib.cleanSource ./.;
  vendorHash = "sha256-63dcCbF2VhYJgp/WGlI1Le5qCEHMFzZYYTJKsqBcJ/A=";
  subPackages = ["cmd/kfactory"];
  nativeBuildInputs = [installShellFiles];
  postInstall =
    ''
      installShellCompletion --zsh ${./completions/_kfactory}
    ''
    + lib.optionalString enableShortAlias ''
      ln -s kfactory $out/bin/kf
    '';
  meta = {
    description = "CLI for an opencode factory deployment (OIDC device flow, workspace dispatch + attach)";
    mainProgram = "kfactory";
    license = lib.licenses.agpl3Only;
  };
}
