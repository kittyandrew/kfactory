# Tail-of-suite banner. Lives in its own phase so lex order
# guarantees it runs LAST regardless of how many `10-*`, `11-*` etc.
# phases get added. Previously this was inlined at the bottom of
# 09-recovery.sh -- once phase 10 landed, the banner started firing
# mid-suite.

echo
echo "========================================================"
echo " Done."
echo " ntfy UI:  $NTFY_URL/$TOPIC"
echo "========================================================"
