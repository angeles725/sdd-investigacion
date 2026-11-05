# Core consolidation — retire the Python adapter core

Objective: delete analysis_manifest.py, lib/adapter_core.py, lib/adapter_helpers.py and lib/isolation_profile.py once no production consumer remains; Go core/adapter is the only implementation. Delivery: ask-on-risk, one PR per task. Runner: go test (package-scoped) + toolbelt *.test.sh with --prove-teeth.

## Specs

- S1. "Necesitamos que se pase todo [a GO], para no perder tiempo en los test" — no production path loads or execs these four modules.
- S2. The Go shims (corroborate-capa.sh, squashfs-extract.sh, zip-metadata.sh, zip-stored.sh) stop passing `--manifest-cli <path to analysis_manifest.py>`; the Go commands accept the flag as optional and ignored (as native/ghidra already do) so existing callers do not break. Output of every command is byte-identical to before.
- S3. Test oracles that need the Python modules use frozen copies under the consuming package's testdata (campaign rule), never the live toolbelt files.
- S4. Docs: METHODOLOGY.md rule "MUST keep analysis_manifest.py" (≈:2213), DEPENDENCIES.md, requirements.txt, the .v1.md contracts and registries are updated to name the Go command.

## Tasks

- T1b (S2) [x] squashfs-extract, zip-metadata and zip-stored create and verify the manifest in process (core/adapter ManifestRun) instead of exec'ing `python3 analysis_manifest.py`; `--manifest-cli` stays required and validated, shims unchanged. Route: delegated writer (worktree). Commit: see Log L4.
- T1a (S2) DEFERRED to T3: drop `--manifest-cli` from all shims and make it optional/ignored in capa (args.go `required`, ~413 goldens lines in testdata/goldens/args.json, cli_units_test, usage) and in the three T1b commands, with the argv teeth.
- T2 (S3) freeze the four modules for the remaining C consumers (core/adapter manifest_driver.py, helpers parity driver, capa legacy oracle, profile_test.go, *.test.sh). Route: after floss/pcap/#2521/java merge.
- T3 (S1,S4) [x] delete the four modules and their toolbelt suites; doc updates. Route: after T2 and the java port (#2534). commit 5f3da59a + the docs commit (docs(toolbelt): point the adapter contracts at rsdd adapter manifest).

## Log

- L1 (2026-11-02, user): "Que es lo que se estaba haciendo? no estabamos haciendo la parte de portarlo de una vez?? ... Necesitmaos que se pase todo, para no perder tiempo en los test, etc, reucerda que debemos de portar todo a GO"
- L3 (T1 findings, writer): only capa validates `--manifest-cli` without exec'ing it. squashfs (`squashfs_unix.go` runManifestTool, 60 s) and zip (`zipout.go` zipRunManifest, 10 min) exec `python3 analysis_manifest.py create/verify`, and squashfs records `--manifest-cli <path>` in the spec "argv", so dropping the flag changes manifest bytes. Capa's required flag is encoded in ~413 lines of goldens. Coordinator decision: split T1 into T1b now (in-process manifest, flag kept) and T1a deferred to T3.
- L4 (T1b evidence): RED: manifest_inprocess_test.go TestSquashfsManifestNeedsNoPython — "squashfs-extract: python3 is required to run the manifest tool"; TestZipManifestNeedsNoPython/zip-metadata — "zip-metadata: proc: cannot start python3: executable file not found in $PATH" (same for zip-stored). Differential old vs new binary over 43 scenarios (22 zip-stored, 11 zip-metadata, 7 squashfs fixtures plus caps plus bad `--manifest-cli` for each): rc, stdout, stderr and every output file with mode identical after masking timestamps, digests and the binary path. Timeouts (60 s / 10 min) are gone with the exec: the in-process manifest has no bound.
- L2: consumer map (explorer, 2026-11-02): java is the only live Python consumer (blocked on #2534); shims pass --manifest-cli as a path the Go side never execs; zip_*.py/corroborate_capa.py already oracles. s4 owns the zip_*.py/bacnet oracle freeze (U4): T1 must not touch formats/testdata/zip or the zip parity drivers.
- L5 (T3 evidence): RED: stage-libs b3 pyform FAIL with analysis-side module files deleted, PASS after repointing the check at kaitai_driver.py. Focused suites green after the deletion. RDD lineage on 5f3da59a approved and acknowledged; independent verifier PASS. Docs commit repoints adapter-core, adapter-helpers, isolation-profile, analysis-manifest, firmware-static, native-static, capa-evidence and floss-evidence contracts at the Go packages and `rsdd adapter manifest <create|validate|verify>` (same flags as the Python CLI), and fixes the stale java/diff_test.go comment.
