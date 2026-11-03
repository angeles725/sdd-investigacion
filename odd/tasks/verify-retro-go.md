# verify-retro-go — port verify-retro.sh to `rsdd retro verify` (issue #2586)
Objective: Go package internal/retro/verifyretro + `rsdd retro verify`; verify-retro.sh becomes an rsdd_exec shim. Branch: worktree-agent-a905be7f0dd4609af (base origin/main d25090ec). Delivery: single PR, commits <= ~1.4k lines each. Runner: go test (+ -tags nodiff), bash suites.

## Specs
- S1 parity: "Byte parity: stdout, stderr and the exit code match the frozen script. The differential runs the sha-pinned legacy oracle under `!nodiff`, and a Go-only golden replay runs under nodiff."
- S2 typed states: "Typed states stay distinct (CLAUDE.md §7)." absent-input (exit 2, `ERROR: file not found (absent-input)` / `file not readable (absent-input)`) stays distinct from non-conforming (exit 1) and from bad args (exit 2 usage / not-.md).
- S3 reuse: "Reuse: `internal/core/retrogrammar`, never a re-implemented grammar rule."
- S4 shim: verify-retro.sh is an `rsdd_exec retro verify "$@"` shim; its bash suite is cut to shim + wiring cases and every removed case maps to a Go test (case map in the Log).
- S5 registry: "`reason-codes.test.sh` maps the shim to its Go package (GO_SRC, #2583)." (the GO_SRC line is added by the orchestrator after #2585 merges; this unit reports the rows emitted); tool-registry.md row updated if the interface text changes.
- S6 teeth: "No lived mutant in the bridge teeth." Fleet sweep: "byte-identical against main on the real retros."

## Tasks
- T1 · S1 S3 · inline · feature doc, frozen oracle (legacy script + lib, sha-pinned), fixtures copied to testdata · pending
- T2 · S1 S2 S3 · inline · package verifyretro (Run/Render/Command), registration, differential RED then GREEN · pending
- T3 · S1 S6 · inline · goldens (whole-set regeneration), nodiff replay, unit tests, hand mutants · pending
- T4 · S4 S5 · inline · shim + bash suite trim + case map + planted-lib + registry row · pending
- T5 · S6 · inline · fleet sweep · pending

## Log
- L1 (2026-11-03, s2 orchestrator, issue #2586 body, verbatim): "Part of the Go port (go-port-lanes/PORT-QUEUE.md, s2 retro/sweep family). Port `research-sdd/toolbelt/verify-retro.sh` (251 lines) to Go as `rsdd retro verify` in its own package under `internal/retro`, and turn the script into an `rsdd_exec` shim. The Go retro-gate (`internal/gate`) runs verify-retro.sh as an external process today. Once the package exists, it can be called in process (separate follow-up). Acceptance: Byte parity: stdout, stderr and the exit code match the frozen script. The differential runs the sha-pinned legacy oracle under `!nodiff`, and a Go-only golden replay runs under nodiff. Typed states stay distinct (CLAUDE.md §7). Reuse: `internal/core/retrogrammar`, never a re-implemented grammar rule. `reason-codes.test.sh` maps the shim to its Go package (GO_SRC, #2583). No lived mutant in the bridge teeth. Fleet sweep: byte-identical against main on the real retros."
- L2: base verified: origin/main d25090ece3f335af5b0b7b750aab6667e2474197, tree clean.
- L3: analysis. retrogrammar already exports Read/Delta/HasHonesty. NOT exported and script-local (inline awk/grep in verify-retro.sh, not lib rules): the leading-comment block (no BOM strip, unlike retro-status.sh), the status regex over it, the `kit-retro: exclude` regex (not end-anchored, unlike retrogrammar.IsExcluded) and the `# Retro —` title probes. Ported locally with byte-exact semantics; no core change needed.
