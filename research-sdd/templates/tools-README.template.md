# Tools — <TARGET NAME>

Record every tool introduced during this research run and WHY it exists here.
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
