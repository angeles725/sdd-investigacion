### stage-retro-issues (#2770)

Intended divergences of `rsdd retro stage-issues` from the frozen legacy script `stage-retro-issues.sh`, beyond the main registry row.

Kit root (#2770): the path of the kit is found without naming the legacy script.

| Divergence | Legacy script | Port |
|---|---|---|
| Kit found without `--kit` (#2770) | The kit was found by resolving the legacy script `stage-retro-issues.sh` and keeping its directory: a kit without that script failed with `<kit>/toolbelt/stage-retro-issues.sh is missing`, and a directory without `toolbelt/` was reported as `research-sdd kit not found`. | `rsdd retro stage-issues` finds the kit root (`RESEARCH_SDD_KIT`, the launcher files, the default checkout; the first with a `toolbelt/` directory) without naming a script, so a kit whose legacy script was deleted resolves. A directory that exists but holds no `toolbelt/` is its own error: `research-sdd kit has no toolbelt/ directory: <dir> (set RESEARCH_SDD_KIT)`. The path text for a kit given with a trailing slash, a `.` segment or as a relative path is unchanged. `internal/retro/stageissues/kitroot_site_test.go`. |
