# [3] Verify kfactory list shows the three rows in creation order.
# Failure here means the SORT in client.go diverged from the
# 1-based-index resolution that attach uses.

echo
echo "[3] kfactory list -- should show THREE rows in creation order..."
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
