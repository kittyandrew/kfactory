{
  pkgs,
  kfactory,
  opencodePackage,
}: let
  regressionRunner = import ./regression-runner {inherit pkgs;};
in {
  factory-kfactory-auth-keycloak-integration = import ./kfactory-auth-keycloak.nix {
    inherit pkgs kfactory opencodePackage;
  };
  factory-e2e-regression-runner = regressionRunner;
}
