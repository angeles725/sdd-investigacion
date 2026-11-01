# Feature: port lib/hook-wiring.sh part 2 to rsdd (kit issue #2357, U2.3b)

Objective: launch state, wired-exec report and the command helpers move to Go (research-sdd/rsdd/internal/hook); the bash functions become shims. Branch: feat/rsdd-hook-wiring-part2-2357 (base feat/rsdd-hook-wiring-2356 b6b8c8a9). Delivery: single slice, no PR (the orchestrator decides). Test runner: `go test ./internal/hook/...` plus the bash suites with RSDD_BIN set.

## Specs

- S1: "Port to rsdd (Go): lib/hook-wiring.sh (second half)".
- S2: "Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged."
- S3: "Suites that must stay green with --prove-teeth: hook-wiring, verify-registry-wired-exec."
- S4: "Acceptance: parity against the bash output over the suite fixtures (testkit/parity), strict TDD with RED executed on the pre-change SUT, mutation teeth, Go build hygiene (GOTMPDIR per lane, no leftover binaries)."
- S5: required export `func LaunchState(e Env, target string) string` returning exactly the bash tokens of hook_stop_launch_state (launched | no-sessions | unknown), as consts in states.go; plus an exported Go equivalent of hook_wired_exec_report; both documented in the package doc.
- S6: Env reads (HOME, RSDD_CLAUDE_PROJECTS_DIR, CLAUDE_CONFIG_DIR, cwd) only through Env; archtest bans os.Getenv/Getwd/time.Now outside internal/cli/stdio.go.
- S7: a batch form `rsdd hook launch-state <target>...` and a bash `hook_stop_launch_states_var`; no fork per target in a fleet loop.
- S8: unknown or failed rsdd answers degrade to the lib's documented state (launch: unknown; wired-exec: an `unverifiable` finding), never a silent success.

## Tasks

- [x] T1 (S1,S5) frozen oracle half 2 (sha-pinned, oracle_test.go) + differential/table/fuzz tests written first; RED = `go test ./internal/hook/` failed to build: `launch_test.go:46:73: undefined: LaunchLaunched` (and LaunchState, WiredExecReport, FormatFindings, splitCommand, headOf, Finding). inline. commit 01a2acf7
- [x] T2 (S5,S6) LaunchState + consts + `hook launch-state`. inline. commit 01a2acf7
- [x] T3 (S5) WiredExecReport + splitCommand/checkCommand + `hook wired-exec`. inline. commit 01a2acf7
- [x] T4 (S2,S7,S8) bash shims (`hook_stop_launch_state(_var)`, `hook_stop_launch_states_var`, `hook_wired_exec_report`), `_hw_abspath`/`_hw_split_cmd`/`_hw_unv`/`_hw_check_command` removed (no caller outside the lib and its own suites), suites adapted, parity cases. inline.
- [x] T5 (S3,S4) suites with --prove-teeth, Go checks, hand mutations (below). inline.

## Log

