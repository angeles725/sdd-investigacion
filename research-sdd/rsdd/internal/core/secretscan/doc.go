// Package secretscan is the engine of `rsdd secrets scan` (port of toolbelt/scan-secrets.sh, a leaked-secret-VALUE
// scanner for a Research-SDD corpus). It lives in the core tier so the domain command (internal/secretscan) and the
// corpus archive gate (internal/corpus) call the same code in process.
//
// Where to change what:
//
//	rules.go          the seven high-confidence patterns and the advisory keywords (data only)
//	scope.go          which file names and directories are in scope (data + predicates)
//	hcscan.go         high-confidence matching over a byte buffer
//	advisory.go       the credential-assignment keyword matcher (a PCRE lookaround emulation)
//	advisoryvalue.go  which extracted values are placeholders, too short or hashes
//	analyze.go        one buffer in, every finding out (HC, NUL-stripped HC, advisory, NUL flag)
//	walk.go           default mode: corpus-root narrowing and the directory walk
//	filesfrom.go      --files-from: list parsing and the per-entry degraded checks
//	history*.go       --committed: version-control enumeration, blobs and commit messages
//	gitrun.go         the Git seam (exec by default)
//	report.go         every line written to stdout, in legacy order
//	run.go            composition (Run)
//
// Detection is never weaker than the legacy script: where Go differs it scans more or says more
// (tool-registry.d/scan-secrets.md lists each divergence).
package secretscan
