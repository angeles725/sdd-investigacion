### verify-skill-drift (#2592)

Intended divergences of `rsdd verify skill-drift` (the Go port behind `verify-skill-drift.sh`, kit issue #2365) from the frozen legacy script. Everything else is pinned against the sha-pinned script by `internal/verify/skilldrift_diff_test.go` (`!nodiff`).

| Divergence | Legacy script | Port |
|---|---|---|
| The throwaway render dir cannot be created (`$TMPDIR` missing or unwritable) | `tmp="$(mktemp -d)" \|\| return 2`: mktemp's own message (`mktemp: failed to create directory via template ...`) then the could-not-run line. | One line in Go's wording naming the path and the error, `verify-skill-drift: cannot create a throwaway render dir: <error>`, then the same could-not-run line and exit code. `TestSkillDriftRenderHonoursTMPDIR`. |

Kit root (#2770): the path of the kit is found without naming the legacy script.

| Divergence | Legacy script | Port |
|---|---|---|
| Kit found without `--kit` (#2770) | The kit was found by resolving the legacy script `verify-skill-drift.sh` and keeping its directory: a kit without that script failed with `<kit>/toolbelt/verify-skill-drift.sh is missing`, and a directory without `toolbelt/` was reported as `research-sdd kit not found`. | `rsdd verify skill-drift` finds the kit root (`RESEARCH_SDD_KIT`, the launcher files, the default checkout; the first with a `toolbelt/` directory) without naming a script, so a kit whose legacy script was deleted resolves. A directory that exists but holds no `toolbelt/` is its own error: `research-sdd kit has no toolbelt/ directory: <dir> (set RESEARCH_SDD_KIT)`. The path text for a kit given with a trailing slash, a `.` segment or as a relative path is unchanged. `internal/verify/kitroot_site_test.go`. |
