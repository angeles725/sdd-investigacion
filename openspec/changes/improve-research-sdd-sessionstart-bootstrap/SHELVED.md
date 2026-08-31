# PARTIALLY SHELVED — read before building

**Status:** D1 SHELVED · D2/D3 already shipped · D4 separable-and-unmeasured. Do not
implement this change as written.

**Verdict date:** 2026-08-31 · recorded by `investigador2`, endorsed by `investigador1`
and `QA`.

## Per-delta disposition

- **D1 — silence-on-clean on the 4 always-emit hooks: SHELVED.** This change's own
  Approach A is "the hook parses the underlying script's output tokens" to decide silence.
  That is the *hook-parses-free-form-stdout* mechanism named in **PR #383**'s close comment
  as §6-fragile / §7 false-clean — the same class as the shelved
  `research-sdd-sweep-declared-state` sentinel (see that directory's `SHELVED.md`). Same
  §6 zero-yield fact (the fleet is never clean today) and same §7 treadmill hazard. Do not
  build.
- **D2 — breakthroughs "Ledger consistent" clean sentence: ALREADY SHIPPED** via PR #376
  (merge `26332ba`, squash `5185632`). `sweep-breakthroughs.sh:176`.
- **D3 — neutral success/failure header wording: ALREADY SHIPPED** via PR #376 (same
  commit).
- **D4 — distinct absent-vs-empty exit-code contract across the 4 underlying scripts:
  SEPARABLE, NOT killed, NOT yet measured.** D4 is a §7 anti-silent-zero distinction
  (missing/broken TARGETS.md vs present-but-zero-rows) and is *independent* of the
  silence-on-clean feature, so it does not die with D1. But it has no measured yield yet.
  Before any writer: run a §6 probe — is there a consumer that actually branches on an
  absent-vs-empty *exit code* (the hooks mostly `exit 0` regardless), and do the current
  scripts' *messages* already distinguish the three §7 states (absent / empty / no-match)?
  If the messages already distinguish them and no consumer branches on the code, D4 is also
  low-yield. Carried to the backlog as its own measured candidate, not built here.

## Net

Nothing in this directory is buildable as-is: D1 is shelved, D2/D3 are shipped, D4 needs
its own yield probe. Kept as a tombstone so this loop is not re-opened a fourth time.
