# kfactory CLI -- endpoint defaults (main.default{Server,Issuer,
# ClientID,Audience}) ship empty; consumers bake via overrideAttrs:
#
#   kfactory.overrideAttrs (old: {
#     ldflags = (old.ldflags or []) ++ [
#       "-X main.defaultServer=https://factory.example.com"
#       "-X main.defaultIssuer=https://auth.example.com"
#       "-X main.defaultClientID=12345"
#       "-X main.defaultAudience=67890"
#     ];
#   })
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
