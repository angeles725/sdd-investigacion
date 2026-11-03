# resume-go — port resume-state.sh and resume-render.sh to `rsdd status resume-state|resume-render` (kit issue #2578)
Branch: feat/rsdd-status-resume-2578 (base origin/main 0c339974) · Delivery: small Conventional Commits, no push/PR · Runner: `go test` from research-sdd/rsdd (focused packages only) + the three bash suites through the shims

## Specs
- S1 (resume-state port): "`rsdd status resume-state` reproduces `research-sdd/toolbelt/resume-state.sh` (181 lines)." Contract: "`resume-state.v1.md` and `resume-render.v1.md` stay the contracts. Output must be byte-identical: the JSON document, the `--json` envelope, stderr lines and exit codes 0, 2 and 3." "The command stays read-only: `GIT_OPTIONAL_LOCKS=0`, no writes." "`gh` stays optional. When it is missing or times out, the document reports a typed `prs_status`. The output is never an empty array posing as a result." Acceptance: "Go unit, golden and differential tests. Oracle tests are `!nodiff`, and teeth (`make teeth`) shows Lived 0." "Reuse `internal/core/git`, `internal/core/gh` and `internal/core/envelope`."
- S2 (resume-render port): "`rsdd status resume-render` reproduces `research-sdd/toolbelt/resume-render.sh` (130 lines)." Same contract and acceptance bullets as S1 (byte-identical stdout, stderr and exit codes 0, 2, 3).
- S3 (shims): "Both scripts become `rsdd_exec` shims." Acceptance: "`resume-state.test.sh`, `resume-state-json.test.sh` and `resume-render.test.sh` pass through the shims."

## Tasks
- T1 (S1-S3) odd doc — inline — [x] 4d978701
- T2 (S1,S2) frozen legacy oracle, fixture harness, goldens, RED against a stub — inline — [x] 5b1d5d32 (oracle + goldens), 1adf0873 (harness). RED: 406 of 406 scenario subtests (TestGolden and TestDifferential) failed against the stub (`rc: 99`, empty stdout vs the recorded script output).
- T3 (S1) implement `internal/status/resume` resume-state — inline — [x] 70132dcf
- T4 (S2) implement resume-render — inline — [x] 70132dcf (same slice: the two share the JSON value model), tests 72ab7d5e
- T5 (S3) shims and the three bash suites — inline — [x] a27c17e3
- T6 (S1-S3) vet, gofmt, archtest, hand mutation check — inline — [x] 29 hand mutants run under `-tags nodiff`, 25 killed at once; 4 lived: `--no-optional-locks` (equivalent: redundant with `GIT_OPTIONAL_LOCKS=0`, kept as in the script), the toolbelt trailing-slash trim (equivalent: dead code, removed), and `len(mapped) == 1` and `st.IsDir()` (both got tests and were then killed)

## Log
- L1 (issue #2578 Goal, verbatim):
  "Port `research-sdd/toolbelt/resume-state.sh` (181 lines) and `research-sdd/toolbelt/resume-render.sh` (130 lines) to Go as `rsdd status resume-state` and `rsdd status resume-render`. Both scripts become `rsdd_exec` shims. Part of the Go-port plan (epic #2270, status/state/init family)."
- L3 intended differences from the scripts (not reproduced on purpose): (a) gh output of more than one JSON document: bash prints `[: integer expression expected` naming its own path, the Go port is silent (still ok, truncated false); (b) a gh that exits 137 reads as timeout (core/gh) instead of gh-failed; (c) gh runs without GH_REPO and with GH_PROMPT_DISABLED=1 (core/gh); (d) `--json` with a PR number that is not a plain integer (7.0, 1e2) fails with `--json envelope build failed` (the envelope renderer has no number type), the default document keeps the literal; (e) `repo:false` renders `render failed: jq: error (at <unknown>): ...` (jq's message names a temp file); (f) the jq-stub cases of the suites (a failing jq) became SKIPs: the port has no jq step, but the typed `DEGRADED: jq not found` probe is kept so a missing jq still reads as rc 3; (g) the bound of the gh call is 30 s as in the script, overridable only through RSDD_RESUME_GH_TIMEOUT (used by a test).
- L2 route: all tasks inline (one sequential unit; no parallel-writer reason). Risk: item 3 (replaces scripts others call; the shims keep argv, stdout, stderr and exit codes).
