# Research-SDD

**Research-SDD** is a Spec-Driven-Development-style methodology for exhaustive, fully-cited
reverse-engineering and research investigations. A driver runs an iterative loop — pick the next
gap, investigate it read-only, write one cited "block", update state, repeat until saturation or a
principled STOP. Every claim carries a certainty marker (`[CERT]`, `[INFER]`, …) that must resolve
to a real, preserved source, and a toolbelt of bash/node scripts mechanizes the gates (citation
resolution, living-mirror consistency, source-registry integrity, secret scanning, adversarial
`[CERT]` sealing) so a green report can never sit over a broken corpus.

This directory is the **kit**. The repository root is itself a live corpus produced by the kit — a
research investigation *about SDD* (`../sdd-mental-model-bloque*.md` plus [`../CATALOG.md`](../CATALOG.md)
and [`../INDEX.md`](../INDEX.md)). Read that as the reference example of the methodology applied to
itself.

---

## Requirements

The toolbelt is written for **Linux / GNU userland**:

- **bash ≥ 4** and **GNU coreutils** — scripts use `mapfile`, `grep -P`/`grep -E`, and other GNU-isms.
  WSL is fine. macOS/BSD is **not supported** out of the box (install GNU tools — `coreutils`,
  `grep` — and a modern bash first, or expect failures).
- **python3** — used by the catalog generator (`templates/gen-catalog.py`) and sanity-checked in CI.
- **Node.js** (CI uses 20) — required only for the adversarial-verify pair
  (`toolbelt/adversarial-verify.js`, `toolbelt/adversarial-verdict.mjs`).
- **Optional, per-workflow only** — the decompile/extract/ingest tools (Ghidra, radare2, Vineflower/CFR/Procyon,
  ilspycmd, binwalk, pandoc, pdftotext/pdfinfo, tesseract, …). None are needed to run the loop or the
  gates; each is required only for the specific ingest/decompile wrapper that calls it. Run
  [`toolbelt/detect-tools.sh`](toolbelt/detect-tools.sh) to see what is actually available on your host.

---

## Layout

```
research-sdd/
├── METHODOLOGY.md              # the full contract (§1–§19): markers, block anatomy, sources, stopping…
├── PROMPT-LOOP.md              # the per-iteration operational prompt (what goes into the loop)
├── PROMPT-AUDIT.md             # the audit-mode prompt (re-verify an existing corpus)
├── TARGETS.md                  # master table of registered research targets
├── skills/research-sdd/SKILL.md# launcher / depth classifier (quick · light · exhaustive)
├── templates/                  # block, INDEX, RESEARCH-STATE, SOURCES, CONTRADICTIONS, retro, audit templates + gen-catalog.py + hook-sessionstart.sh
└── toolbelt/                   # the ~two-dozen scripts that mechanize the gates
    └── tests/                  # regression suites + run-all.sh runner
```

---

## The loop in brief

The single source of truth for the loop is [`PROMPT-LOOP.md`](PROMPT-LOOP.md) (operational prompt) and
[`METHODOLOGY.md`](METHODOLOGY.md) (the contract). In outline:

1. **Bootstrap** (only if the target has no corpus) — `research-sdd-init.sh <target>` scaffolds
   `INDEX.md`, `RESEARCH-STATE.md`, `sources/SOURCES.md`, a SessionStart hook, `retros/`, `.gitignore`
   and `git init`s the target. The agent then does the judgment follow-ups it prints (register the
   target in `TARGETS.md`, declare the investigation angle, seed the gap backlog).
2. **Resolve the next gap** — mechanically, never by eye: `research-sdd-status.sh <target> --next`
   returns one line: `NEXT | <priority> | <gap>`, `STOP | <reason>`, `STALE`, `NONE`, or `BOOTSTRAP`.
3. **Investigate + write one block** — CHOOSE the gap, PROFILE its artifact type to pick a wrapper
   (`toolbelt/tool-registry.md`), INVESTIGATE read-only, and write ONE cited block with certainty
   markers.
4. **Verify in-iteration** — the sub-agent runs `verify-block.sh <block>` and pastes the output into
   its §11 self-report (marker tally, `[INFER]`/`[CERT]` ratio, `file:line` citation resolution).
5. **Close / STOP** — when the investigable backlog is exhausted (§8), `research-sdd-archive.sh <target>`
   gates the close: it runs the consistency linters (`verify-state`, `verify-sources`) and
   `scan-secrets`, regenerates the CATALOG, and refuses to close an inconsistent corpus.

---

## Toolbelt reference

The scripts a user actually invokes (usage strings verified against each script header). This is not
the full inventory — internal helpers (`profile-target.sh`, `install-tool.sh`, `stage-retro.sh`,
`sweep-retros.sh`, the `*-hook.sh` shims, `adversarial-verify.js`) are driven by the loop rather than
called directly. (`detect-tools.sh` is loop-run too, but is also handy to run directly — see Requirements/Quickstart.)

### Bootstrap / status

| Script | Usage | Purpose |
|---|---|---|
| [`research-sdd-init.sh`](toolbelt/research-sdd-init.sh) | `<target-dir> [--corpus auto\|nested\|flat] [--prefix <slug>] [--force]` | Mechanical bootstrap scaffolder; refuses over an existing corpus. (`nested` = corpus in a `corpus/` subdir, `flat` = at target root, `auto` = decide.) |
| [`research-sdd-status.sh`](toolbelt/research-sdd-status.sh) | `<target-dir> [--next]` | Structured status report; `--next` prints the deterministic next-gap line. |

### Gates

