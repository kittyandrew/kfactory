# [1/9] List any pre-existing workspaces. Informational only; the test
# is robust against leftover state from a prior dev-test run (each
# downstream phase either creates a fresh workspace or anchors on a
# known slug).

echo
echo "[1/9] Pre-check: list any existing workspaces..."
cli kfactory list || true
