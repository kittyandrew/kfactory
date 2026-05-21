---
description: Auto-continue the current session until a user-defined sentinel string appears in your output
---

# /loop

Start an auto-continuation loop. After your turn ends (`session.idle`),
the plugin checks the **last non-empty line** of the last assistant
message: if that trimmed line equals the configured sentinel exactly,
the loop terminates; otherwise it re-prompts you to continue. The loop
also stops once `--max` iterations are reached.

## Arguments

Parse `$ARGUMENTS` as a flag-style command line:

- `--max N` — maximum iterations before auto-stop. Must be an integer in
  [1, 10000]. Default `100`.
- `--sentinel "<exact string>"` — the literal string you must emit AS
  THE LAST LINE of your turn to signal completion. Default:
  `<promise>EXHAUSTIVELY COMPLETED</promise>`. The sentinel may be any
  user-defined phrase, including multi-word sentences like
  `I FULLY COMPLETED SPEC IMPLEMENTATION AND RESOLVED ALL OPEN QUESTIONS`.
  The matcher does **last-non-empty-line trimmed equality**, case-sensitive:
  the model has to emit the sentinel as its concluding line, with no
  trailing prose, punctuation, or follow-up sentences. Mentioning the
  sentinel mid-response (in a plan, a paraphrase, a quoted prompt) does
  not terminate the loop.
- Remaining text after the flags is the task prompt.

Examples:

- `/loop build a REST API with JWT auth`
  -> `{maxIterations: 100, sentinel: "<promise>EXHAUSTIVELY COMPLETED</promise>", task: "build a REST API with JWT auth"}`
- `/loop --max 50 fix all failing tests`
  -> `{maxIterations: 50, sentinel: "<promise>EXHAUSTIVELY COMPLETED</promise>", task: "fix all failing tests"}`
- `/loop --sentinel "ALL DONE" --max 25 refactor the auth module`
  -> `{maxIterations: 25, sentinel: "ALL DONE", task: "refactor the auth module"}`

## Action

Call the `loop-start` tool with the parsed `{task, maxIterations, sentinel}`,
then begin working on the task.

When you have fully and verifiably completed the task, emit the sentinel
string as the LAST line of your response (final non-empty line, trimmed,
matching exactly). Do NOT emit it as part of a plan, a paraphrase, or
mid-response speculation — only the trailing line is checked, so a
mid-response mention is harmless but a trailing punctuation mark
("ALL DONE." instead of "ALL DONE") will leave the loop running.

To stop the loop early, the operator can run `/loop-stop`.