- L1 (issue #2357 body, verbatim): "Phase 2 unit of epic #2270 (plan: odd/tasks/go-port.md, Phase 2 table).\n\nPort to rsdd (Go): lib/hook-wiring.sh (second half) (paths under research-sdd/toolbelt/ unless prefixed).\nKeep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged.\nSuites that must stay green with --prove-teeth: hook-wiring, verify-registry-wired-exec.\nDepends on: U2.3a.\nAcceptance: parity against the bash output over the suite fixtures (testkit/parity), strict TDD with RED executed on the pre-change SUT, mutation teeth, Go build hygiene (GOTMPDIR per lane, no leftover binaries)."
- 2026-11-01: orchestrator brief (session 4). Decisions, all declared deviations from the bash:
  - Go parses settings.json itself, so the "jq not on PATH" text-match fallback of the bash report and its note have no Go counterpart (the shell lib no longer needs jq for this function).
  - encoding/json does not read the non-standard literals `NaN`/`Infinity` that jq reads: such a document reads as "not valid JSON" (loud, one unverifiable finding). A lone high-surrogate escape is rejected like jq does (loneHighSurrogate); everything else in the JSON grammar was compared against jq 1.8.2 by the differential tests (BOM, several top-level documents, duplicate keys: first position and last value, NUL, huge numbers).
  - The head of an unverifiable finding is the first 60 characters, and the leading blanks are `[[:space:]]` of a glibc UTF-8 locale (bash under LC_ALL=C.utf8, which the differential tests use); a bash run under the C locale cuts at 60 bytes.
  - The launch-history root is taken literally (bash globbed `$root/$enc/*.jsonl`, so a root holding `* ? [ \` was read as a pattern).
  - No batch form of wired-exec on the CLI: its output is multi-line per target and verify-registry will call `WiredExecReport` in process; the bash caller pays one fork per wired target.

## Hand mutation record (step 6)

Harness (outside the repo): `/home/cristian/rsdd-u23b-scratch/mutate.py`, one source edit per mutant, `go test ./internal/hook -run <table tests>` (the table, split, head, command and launch tests; the bash oracle is NOT in that run), file restored after each. 124 mutants: 116 killed, 8 equivalent (below); every first-run survivor was either fixed by a new test (`27c2` empty history dir, `S9` event key holding a newline, `TestWiredExecReadFailureIsTyped`, the `dir-noexec` fixture now mode 600) or proved equivalent.

Equivalent mutants (no observable difference): launch "no root at all reads a state" (the made-up root does not exist, so it is unknown anyway); launch "root of the walk counted" (`/` is never a symlink); exec "bare alone ignores a prefix" (n==1 with i>0 is unreachable: the earlier `i >= n` return); exec "truncated document accepted", "hooks array accepted", "event object accepted", "non-object group accepted", "non-string command accepted" (the next token read, or a nil/zero value, gives the same output).

Bash teeth that mutated moved code, and the Go mutant that carries them now:

| bash tooth | Go mutant (mutate.py name) |
|---|---|
| OPERATOR-STOP-DROPPED | exec: operator does not stop the words |
| NAMEVAL-NOT-SKIPPED | exec: NAME=value prefix not skipped / bad name does not stop prefixes |
| WRAP-EXEC-NOT-SKIPPED, WRAP-OPTION-GUESSED | exec/nohup/command wrapper not skipped (3), wrapper option guessed |
| WRAP-TIMEOUT-NOT-SKIPPED, TIMEOUT-DURATION-NOT-CONSUMED, TIMEOUT-OPTIONS-ACCEPTED | timeout not skipped, duration not consumed, options accepted, unit dropped |
| INTERP-REQUIRES-EXEC, INTERP-OPTION-TAKEN-AS-SCRIPT, INTERP-RELATIVE-ACCEPTED, QUOTED-INTERP-ACCEPTED | interpreter needs +x, option taken as script, relative script accepted, quoted interpreter accepted |
| ENV-OPTIONS-GUESSED | env not recognised / assignment / option / without interpreter accepted |
| CHAIN-NOT-REPORTED, BARE-ALONE-REPORTED | chain silently ignored, bare alone reported (+ operator variant) |
| BACKSLASH-IGNORED, UNTERMINATED-IGNORED, NO-COMMAND-WORD-IGNORED | backslash ignored, unterminated quote ignored, no command word ignored |
| VARGLOB-IGNORED, SQUOTE-EXPANDED, DQ-TILDE-EXPANDED | variable or glob accepted (+ one per glob character), single quote expanded, double-quoted tilde expanded |
| HOME-BRACE/PLAIN/TILDE-UNEXPANDED | `${HOME}`, `$HOME`, `~` unexpanded, empty HOME expanded |
| DIR-NOT-SKIPPED, EVENT-DROPPED | directory not skipped, event dropped from missing / not-executable |
| HOOKS-SCOPE-WIDENED, UNREADABLE-NOT-TYPED | statusLine read as a hook, unreadable settings not typed |
| NOEXEC-TEST-DROPPED, MISSING-NOT-REPORTED, PROJECT-DIR-UNEXPANDED (lib steeth) | execute bit not tested, missing not reported, project dir braces / plain unexpanded |
| NOJQ-NOTE-DROPPED, JQ-NOT-USED | gone with the jq fallback; L32 now asserts the report is the same without jq on PATH |
| hook-wiring.test.sh abs_tooth (dotdot, newline split, absolutize, join prefix) | abs: dotdot not collapsed, newline truncates the split, relative path not absolutized, join prefix dropped |
| hook-wiring.test.sh launch_tooth x10 (history check true / false, directory counted, any file, absent root, encoding, non-ASCII, symlink, config dir, long name) | launch: history check always true / false, empty history dir counts, any entry / suffix counts, root not a directory, encoding keeps dots, uppercase / digit / lowercase bounds, DEL / control / non-ASCII accepted, symlink guard dropped / leaf skipped, CLAUDE_CONFIG_DIR / HOME / override, long-name boundary and guard |

New bash teeth (kept in the suites): hook-wiring.test.sh 30-32 + the mutants after `shim_tooth` (launch fallback, exit status, target, three env hand-overs, batch count and vocabulary guards, wired-exec fallback, vocabulary, target); verify-registry-wired-exec.test.sh L33 + RSDD-FAILURE-SILENT.

- L-move (2026-11-01): per the architecture decision of sessions 1 and 2 (a domain may import only the core tier, so internal/verify cannot import internal/hook), the predicates, their command handlers (exported Run*) and their tests moved to internal/core/hookwiring; internal/hook keeps only the command registration and the testkit/parity cases. Behaviour unchanged: parity 22/22, hook-wiring --prove-teeth 182/0, verify-registry-wired-exec 45/0.
