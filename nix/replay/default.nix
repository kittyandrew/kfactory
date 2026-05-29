{
  pkgs,
  opencodeVersion,
  opencodeHeal,
}: let
  fixtureVersion = "v1.15.11";
  ptyLifecycleContract =
    pkgs.runCommand "factory-pty-lifecycle-contract" {
      src = ./pty-lifecycle-contract;
      nativeBuildInputs = [
        pkgs.bun
        pkgs.sqlite
      ];
    } ''
      export NTFY_SRC=${../../plugins/ntfy}
      export OPENCODE_HEAL=${opencodeHeal}/bin/opencode-heal
      export OPENCODE_SCHEMA=${./opencode-heal/fixtures/v1.15.11/schema.sql}
      export PTY_LIFECYCLE_CASES=$src/cases.json
      bun $src/check.ts
      touch $out
    '';
in
  if opencodeVersion != fixtureVersion
  then builtins.throw "opencode-heal fixture version ${fixtureVersion} does not match pinned opencode ${opencodeVersion}"
  else {
    factory-opencode-heal-fixtures =
      pkgs.runCommand "factory-opencode-heal-fixtures" {
        src = ./opencode-heal;
        nativeBuildInputs = [
          opencodeHeal
          pkgs.bash
          pkgs.sqlite
          pkgs.jq
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.diffutils
          pkgs.gnused
        ];
      } ''
        export OPENCODE_HEAL=${opencodeHeal}/bin/opencode-heal
        cd "$src"
        bash replay.sh
        touch $out
      '';
    factory-pty-lifecycle-contract = ptyLifecycleContract;
  }
