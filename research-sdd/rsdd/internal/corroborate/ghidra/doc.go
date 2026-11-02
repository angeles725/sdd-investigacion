// Package ghidra is `rsdd corroborate ghidra`: the port of toolbelt/corroborate_ghidra.py and of the tool
// resolution that corroborate-ghidra.sh did in bash (schema ghidra-corroboration.v1; the exporter it drives,
// toolbelt/ghidra/CuratedEvidenceExporter.java, stays Java and its contract is toolbelt/ghidra-curated-evidence.v1.md).
//
// The adapter copies the input, the exporter script, Bubblewrap, the Ghidra launch chain and the JDK launcher into
// a private 0700 staging directory, locks every staged file by an open descriptor (the descriptor, not the path,
// is what the sandbox executes and binds), runs Ghidra's headless analyzer in Bubblewrap with no network and a
// read-only host root, validates the curated JSON the exporter wrote, seals everything with an
// analysis-manifest.v1 and publishes the stage atomically without replacement.
//
// Layout (where to change what):
//
//	args.go       command line and defaults
//	resolve.go    the shim's job: Ghidra home, JDK, Java launcher, Bubblewrap and the exporter path
//	ghidra.go     Run and the ordered pipeline
//	trust.go      trusted launcher checks (owner, mode, PATH identity, ancestor chain)
//	stage.go      staging with identity checks, the descriptor locks and their re-verification
//	command.go    the Bubblewrap command, the environment and the Ghidra argv
//	runner_unix.go the bounded run: wall clock, diagnostic-size watch, process-group reaping
//	curated.go    strict validation of the exporter's curated JSON
//	report.go     report.json and the manifest spec
//
// Shared behaviour comes from internal/core: fsx (identity, staging, publish, atomic write), adapter (private
// filesystem check, isolation profile, analysis manifest), probe (Ghidra and JDK discovery) and proc (the
// process-group kill guard).
//
// Deliberate differences from the Python driver and its shim:
//   - the manifest is created and validated in-process through the adapter manifest port, so the manifest CLI is
//     no longer staged: `provenance` has 9 entries (the exporter, Bubblewrap, six Ghidra launch-chain files and
//     the Java launcher) instead of 10, and `tool/manifest.py` is gone from the manifest's tool artifacts. The
//     `--manifest-cli` flag (and the other legacy path flags the shim used to pass) is accepted and ignored;
//   - Ghidra, the JDK and Bubblewrap are resolved by the command itself with the same rules the shim used
//     (internal/core/probe); `--toolbelt DIR` (or the resolved kit) locates the exporter, `--exporter FILE` overrides it;
//   - `RSDD_TEST_ONLY_UNTRUSTED_BWRAP=1` still selects the test-only launcher mode, as does `--test-only-untrusted-bwrap`;
//   - the sandbox descriptors are inherited as descriptors 3, 4, ... of the child, so the `/proc/self/fd/N`
//     numbers recorded in the manifest argv are deterministic instead of whatever the parent happened to have open;
//   - the private-filesystem check is core/adapter's allow-list (fail closed) instead of the old deny-list;
//   - staging the Bubblewrap launcher from its open descriptor compares (device, inode, size, mtime, mode) and the
//     content hash; the Python copy also compared ctime, which the portable Go stat does not expose. The bytes are
//     still hashed before and after the copy and must equal the authenticated identity;
//   - a launcher that cannot be resolved ends with the one typed line only: the shim let realpath(1) print its own
//     diagnostic first (parity case cg-bwrap-missing);
//   - `runtime` names the Go toolchain (`go`) and the kernel instead of the Python version;
//   - option parsing is the stdlib flag package (no prefix abbreviations; usage errors print rsdd's usage, exit 2);
//   - the Linux-private filesystem, Bubblewrap and /proc/self/fd requirements make the adapter Unix-only: elsewhere
//     the command compiles and refuses with a typed message.
package ghidra
