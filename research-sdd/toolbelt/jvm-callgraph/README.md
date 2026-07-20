# JVM call-graph exporter

This tool produces bounded, deterministic `jvm-callgraph.v1` JSON without loading or
executing analyzed classes. It uses SootUp 2.0.0 class-hierarchy analysis (CHA).

```bash
./jvm-callgraph.sh build                    # offline only
./jvm-callgraph.sh bootstrap                # explicit, Central-only fetch
./jvm-callgraph.sh analyze \
  --input app.jar \
  --dependency lib/dependency.jar \
  --entry-contains 'com.example.Bootstrap' \
  --sink-contains 'send' \
  --max-depth 16 --max-paths 100 \
  --max-nodes 10000 --max-edges 50000 --max-xrefs 10000 \
  --output evidence/callgraph.json
```

`--dependency`, `--entry`, `--entry-contains`, and `--sink-contains` are repeatable.
Without an entry selector, application `main(String[])` methods are discovered. Existing
outputs require `--overwrite`. Inputs and dependencies must be regular, non-symlink files.

The wrapper pins Java 21 through `lib/tool-env.sh`, runs with a timeout and heap ceiling,
and does not invoke Maven during analysis. Override the default bounds with
`RSDD_JVM_CALLGRAPH_TIMEOUT` (seconds) and `RSDD_JVM_CALLGRAPH_MAX_HEAP` (for example,
`2048m`).

## Interpretation limits

- CHA deliberately overapproximates some virtual dispatch targets.
- SootUp 2.0.0 does not add `invokedynamic` edges.
- Missing dependency JARs produce unresolved methods and partial evidence.
- Caps make truncation explicit; this output is evidence for corroboration, not proof of
  complete runtime behavior.
