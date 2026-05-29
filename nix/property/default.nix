{
  pkgs,
  pluginSrcs,
}: let
  ntfySpec = pluginSrcs.ntfy;
in {
  factory-ntfy-plugin-property = pkgs.buildNpmPackage {
    pname = "factory-ntfy-plugin-property";
    version = "0";
    src = ntfySpec.src;
    npmDepsHash = ntfySpec.npmDepsHash;
    dontNpmBuild = true;
    nativeBuildInputs = [pkgs.bun];
    buildPhase = ''
      runHook preBuild
      bun test --test-name-pattern '^property:' test/*.test.ts
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      touch $out
      runHook postInstall
    '';
  };
}
