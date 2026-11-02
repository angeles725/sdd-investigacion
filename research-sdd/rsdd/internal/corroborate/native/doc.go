// Package native is `rsdd corroborate native`: the port of toolbelt/corroborate_native.py (the driver behind
// corroborate-native.sh, schema native-static.v1).
//
// It produces bounded, non-executing radare2 evidence for one regular native binary: the input and the analyzer
// are copied into a private 0700 staging directory next to the output, radare2 runs inside Bubblewrap with no
// network, a read-only host root and synthetic HOME/XDG/TMP paths, the result is sealed by an
// analysis-manifest.v1 and the stage is published atomically without replacement. The evidence contract is
// toolbelt/native-static.v1.md.
//
// Layout (where to change what):
//
//	args.go       command line, defaults and cap validation
//	native.go     Run and the ordered pipeline (the only place that knows the step order)
//	stage.go      identity/staging of the input and the analyzer, trusted launcher lookup
//	sandbox.go    the Bubblewrap prefix, its environment and the fixed radare2 argv (SafeR2)
//	run.go        one bounded process run over core/proc, cap and timeout semantics
//	functions.go  radare2 `aflj` output to sorted function records
//	report.go     manifest spec and native-static.v1.json assembly
//	pyerr.go      Python-style error text for OS failures (kept for byte parity of stderr)
//
// Shared behaviour comes from internal/core: fsx (identity, staging, publish, atomic write), adapter (trusted
// executable, private-filesystem check, isolation profile, analysis manifest) and proc (bounded runs).
//
// Deliberate differences from the Python driver:
//   - the manifest is created and validated in-process through the adapter manifest port instead of a
//     `--manifest-cli` subprocess; the flag is still accepted and ignored so old command lines keep working;
//   - the private-filesystem check is core/adapter's allow-list (fail closed) instead of the old deny-list, so an
//     unknown filesystem type is refused too (lib/adapter-core.v1.md, known divergences);
//   - `runtime` names the Go toolchain (`go`) and the kernel; the Python version key is gone;
//   - option parsing is the stdlib flag package: no unambiguous-prefix abbreviations (`--in`), and usage errors
//     print Go's usage text with the same exit status 2;
//   - a failed `-v` probe or an empty version line is a typed exit 2 (Python crashed with a traceback or
//     CalledProcessError text); command-run failures use rsdd's wording instead of Python's repr of the argv;
//   - radare2 output is captured in memory by core/proc and written to engine/stdout.txt and engine/stderr.txt
//     afterwards, so --max-bytes also bounds this process's memory;
//   - a function record whose offset is not a number or whose name is not a string is `invalid-functions-json`
//     (Python raised TypeError while sorting);
//   - a configured launcher that does not exist is reported with core/adapter's wording
//     (`configured r2 path does not exist: ...`).
package native
