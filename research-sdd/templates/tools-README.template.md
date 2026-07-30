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

---

| Tool | Path | Provenance | Why it exists here |
|---|---|---|---|
| <name> | `tools/<name>` | `created` | <one sentence: what gap it closes, what it replaces if anything> |
| <name> | `tools/<name>` | `downloaded` | <source URL or package + version · what it enables> |
| <name> | `<kit-path>` | `used-as-is` | <which artifact type it handles in this corpus> |
| <name> | `<kit-path>` | `adapted` | <what the kit version could not express · what changed> |
| <name> | `tools/<name>` | `updated-in-use` | <old version → new version · why the update was necessary> |

<!-- Remove unused rows. Keep this file short — it is a WHY ledger, not a user manual.
     The kit's toolbelt/tool-registry.md documents HOW to use kit tools; this file records
     WHICH kit tools this corpus relies on and WHY any local tools were created or adapted.
     Seeded by BOOTSTRAP (PROMPT-LOOP.md). Updated whenever a tool is added or changed. -->
