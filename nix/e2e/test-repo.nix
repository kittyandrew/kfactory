# Bare git repo with one trivial commit. Bundled into both images
# at /srv/test-repo.git so the regression tests never needs the public network:
# kfactory client dispatches against it; kfactory-adapter clones from
# it. Reproducible via Nix; built once, referenced from both image
# files.
{pkgs}:
pkgs.runCommand "kfactory-test-repo" {
  nativeBuildInputs = [pkgs.git];
} ''
  workdir=$(mktemp -d)
  cd "$workdir"
  export HOME="$workdir/h"
  mkdir -p "$HOME"
  git init -q --initial-branch=main .
  git config user.email "regression@kfactory.local"
  git config user.name "regression"
  cat > README.md <<'EOF'
  # kfactory regression test repo

  A trivial repo for end-to-end testing of `kfactory dispatch`. The
  regression tests clone this into per-workspace dirs to exercise the
  factory adapter without needing public-internet access.
  EOF
  cat > task.txt <<'EOF'
  Hello from the kfactory regression tests.
  EOF
  git add .
  git commit -q -m "init"

  git clone -q --bare . "$out"
''
