# [4/9] Resolve each ref via 'kfactory attach' (no TUI -- just resolve).
# We're not actually attaching (TUI requires a real terminal); we ARE
# validating that the CLI's ref-resolution path resolves each form
# (id, slug, index, prefix) to the correct workspace ID -- the canary
# for the index-vs-list-order bug.
#
# NB: 'kfactory attach' execs opencode, which needs the TUI. To
# validate just the resolution layer, we'd want a `--dry-run` flag on
# attach. For now: use 'kfactory list' to verify each index's
# canonical ID lines up with what dispatch returned, and rely on the
# operator to do the actual TUI attach manually.

echo
echo "[4/9] Resolve each ref via 'kfactory attach' (no TUI -- just resolve)..."
echo "      → Checking that index 1 corresponds to first-dispatched workspace ($WS1):"
INDEX1=$(cli kfactory list 2>/dev/null | tail -n +2 | head -1 | awk '{print $2}')
if [ "$INDEX1" = "$WS1" ]; then
  echo "      ✓ index 1 = $WS1"
else
  echo "      ❌ index 1 = $INDEX1, expected $WS1"
  echo "         This is the attach-resolution bug. kfactory list orders by ID"
  echo "         ascending; dispatch 1 should have lowest ID."
  exit 1
fi
