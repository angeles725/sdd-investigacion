# `firmware-static.v1`

`corroborate-firmware.sh --input firmware.bin --output evidence/firmware --max-input-bytes 1073741824` produces
deterministic, bounded Binwalk signature and entropy evidence without extraction,
network access, emulation, or target execution. The output path must be new and
reside on a Linux-private filesystem.

The adapter descriptor-copies the input and analyzer into a private `0700` stage,
requires the real root-owned `/usr/bin/binwalk` and `/usr/bin/bwrap` to agree with
PATH, and runs the staged analyzer through Bubblewrap with a read-only host and
stage, private PID/network namespaces, zero capabilities, and synthetic HOME/XDG/TMP state. The only
scan argv is `engine/binwalk -B -E -N input/firmware.bin`; user arguments,
configuration, extraction, carving, plugins, emulation, and target execution are
not exposed. Publication uses Linux `RENAME_NOREPLACE`.

`firmware-static.v1.json` records source/staged identities, exact argv, Binwalk
version, normalized sorted signatures and entropy edges, caps, truncation, errors,
and the verified `engine/analysis-manifest.v1.json` identity. Verify artifacts with:

```sh
python3 analysis_manifest.py verify --root evidence/firmware \
  evidence/firmware/engine/analysis-manifest.v1.json
```

Exit `0` means complete evidence, `1` means truthful partial or failed published
evidence, and `2` means unsafe preflight/publication failure with no output.
Input bytes (checked from the open descriptor before and while hashing/staging), timeout, process,
execution-time diagnostic-file, finding, and evidence-file ceilings are hard.

Binwalk 2.3.3 is recorded from the staged launcher. Its distro Python package,
dependencies, and magic database are read-only but not artifact-bound; signatures
remain heuristic. Bubblewrap on WSL2 is defense in depth, not a hostile-parser
boundary. `RSDD_BINWALK_TEST_ONLY` is test-only and is disclosed in all evidence.
