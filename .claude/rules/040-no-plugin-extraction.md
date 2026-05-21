# Do NOT propose extracting plugins/shared/
<!-- plugins -- explicit no-go: shared module extraction -->

Across multiple architect reviews, the suggestion of "extract
`plugins/_shared/` for isSubagentSession / isRecord / OpencodeClient
alias / xdgPath" has come up repeatedly as a code-smell finding.

**The operator has explicitly decided NOT to extract.** Duplication
between the three plugins is intentional. Reasons:

- Each plugin is small and operator-owned; the cost of the duplication
  is far less than the cost of an extra workspace package, additional
  flake-output, tsconfig path-mapping, and synchronized type-bump
  workflow.
- The plugins evolve independently; a shared abstraction would couple
  their release cadence.
- The cross-plugin duplication is grep-visible and the helpers are
  small enough to read in place.

**Action for future reviewers / agents**: do not flag duplication
across plugins as a finding to fix. Do not propose creating
`plugins/_shared/`, `plugins/_common/`, `@kfactory/shared`, or any
similar package. If you spot the duplication, simply note it as
"deliberate per .claude/rules/040" and move on.

If the operator later changes their mind, this rule will be removed
or updated. Until then, treat the duplication as a load-bearing
design choice.
