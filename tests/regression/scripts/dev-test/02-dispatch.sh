# [2] Dispatch THREE workspaces against the bundled test repo.
# Each dispatch creates its own random-slug workspace + session; the
# returned workspace IDs are reused by later phases (attach
# resolution + per-workspace session isolation + the heal/recovery
# round-trip uses WS1 as its target).

echo
echo "[2] Dispatch THREE workspaces against $REPO..."
WS1=$(cli kfactory dispatch "$REPO" "say hi and immediately stop")
echo "      → ws1 = $WS1"
WS2=$(cli kfactory dispatch "$REPO" "echo done")
echo "      → ws2 = $WS2"
WS3=$(cli kfactory dispatch "$REPO" "list the files in this repo")
echo "      → ws3 = $WS3"
