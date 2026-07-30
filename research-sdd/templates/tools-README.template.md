# Tools — <TARGET NAME>

Record every tool the moment it is acquired or changed — not reconstructed at retro time.
The rationale is cheapest while the decision is live; a backfill written weeks later loses
exactly the information this ledger exists to hold (METHODOLOGY §10).

**Scope:** this table covers tools born inside the research loop (created, adapted, or
downloaded specifically for this investigation). Operational tooling that predates the
loop (site clients, harvesters, dashboards, decoders) belongs in the target's operational
inventory, not here — otherwise a target with dozens of operational scripts drowns the ledger.

One row per tool. Provenance cases:

| Provenance | Meaning |
|---|---|
| `used-as-is` | Kit tool used without modification |
| `adapted` | Kit tool modified for this target's needs (note what changed) |
| `downloaded` | External tool acquired for this run (note source + version) |
| `created` | New script/tool written from scratch for this target |
| `updated-in-use` | Tool was updated during the run (note old → new version or what changed) |
| `superseded` | Replaced by another tool — keep the row AND the file; name the replacement and the sha |

---

Every row carries **when** and **which version**. The date is the acquisition/change date, not the retro
date, and the block it was born in (`B34`) ties the tool to the evidence that motivated it. Version is the
upstream version for `downloaded`, the kit sha for `used-as-is`/`adapted`, and `n/a` for a local `created`
script that has no version of its own — write `n/a` rather than leaving it blank, so an empty cell always
means "not filled in" and never "does not apply".

| Tool | Path | Provenance | When · Version | Why it exists here |
|---|---|---|---|---|
| <name> | `tools/<name>` | `created` | `<YYYY-MM-DD>` (`B<N>`) · `n/a` | <what gap it closes> · **searched:** <terms tried in tool-registry.md / this ledger / the fleet> → <what came back> |
| <name> | `tools/<name>` | `downloaded` | `<YYYY-MM-DD>` (`B<N>`) · `<upstream version>` | <source URL or package · what it enables> · **searched:** <terms> → <result> |
| <name> | `<kit-path>` | `used-as-is` | `<YYYY-MM-DD>` (`B<N>`) · `kit <sha>` | <which artifact type it handles in this corpus> |
| <name> | `<kit-path>` | `adapted` | `<YYYY-MM-DD>` (`B<N>`) · `kit <sha>` | <what the kit version could not express · what changed> · **upstream:** <what it would take to merge this back, or why it cannot> |
| <name> | `tools/<name>` | `updated-in-use` | `<YYYY-MM-DD>` (`B<N>`) · `<old> → <new>` | <why the update was necessary> |
| <name> | `tools/<name>` | `superseded` | `<YYYY-MM-DD>` (`B<N>`) · `<last version>` | **by** `<replacement>` (`<sha>`) · <why> · **used by:** <other targets, or `none known`> |

`created` and `downloaded` require the **searched** clause (METHODOLOGY §10): a new tool without a
recorded search is a claim, not a finding — "nothing existed" and "I did not look" leave the same trace.
Search by ARTIFACT (`DXF`, `CHM`, `stripped ELF`) and by JOB (`oracle`, `carve`, `entropy`), never by the
name you were about to give the script.

`adapted` requires the **upstream** clause: it is what separates a general improvement the kit should
absorb from a local fit that must stay here. Without it, nobody can tell which is which later.

<!-- Remove unused rows. Keep this file short — it is a WHY ledger, not a user manual.
     The kit's toolbelt/tool-registry.md documents HOW to use kit tools; this file records
     WHICH kit tools this corpus relies on and WHY any local tools were created or adapted.
     Seeded by BOOTSTRAP (PROMPT-LOOP.md). Updated whenever a tool is added or changed. -->
