# buildGoModule wrapper for the kfactory CLI.
#
# Endpoint defaults (main.defaultServer / Issuer / ClientID / Audience)
# are EMPTY in this upstream build. Consumers wrap with overrideAttrs:
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
# vendorHash: buildGoModule downloads the Go module graph via a fixed-
# output derivation keyed on this hash. To bump (or after changing
# go.mod/go.sum), set to lib.fakeHash, run `nix build`, copy the hash
# from the error.
{
  buildGoModule,
  installShellFiles,
  lib,
}:
buildGoModule {
  pname = "kfactory";
  version = "0.0.1";
  src = lib.cleanSource ./.;
  vendorHash = "sha256-63dcCbF2VhYJgp/WGlI1Le5qCEHMFzZYYTJKsqBcJ/A=";
  subPackages = ["cmd/kfactory"];
  nativeBuildInputs = [installShellFiles];
  postInstall = ''
    installShellCompletion --zsh ${./completions/_kfactory}
  '';
  meta = {
    description = "CLI for an opencode factory deployment (OIDC device flow, workspace dispatch + attach)";
    mainProgram = "kfactory";
    license = lib.licenses.agpl3Only;
  };
}
