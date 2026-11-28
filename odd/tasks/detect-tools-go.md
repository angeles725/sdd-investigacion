Port detect-tools.sh to Go (issue 2576). Branch: feat/detect-tools-go. Delivery: single PR, per-commit RDD.
Test runner: go test (default + -tags nodiff), rsdd-go.test.sh, run-all.sh --impacted via heavy-run.

## Specs
- S1: "Port research-sdd/toolbelt/detect-tools.sh (406 lines) to an rsdd command, keep the bash path as a shim calling rsdd, with differential parity against the frozen bash behaviour (stdout, stderr, exit code) and Go teeth."
- S2: "Reuse internal/core/probe (the tool-env port) for tool probing."
- S3: Every existing caller and test of detect-tools.sh keeps its observable behaviour (stdout, stderr, exit code).

## Tasks
- T1 · S1-S3 · delegated (writer reason: parent keeps orchestrating 4 lanes; context backstop) · landing: commits 1de1226b..38a554ab on 12ec3a8e; teeth Killed 136 Lived 0; gate 184/185 + lint fix 

## Log
- L1 (2026-11-03, user): "Y bash no es más rápido el hacer el port qué python? De igual forma tu sigue trabajando para tener todo en GO"
- L2 (2026-11-03): writer done: rsdd install detect-tools + 3-line shim, differential tests vs frozen script, suite 37/0 (+1 SKIP case h -> TestJavaRows). Teeth Lived 6 must reach 0 before PR. Risk item 3 (contract others consume) -> independent verifier before merge.
- L3 (2026-11-03): independent verifier PASS (no parity blocker); correction batch: install.sh stale cache on rsdd-unavailable, hermetic differential tests, registry exit-2 wording, HOME unset, suite teeth banner.
- L4 (2026-11-03): final batch 7abf1aec (GO_NO_TYPED, java asserts, (no stderr)); gate found lib-resolution-lint missing shim -> 38a554ab; all 8 commits RDD approved; PR opened via land-pr.
