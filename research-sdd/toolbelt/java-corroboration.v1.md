# Corroborate a Java archive without executing it

`corroborate-java.sh` runs Vineflower, CFR, Procyon, `javap`, and `jdeps` as
independent bounded adapters and publishes one reproducible evidence root.

```bash
./corroborate-java.sh \
  --input application.jar \
  --output evidence/java-corroboration \
  --timeout-seconds 120 \
  --max-heap 1024m \
  --max-files 20000 \
  --max-bytes 1073741824 \
  --max-classes 10000
```

The output root must be new. Replacing it requires `--overwrite`; input and tool
artifact aliases are rejected before publication. The wrapper validates and copies
the JAR without loading target classes, then publishes atomically from a
deterministically named sibling staging directory. A concurrent collision fails
closed rather than sharing workspace state. Overwrite publication uses one atomic
directory exchange, so the visible destination is always either the old or new
evidence root. A managed staging marker lets the next locked run remove an old root
left by interruption after that exchange.

## Evidence

- `java-corroboration.v1.json` is timing-free and deterministic for stable adapter
  results. It records class entries, base-class expectations, signatures,
  dependencies, coverage, inventories, pairwise agreements, disagreements, caps,
  partial failures, and limitations.
- Every available adapter has its own `analysis-manifest.v1.json`, bounded canonical
  stdout/stderr, outcome, launcher identity, and bounded output inventory. Canonical
  streams replace only the run-specific staging root with `<STAGING_ROOT>`; temporary
  raw streams are removed during finalization rather than duplicating diagnostics in
  published evidence. Diagnostics and retained output share the configured byte cap.
  On Linux, every adapter process inherits `RLIMIT_FSIZE` set to that cap, so no
  individual generated regular file can grow beyond it during execution. This limit
  does not by itself bound the aggregate size or file count; the adapter monitor
  stops the process group when those aggregate caps are observed, and deterministic
  finalization enforces the published aggregate. Finalization retains the canonical
  prefix of an oversized output when budget remains instead of deleting all generated
  evidence; diagnostics reserve one byte when any generated output exists. The engine
  is recorded as truncated partial evidence. The recorded argv is the command actually
  executed;
  manifests bind Bubblewrap, the inner Java launcher, and the private analyzer copy
  at their exact invocation positions. `trusted-source.json` records the original
  regular file's path, size, and digest plus the equal staged-copy identity. Stable
  provenance uses the source digest; invocation uses only the private copy.
  An unavailable decompiler has no synthetic manifest.
- Java tool launchers are resolved through trusted symlink chains before execution
  and digest binding. Input and analyzer JARs remain final-symlink rejecting.
- Vineflower runs with one worker (`--thread-count=1`), and inventories and summary
  collections use canonical ordering.
- Multi-release entries are inventoried, but `javap` coverage uses base classes.
  Decompiled sources are compared only by paths and byte hashes; source equivalence
  is never claimed.

## Trust and isolation

Decompiler execution requires a trusted SHA-256 pin. These versioned defaults match
the verified laboratory artifacts; set `VINEFLOWER_SHA256`, `CFR_SHA256`, or
`PROCYON_SHA256` to intentionally approve different bytes.

| Analyzer | Trusted SHA-256 |
|---|---|
| Vineflower | `1dfcfe974395734fa467ce620661c7623d05ba83670de0529b1fbd63ff548b9d` |
| CFR | `f686e8f3ded377d7bc87d216a90e9e9512df4156e75b06c655a16648ae8765b2` |
| Procyon | `821da96012fc69244fa1ea298c90455ee4e021434bc796d3b9546ab24601b779` |

Pin changes are trust decisions: verify the upstream release independently, record
the new digest here, and review that change before execution. Every adapter runs in
Bubblewrap with network unshared, `/` read-only, only its staging output writable,
and synthetic HOME/XDG/TMP directories. Missing pins, digest mismatches, or an
unavailable isolation boundary fail before analyzer execution; there is no fallback.
Each external JAR is opened once without following its final symlink, copied and
hashed through that stable descriptor, fsynced, made read-only under a non-writable
private directory, and reverified before Bubblewrap receives it through a read-only
bind. The original path is never reopened by the analyzer. Bubblewrap reduces host
exposure, but WSL2 is not a security boundary; use a disposable VM for hostile input.
