{pkgs}:
pkgs.mkShell {
  packages = with pkgs; [
    # Nix
    alejandra
    deadnix
    # GitHub Actions
    actionlint
    zizmor
    # Go (kfactory CLI)
    go
    golangci-lint
    # TypeScript plugins (dep-bump workflow per .claude/rules/010-plugin.md)
    nodejs_22
    prefetch-npm-deps
    # Patch re-diff workflow per .claude/rules/021-patches-rediff.md
    patch
    git
    # Secrets scan; same dev-shell + CI surface as the other
    # code-quality linters. Allowlist in .betterleaks.toml.
    betterleaks
  ];
}
