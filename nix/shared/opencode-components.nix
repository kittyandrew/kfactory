{
  pkgs,
  system,
  opencode,
  opencodePatchStack,
}: let
  mkOpencodeNodeModulesConfigurePhase = import ./opencode-node-modules.nix;

  opencodePatched =
    (opencode.packages.${system}.default.override {
      node_modules = opencode.packages.${system}.node_modules_updater.override {
        hash = "sha256-FT8N4SBP7OmVu73OwNyPJvBoxFd2+IXzNnFubB8y6J0=";
      };
    }).overrideAttrs (old: {
      # @WARNING (patch order): DO NOT REORDER. kfactory-refresh is line-pinned
      # against static-bearer + workspace-routing post-apply hashes; see
      # .claude/rules/020-patches.md and 021-patches-rediff.md.
      patches = (old.patches or []) ++ opencodePatchStack;
      configurePhase = mkOpencodeNodeModulesConfigurePhase {
        inherit pkgs;
        nodeModules = old.node_modules;
      };
    });

  opencodeHeal = pkgs.writeShellApplication {
    name = "opencode-heal";
    # writeShellApplication locks PATH to runtimeInputs. `grep` is
    # NOT in coreutils -- omitting gnugrep silently empties the
    # heal queue (a `grep -v '^$' | sort -u` step in a `|| true`
    # chain swallows the error).
    runtimeInputs = [pkgs.sqlite pkgs.jq pkgs.coreutils pkgs.gnugrep];
    text = builtins.readFile ../../modules/scripts/opencode-heal.sh;
  };

  opencodeSyncKick = pkgs.writeShellApplication {
    name = "opencode-sync-kick";
    runtimeInputs = [pkgs.curl pkgs.jq pkgs.coreutils];
    text = builtins.readFile ../../modules/scripts/opencode-sync-kick.sh;
  };
in {
  inherit opencodePatched opencodeHeal opencodeSyncKick;
}
