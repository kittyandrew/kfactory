# Typescript Extra Guidelines
<!-- Location: .claude/rules/00-project/032-typescript.md -- code quality -->

typescript-exhaustive-switch: In switch statements over discriminated unions or enums, use a `never` check in the default case so newly added variants cause compile-time failures until handled.
