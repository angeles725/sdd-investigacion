# Lane fixture layout

Fixtures for the fast/slow test-lane system live here, one subdirectory per suite:

```
fixtures/lane/
  <suite-name>/
    <fixture-name>.json
```

Example: `fixtures/lane/corroborate-ghidra/baseline.json`

## Purpose

In the **fast** lane (the default gate), suites load these pre-captured JSON
fixtures instead of spawning the real tool (Ghidra, r2, bwrap, etc.).  This
keeps `run-all.sh` under ~30 s on developer machines while still exercising
every assertion that does not require a live tool.

Containment guards (bwrap / qemu / docker flags) are asserted in the fast lane
too — only the real-tool spawn is deferred.

## Generating fixtures

Run `regen-lane-fixtures.sh` (in the parent `tests/` directory) to rebuild
all fixtures from a live slow-lane run.  A real tool installation is required
for regeneration; it is NOT required for the fast-lane gate.

## Anti-#128 rule

A fast-lane suite MUST emit a normal `== N passed · N failed ==` summary.
It must NEVER emit a `SKIP:` line — `run-all.sh` counts `SKIP:+exit0` as
skipped (= lost coverage).
