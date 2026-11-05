### verify-skill-drift (#2592)

Intended divergences of `rsdd verify skill-drift` (the Go port behind `verify-skill-drift.sh`, kit issue #2365) from the frozen legacy script. Everything else is pinned against the sha-pinned script by `internal/verify/skilldrift_diff_test.go` (`!nodiff`).

| Divergence | Legacy script | Port |
|---|---|---|
| The throwaway render dir cannot be created (`$TMPDIR` missing or unwritable) | `tmp="$(mktemp -d)" \|\| return 2`: mktemp's own message (`mktemp: failed to create directory via template ...`) then the could-not-run line. | One line in Go's wording naming the path and the error, `verify-skill-drift: cannot create a throwaway render dir: <error>`, then the same could-not-run line and exit code. `TestSkillDriftRenderHonoursTMPDIR`. |