| Script | Usage | Purpose |
|---|---|---|
| [`verify-block.sh`](toolbelt/verify-block.sh) | `<block.md> [target-dir]` | Per-block self-verify: marker tally + `[CERT]` `file:line` citation resolution. |
| [`verify-state.sh`](toolbelt/verify-state.sh) | `<target-dir>` | Living-mirror lint — catches a stale summary that would emit a premature STOP. |
| [`verify-sources.sh`](toolbelt/verify-sources.sh) | `<target-dir>` | `SOURCES.md` preservation linter — every cited source is downloaded, present, and registered. |
| [`scan-secrets.sh`](toolbelt/scan-secrets.sh) | `<target-dir>` | Fails closed if a high-confidence secret **value** leaked into authored content. |

### Close

| Script | Usage | Purpose |
|---|---|---|
| [`research-sdd-archive.sh`](toolbelt/research-sdd-archive.sh) | `<target-dir> [--dry-run]` | Gated close: runs the linters + scan, consolidates CATALOG, refuses an inconsistent corpus. |

### Ingest / dynamic / firmware (optional tooling)

| Script | Usage | Purpose |
|---|---|---|
| [`fetch-doc.sh`](toolbelt/fetch-doc.sh) | `doc <url> <target-dir> [datasheets\|manuals] [name]` | Download a datasheet/manual into `sources/` and register it in `SOURCES.md`. |
| [`fetch-doc.sh`](toolbelt/fetch-doc.sh) | `web <url> <target-dir>` | Page/forum → Markdown (pandoc) into `sources/`, registered in `SOURCES.md`. |
| [`fetch-doc.sh`](toolbelt/fetch-doc.sh) | `ocr <pdf>` | OCR a scanned PDF (tesseract) and print to **stdout** — does not touch `sources/` or register. |
| [`extract-pdf.sh`](toolbelt/extract-pdf.sh) | `[options] <input.pdf>` | PDF → page-anchored Markdown (text-layer tier, OCR fallback). |
| [`probe.sh`](toolbelt/probe.sh) | `check <ip> <port…>` · `run <target-dir> <probe-cmd> [args…]` | Dynamic phase (§12): read-only probe of a live system, preserving raw output as evidence. |
| [`scan-firmware.sh`](toolbelt/scan-firmware.sh) | `scan\|extract\|yara <file> …` | Firmware/opaque-binary triage: binwalk structure/extraction + YARA signature match. |

### Decompile (optional tooling)

| Script | Usage | Purpose |
|---|---|---|
| [`decompile-java.sh`](toolbelt/decompile-java.sh) | `<in.jar\|in.class> <out-dir> [--engine vineflower\|cfr\|procyon]` | Java → source (Vineflower → CFR → Procyon); `--javap` for signatures. |
| [`decompile-net.sh`](toolbelt/decompile-net.sh) | `<in.dll\|in.exe> <out-dir>` | .NET assembly → C# via `ilspycmd` (`--list`, `--il` modes). |
| [`decompile-native.sh`](toolbelt/decompile-native.sh) | `ghidra\|r2\|quick <binary> …` | Native ELF/PE analysis: Ghidra headless, radare2, or a quick triage. |

---

## Quickstart

```bash
KIT=/home/cristian/investigacion/sdd-investigacion/research-sdd

# 0. (optional) see which decompile/ingest tools are actually installed
"$KIT/toolbelt/detect-tools.sh"

# 1. bootstrap a corpus for a target (scaffolds INDEX/RESEARCH-STATE/sources, git init)
"$KIT/toolbelt/research-sdd-init.sh" /path/to/target

#    then do the judgment follow-ups it prints: register the target in TARGETS.md,
#    declare the investigation angle, seed 5–15 high-priority gaps in RESEARCH-STATE.md

# 2. each iteration: resolve the next gap mechanically
"$KIT/toolbelt/research-sdd-status.sh" /path/to/target --next
#    -> NEXT | <priority> | <gap>   (investigate it, write one cited block)
#    -> STOP | <reason>             (backlog exhausted — proceed to close)

# 3. at STOP: gated close (runs the linters + secret scan, consolidates CATALOG)
"$KIT/toolbelt/research-sdd-archive.sh" /path/to/target
```

To drive the loop end-to-end (agent-directed), use the [`research-sdd` skill](skills/research-sdd/SKILL.md),
which classifies depth (quick answer · light exploration · exhaustive block loop) before launching.

---

## Testing / CI

Run the full toolbelt suite locally:

```bash
research-sdd/toolbelt/tests/run-all.sh              # run every suite
research-sdd/toolbelt/tests/run-all.sh --prove-teeth # + mutation self-test (negative control)
```

[`run-all.sh`](toolbelt/tests/run-all.sh) auto-discovers every `*.test.sh` and `*.test.mjs` suite next
to it (new suites are picked up automatically) and exits non-zero unless every suite passes.
`--prove-teeth` is forwarded only to the shell suites.

CI ([`.github/workflows/toolbelt-tests.yml`](../.github/workflows/toolbelt-tests.yml)) runs on any change
under `research-sdd/toolbelt/**`. It has two jobs:

- **toolbelt-tests** — `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` (Node 20, python3 sanity check).
- **shellcheck** — `shellcheck -S warning` over every `research-sdd/toolbelt/**/*.sh`.

---

## Where to go deeper

- [`METHODOLOGY.md`](METHODOLOGY.md) — the full contract: markers, block anatomy, `sources/` discipline,
  stopping criterion, self-verification, audit mode, multi-focus corpora, retrospectives.
- [`PROMPT-LOOP.md`](PROMPT-LOOP.md) — the per-iteration operational prompt (bootstrap → normal cycle → stop).
- [`skills/research-sdd/SKILL.md`](skills/research-sdd/SKILL.md) — the launcher and depth classifier.
- [`../`](../) — the SDD mental-model corpus: the kit applied to itself, as a worked example.
