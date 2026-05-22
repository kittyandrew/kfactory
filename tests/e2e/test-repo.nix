# Bare git repo seeded with one trivial commit. Mounted into both
# images so:
#   - kfactory-cli can dispatch against `file:///srv/test-repo.git`
#   - opencode-kfactory's kfactory-adapter plugin can `git clone` it
#     into a per-workspace dir under /var/lib/kfactory/workspaces/
#
# Built once, referenced from both kfactory-cli-image.nix and
# opencode-image.nix so the e2e tests never hits the public network.
{pkgs}:
pkgs.runCommand "kfactory-test-repo" {
  nativeBuildInputs = [pkgs.git];
} ''
  workdir=$(mktemp -d)
  cd "$workdir"
  export HOME="$workdir/h"
  mkdir -p "$HOME"
  git init -q --initial-branch=main .
  git config user.email "e2e@kfactory.local"
  git config user.name "e2e"
  cat > README.md <<'EOF'
  # kfactory e2e test repo

  A trivial repo for end-to-end testing of `kfactory dispatch`. The
  the e2e tests clone this into per-workspace dirs to exercise the factory
  adapter without needing public-internet access.
  EOF
  cat > task.txt <<'EOF'
  Hello from the kfactory e2e tests.
  EOF
  git add .
  git commit -q -m "init"

  git clone -q --bare . "$out"
''
