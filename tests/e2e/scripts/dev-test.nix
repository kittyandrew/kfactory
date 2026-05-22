{pkgs}: let
  env = import ../dev-env.nix;
in
  pkgs.writeShellScriptBin "dev-test" ''
    set -euo pipefail
    if ! command -v docker &>/dev/null; then
      echo "ERROR: Docker not found. Run dev-up first."
      exit 1
    fi

    if ! docker ps -q --filter "name=^${env.cliContainer}$" | grep -q .; then
      echo "ERROR: ${env.cliContainer} not running. Run 'nix run .#dev-up' first."
      exit 1
    fi

    # `cli` rather than `exec` because `exec` is a shell builtin that
    # replaces the current process -- shadowing it with a function would
    # silently break any future `exec foo` line in the script.
    cli() { docker exec -i ${env.cliContainer} "$@"; }

    REPO="file:///srv/test-repo.git"
    NTFY_URL="http://localhost:${toString env.ports.ntfy}"
    TOPIC="${env.ntfyTopic}"

    echo
    echo "========================================================"
    echo " kfactory e2e validation"
    echo "========================================================"

    echo
    echo "[1/6] Pre-check: list any existing workspaces..."
    cli kfactory list || true

    echo
    echo "[2/6] Dispatch THREE workspaces against $REPO..."
    # Each dispatch creates its own slug + session. We capture stdout
    # (workspace IDs) for the attach-correctness check below.
    WS1=$(cli kfactory dispatch "$REPO" "say hi and immediately stop")
    echo "      → ws1 = $WS1"
    WS2=$(cli kfactory dispatch "$REPO" "echo done")
    echo "      → ws2 = $WS2"
    WS3=$(cli kfactory dispatch "$REPO" "list the files in this repo")
    echo "      → ws3 = $WS3"

    echo
    echo "[3/6] kfactory list -- should show THREE rows in creation order..."
    cli kfactory list
    # `grep -c` exits 1 on zero matches, leaving LIST_COUNT empty under
    # `|| true` -- the subsequent `[ "$LIST_COUNT" -lt 3 ]` then crashes
    # with "integer expression expected". `|| echo 0` keeps the value
    # numeric so the integer compare reports the intended error instead.
    LIST_COUNT=$(cli kfactory list 2>/dev/null | tail -n +2 | grep -c "wrk_" || echo 0)
    if [ "$LIST_COUNT" -lt 3 ]; then
      echo "      ❌ expected at least 3 workspaces, got $LIST_COUNT"
      exit 1
    fi
    echo "      → $LIST_COUNT workspaces visible"

    echo
    echo "[4/6] Resolve each ref via 'kfactory attach' (no TUI -- just resolve)..."
    # We're not actually attaching (TUI requires a real terminal); we
    # ARE validating that the CLI's ref-resolution path resolves each
    # form (id, slug, index, prefix) to the correct workspace ID.
    # This is the canary for the bug you're hunting.
    #
    # NB: 'kfactory attach' execs opencode, which needs the TUI. To
    # validate just the resolution layer, we'd want a `--dry-run` flag
    # on attach. For now: use 'kfactory list' to verify each index's
    # canonical ID lines up with what dispatch returned, and rely on
    # the operator to do the actual TUI attach manually.
    echo "      → Checking that index 1 corresponds to first-dispatched workspace ($WS1):"
    INDEX1=$(cli kfactory list 2>/dev/null | tail -n +2 | head -1 | awk '{print $2}')
    if [ "$INDEX1" = "$WS1" ]; then
      echo "      ✓ index 1 = $WS1"
    else
      echo "      ❌ index 1 = $INDEX1, expected $WS1"
      echo "         This is the attach-resolution bug. kfactory list orders by ID"
      echo "         ascending; dispatch 1 should have lowest ID."
    fi

    echo
    echo "[5/6] Subscribe to ntfy + verify session.idle notification fires..."
    # Spawn a 15-second background subscriber to the topic. The test
    # dispatch from step 2 should trigger session.idle within seconds,
    # and the ntfy plugin's 3s notifyAfter window will fire.
    NTFY_LOG=$(mktemp)
    (timeout 15 curl -s "$NTFY_URL/$TOPIC/json" > "$NTFY_LOG" || true) &
    NTFY_PID=$!
    sleep 12
    wait $NTFY_PID 2>/dev/null || true

    if grep -q '"message"' "$NTFY_LOG"; then
      echo "      ✓ ntfy received at least one notification:"
      grep '"message"' "$NTFY_LOG" | head -3 | sed 's/^/         /'
    else
      echo "      ❌ no ntfy messages in 15s window. Possible causes:"
      echo "         - ntfy plugin failed to load (check opencode logs)"
      echo "         - notifyAfter=3 didn't expire in time (agent still busy)"
      echo "         - server.error path firing instead of session.idle"
      echo "      Captured ntfy stream:"
      cat "$NTFY_LOG" | sed 's/^/         /'
    fi
    rm -f "$NTFY_LOG"

    echo
    echo "[6/6] Trigger /loop manually..."
    echo "      The /loop slash command needs a session context, which"
    echo "      requires interactive TUI attach. To exercise it manually:"
    echo
    echo "        docker exec -it ${env.cliContainer} kfactory attach 1"
    echo "        # Inside the TUI:"
    echo "        /loop --max 3 --sentinel \"<promise>EXHAUSTIVELY COMPLETED</promise>\" count to three"
    echo
    echo "      After 2-3 iterations the agent should emit the sentinel"
    echo "      and the loop terminates. Verify via:"
    echo "        docker exec ${env.cliContainer} ls /root/.local/state/kfactory-loop/"
    echo "      (Empty dir = loop completed and cleared state.)"

    echo
    echo "========================================================"
    echo " Done."
    echo " ntfy UI:  http://localhost:${toString env.ports.ntfy}/$TOPIC"
    echo "========================================================"
  ''
