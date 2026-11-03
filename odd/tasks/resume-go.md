# resume-go — port resume-state.sh and resume-render.sh to `rsdd status resume-state|resume-render` (kit issue #2578)
Branch: feat/rsdd-status-resume-2578 (base origin/main 0c339974) · Delivery: small Conventional Commits, no push/PR · Runner: `go test` from research-sdd/rsdd (focused packages only) + the three bash suites through the shims

## Specs
- S1 (resume-state port): "`rsdd status resume-state` reproduces `research-sdd/toolbelt/resume-state.sh` (181 lines)." Contract: "`resume-state.v1.md` and `resume-render.v1.md` stay the contracts. Output must be byte-identical: the JSON document, the `--json` envelope, stderr lines and exit codes 0, 2 and 3." "The command stays read-only: `GIT_OPTIONAL_LOCKS=0`, no writes." "`gh` stays optional. When it is missing or times out, the document reports a typed `prs_status`. The output is never an empty array posing as a result." Acceptance: "Go unit, golden and differential tests. Oracle tests are `!nodiff`, and teeth (`make teeth`) shows Lived 0." "Reuse `internal/core/git`, `internal/core/gh` and `internal/core/envelope`."
- S2 (resume-render port): "`rsdd status resume-render` reproduces `research-sdd/toolbelt/resume-render.sh` (130 lines)." Same contract and acceptance bullets as S1 (byte-identical stdout, stderr and exit codes 0, 2, 3).
- S3 (shims): "Both scripts become `rsdd_exec` shims." Acceptance: "`resume-state.test.sh`, `resume-state-json.test.sh` and `resume-render.test.sh` pass through the shims."

## Tasks
- T1 (S1-S3) odd doc — inline — [ ]
- T2 (S1,S2) frozen legacy oracle, fixture harness, goldens, RED against a stub — inline — [ ]
- T3 (S1) implement `internal/status/resume` resume-state — inline — [ ]
- T4 (S2) implement resume-render — inline — [ ]
- T5 (S3) shims and the three bash suites — inline — [ ]
- T6 (S1-S3) vet, gofmt, archtest, mutation check — inline — [ ]

## Log
- L1 (issue #2578 Goal, verbatim):
  "Port `research-sdd/toolbelt/resume-state.sh` (181 lines) and `research-sdd/toolbelt/resume-render.sh` (130 lines) to Go as `rsdd status resume-state` and `rsdd status resume-render`. Both scripts become `rsdd_exec` shims. Part of the Go-port plan (epic #2270, status/state/init family)."
- L2 route: all tasks inline (one sequential unit; no parallel-writer reason). Risk: item 3 (replaces scripts others call; the shims keep argv, stdout, stderr and exit codes).
