# `native-static.v1`

`corroborate-native.sh` produces bounded, deterministic radare2 evidence for
one regular native binary without executing the target.

```sh
corroborate-native.sh --input program.elf --output evidence/native
```

The output path must be new and reside on a Linux-private filesystem. The
adapter copies the input and analyzer into a private `0700` staging directory,
verifies their source/staged identities, locks permissions, and publishes it
atomically without replacement. Input and output symlinks are rejected.

radare2 runs through an authenticated, root-owned Bubblewrap launcher with no
network namespace, a read-only host filesystem, synthetic HOME/XDG/TMP paths,
user configuration and plugins disabled (`-NN -S`), write/debug/profile/script
surfaces disabled (`-x` and fixed argv), and the staged input fixed at
`input/target.bin`. The trusted analyzer can still read the read-only host root.
The fixed command is `aaa;aflj`; results are normalized and
sorted before publication. On WSL2 this is defense in depth, not a hostile-file
security boundary: use a disposable VM for untrusted samples.

`native-static.v1.json` binds source/staged SHA-256 identities, runtime,
launcher and engine executable identities, exact safe argv, caps, normalized
functions, truncation, limitations, errors, and the sibling manifest identity.

| Field | Contract |
|---|---|
| `schema`, `status` | Exact schema and `complete`/`partial`/`failed` outcome |
| `input` | Initial source and immutable staged identities |
| `runtime`, `isolation` | Runtime metadata and authenticated sandbox profile |
| `engine` | Engine identity, safe argv, stable outcome, manifest binding |
| `functions`, `counts` | Sorted bounded function records and totals |
| `caps`, `truncated` | Requested resource limits and disclosed truncation |
| `limitations`, `errors` | Epistemic limits and machine-readable failures |

`engine/analysis-manifest.v1.json` is created and validated only through the
public `analysis_manifest.py` CLI and can be rechecked with:

```sh
python3 analysis_manifest.py verify --root evidence/native \
  evidence/native/engine/analysis-manifest.v1.json
```

Exit `0` means complete evidence. Function truncation publishes truthful
`status: partial` evidence and exits `1`; analyzer exit, timeout, output cap, or
invalid JSON publishes `status: failed` evidence and exits `1`. Unsafe input,
tool identity/isolation failure, collision, or publication failure exits `2`
without publishing a partial directory. Caps are configurable with
`--timeout-seconds`, `--max-bytes`, `--max-functions`, and `--max-files`.
