# [6/9] /loop manual instructions. The /loop slash command needs a
# session context, which requires interactive TUI attach. Print the
# instructions; no automated assertions.

echo
echo "[6/9] Trigger /loop manually..."
echo "      The /loop slash command needs a session context, which"
echo "      requires interactive TUI attach. To exercise it manually:"
echo
echo "        docker exec -it $CLI_CONTAINER kfactory attach 1"
echo "        # Inside the TUI:"
echo "        /loop --max 3 --sentinel \"<promise>EXHAUSTIVELY COMPLETED</promise>\" count to three"
echo
echo "      After 2-3 iterations the agent should emit the sentinel"
echo "      and the loop terminates. Verify via:"
echo "        docker exec $CLI_CONTAINER ls /root/.local/state/kfactory-loop/"
echo "      (Empty dir = loop completed and cleared state.)"
