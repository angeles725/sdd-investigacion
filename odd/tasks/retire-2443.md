# Feature: retire unused kit tool families (kit issue #2443)
Objective: delete unblob, ifc, the Niagara tools (except palette-lexicon-agents) and the VM/Docker tooling with their wrappers, tests, fixtures and registry/doc rows.
Branch: chore/2443-retire-* (one per PR, based on origin/main). Delivery: chained PRs of <=~1.5k-line work-unit commits, each RDD-reviewed with --committed-only. Test runner: research-sdd/toolbelt/tests/run-all.sh (--impacted) + focused suites.

## Specs
- S1 (#2443, user decision 2026-11-01): "Niagara tools: ~/niagara-go ... already ships Go binaries for bog-nav, module-find, n4-type-catalog, station-modules, hdbread (= niagara-hdb-read), niagara-security-audit, px-render" — retire the kit copies.
- S2 (#2443): "VM/Docker tooling (vm-run, detonate/emba/fact/capture plans, lib/{vm_*,docker_*,qemu_exec,detonate_exec,trace_exec,capture_*,fact_exec,gate,plan_common,proc_common}.py): ... Drop U7 from the port and retire these tools from the kit."
- S3 (session 1, 2026-11-02): also retire "unblob and ifc (+lib/ifc_driver.py), with their .sh wrappers, tests, fixtures, registry/doc rows."
- S4 (session 1, 2026-11-02): "palette-lexicon-agents: KEEP and PORT to Go" — not deleted here.
- S5 (#2443): "Before deleting, enumerate the callers (hooks, skills, METHODOLOGY, tool-registry, tests) and the contract docs, and split the work into chained PRs".
- S6 (caller map): the fsx parity driver uses niagara_hdb_read (open_ro, open_wo_new, sha256_fd) — re-point or drop those 3 parity tests before deleting niagara_hdb_read.py.
- S7 (caller map): openspec/invariants.md INV lines that name a deleted test are edited in the same commit (process-integrity.test.sh).
- S8: per PR, run run-all --impacted origin/main, reason-codes.test.sh and the registry suites; full quiet-tree gate before merge.

## Tasks
- T1 S3 inline — A1 delete unblob (corroborate-unblob.sh/.py, unblob-evidence.v1.md, unblob.test.sh, fixtures, regen_unblob, registry/tier/discoverability/DEPENDENCIES/METHODOLOGY rows) — done 581a7101
- T2 S3 inline — A2 delete ifc (+lib/ifc_driver.py, ifc-evidence.v1.md, corroborate-ifc.test.sh, hermetic-fixtures ifc case, registry/DEPENDENCIES rows) — done 25c12288
- T3 S1,S6 inline — B0 re-point fsx parity driver, delete niagara-hdb-read — done (B0)
- T4 S1 — B delete bog-nav, n4-type-catalog, module-find, security-audit, px-render, station-modules (+hermetic-fixtures.test.sh last, NIAGARA-N4-FRAMEWORK.md:207) — pending
- T5 S2,S7 — C delete VM/Docker leaf-first (~12 commits), openspec/invariants.md + open openspec changes, mutant.sh VM kit, Go plan/exec stubs — pending
- T6 — deferred: PROFILE_BWRAP_UNBLOB/IFC_OFFLINE in lib/isolation_profile.py + internal/adapter/profile.go after #2453 merges — pending

## Log
- L1 (user, 2026-11-02): "necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, ... que el codgio de progrmaacion sea modular ... Si sabes alguna manera de optimizar o reducir el codigo." Session 1 assigned #2443 retirement to session 4.
- L2: caller map (origin/main 37e60eba): A ≈2.2k, B ≈10.3k (without palette), C ≈18k authored lines; no reason codes to remove; plan_common/proc_common/gate have no callers outside group C.
- L3: B0 re-pointed parity_driver.py: open_wo_new and sha256_fd now run serial-frame_analyze.py's live helpers; open_ro uses a frozen copy of the retired _open_ro (serial-frame's lacks O_NONBLOCK and blocks on a FIFO). Teeth: dropping O_NOFOLLOW reddens TestParityOpenRO/symlink; a constant digest reddens TestParitySHA256FD.
