#!/usr/bin/env bash
# research-sdd-archive.sh — gated close discipline for a Research-SDD corpus (SDD-borrow #4, models sdd-archive).
#
# WHY: closing a research run/focus was PROSE (PROMPT-LOOP step 7 "STOPPING": run the two linters by hand,
# regenerate CATALOG, refresh the mirror, delegate the retro). A human/agent re-did that cluster by eye each
# close, and a stale mirror let the loop emit a PREMATURE STOP (pruebas-dashboards run-A closed at 23/23 while
# 16 gaps were still pending). This mechanizes the SAFE, deterministic half and REFUSES to close an
# inconsistent corpus. Deliberately CONSERVATIVE: it never authors content, never edits the kit, and never
# touches git — everything that needs JUDGMENT is emitted as a close-checklist, not guessed.
#
# It is the research-loop analog of `sdd-archive` (gate on verify → consolidate → close report), kept to the
# CONTINUOUS loop and CORPUS-scoped (like the §18 retro, it operates on the TARGET only, never the kit).
#
# Uses `set -uo pipefail` WITHOUT -e — like its read-mostly siblings (verify-state/verify-sources/status) it
# does best-effort find/grep/awk over markdown, where a subcommand legitimately exiting non-zero (e.g. `find`
# hitting an unreadable subtree) must NOT abort the tool. The two genuine mutations are guarded explicitly.
#
# Usage:
#   research-sdd-archive.sh <target-dir>              gate + consolidate (regenerate CATALOG, touch INDEX) + checklist
#   research-sdd-archive.sh <target-dir> --dry-run    report what WOULD happen; mutate nothing
# Exit: 0 = archived (or dry-run); the GATE is the archive decision — consolidate steps are BEST-EFFORT and a
#           failure there is reported LOUDLY (stderr + checklist) but keeps exit 0, so callers gate on 0/2/3.
#       2 = bad args / no RESEARCH-STATE (nothing to archive).
#       3 = REFUSED: a consistency gate (verify-state / verify-sources) did not pass — reconcile first.
set -uo pipefail

target=""; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift;;
    -*) echo "research-sdd-archive: unknown flag: $1" >&2; exit 2;;
    *)  [ -z "$target" ] && target="$1" || { echo "research-sdd-archive: unexpected extra arg: $1" >&2; exit 2; }; shift;;
  esac
done
[ -n "$target" ] && [ -d "$target" ] || { echo "usage: research-sdd-archive.sh <target-dir> [--dry-run]" >&2; exit 2; }
target="${target%/}"   # a trailing slash would defeat the corpus-relative prefix strip below

here="$(cd "$(dirname "$0")" && pwd)"
# Resolve the corpus root exactly like research-sdd-status.sh: shallowest RESEARCH-STATE, deterministically.
# (No -e: a non-zero from find on an unreadable subtree is discarded, not fatal — the value is still correct.)
state="$(find "$target" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null | sort | head -1)"
[ -n "$state" ] && [ -f "$state" ] || { echo "research-sdd-archive: no RESEARCH-STATE*.md under $target — nothing to archive (run research-sdd-init.sh)" >&2; exit 2; }
corpus="$(dirname "$state")"
rel="${corpus#"$target"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="(flat)"

echo "== research-sdd-archive: $(basename "$target")  ·  corpus: $rel$([ "$dry" = 1 ] && echo '  ·  DRY-RUN') =="

# --- GATE: never archive an inconsistent corpus (this is the load-bearing part) --------------------
# Delegate to the two sibling linters. verify-state catches the stale-mirror / premature-STOP desync;
# verify-sources catches a broken source registry. Either non-zero blocks the close (fail-closed). A linter
# that exits >1 (missing / not executable / bad args) is reported DISTINCTLY from a real content FAIL so a
# broken toolchain is not mistaken for a stale mirror.
gate_rc=0
gate() {  # <label> <sibling-script> <content-fail-message>
  local rc; "$here/$2" "$corpus" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) echo "    $1 : ok";;
    1) echo "    $1 : FAIL — $3"; gate_rc=1;;
    *) echo "    $1 : ERROR — $2 did not run (exit $rc) — check it exists and is executable"; gate_rc=1;;
  esac
}
echo "  -- gates --"
gate "verify-state  " verify-state.sh   "living mirror inconsistent (stale summary / premature STOP)"
gate "verify-sources" verify-sources.sh "source registry incomplete (preserved-source markers without a registry, a cited file missing, a fabricated registry citation, or an unregistered web-snapshot)"
gate "scan-secrets " scan-secrets.sh   "a high-confidence secret VALUE leaked into authored corpus content (SECRETS DISCIPLINE)"
if [ "$gate_rc" != 0 ]; then
  echo "  REFUSED: reconcile the failing gate(s) before archiving. Run for detail:"
  echo "    $here/verify-state.sh $corpus"
  echo "    $here/verify-sources.sh $corpus"
  echo "    $here/scan-secrets.sh $corpus"
  exit 3
fi

# --- CONSOLIDATE: safe, deterministic, idempotent bookkeeping (the 'merge into main' analog) --------
# Best-effort: a failure here is surfaced loudly and pushed to the top of the checklist, but does NOT flip
# the exit code — the gate already decided the close is legitimate.
consolidate_err=""
# eje #2 (refined) — the KIT generator is the DEFAULT authority (a target with NO copy has no drift), but a
# target's LOCAL `<corpus>/tools/gen-catalog.py` WINS when present. Mature corpora (niagara, logosoft) ship a
# BESPOKE generator that catalogs corpus-specific structures the generic kit generator cannot express: non-
# numbered thematic blocks (e.g. "Bloque TI"), consolidated blocks ("1-3"), and snapshots in their own section.
# ALWAYS using the kit generic silently DROPPED those (niagara -2 blocks, logosoft -1) — a real regression.
# So: prefer the local generator; fall back to the kit generic (resolved from THIS script's location —
# archive.sh lives in research-sdd/toolbelt/ → generator is ../templates/). A local copy that is merely a
# stale duplicate of the kit is harmless: it produces the same catalog, so preferring it changes nothing.
gen_kit="$here/../templates/gen-catalog.py"
gen_local="$corpus/tools/gen-catalog.py"
if [ -f "$gen_local" ]; then
  # Invoke by TYPE of local copy so the catalog always lands in the corpus without assuming argv support:
  #   • SYMLINK (to the shared kit gen, to avoid duplicating an unchanged script): pass the corpus as argv —
  #     else Path(__file__).resolve() follows the link and parent.parent lands on the KIT tree (wrong write).
  #     The kit gen honors argv=corpus.
  #   • REAL FILE (a bespoke generator, or a stale kit duplicate): invoke NO-ARG — its parent.parent IS the
  #     corpus, so it needs no argument, and a bespoke script with strict argv handling (argparse, no
  #     positional) won't choke on an unexpected argument it never declared.
  if [ -L "$gen_local" ]; then gen_cmd=(python3 "$gen_local" "$corpus"); else gen_cmd=(python3 "$gen_local"); fi
  gen_desc="local generator ($gen_local)"
elif [ -f "$gen_kit" ]; then
  gen_desc="kit generator ($gen_kit)";     gen_cmd=(python3 "$gen_kit" "$corpus")
else
  gen_desc=""
fi
if [ -z "$gen_desc" ]; then
  catalog="skipped (no generator: neither $gen_local nor $gen_kit)"
elif [ "$dry" = 1 ]; then
  catalog="would regenerate via $gen_desc"
elif "${gen_cmd[@]}" >/dev/null 2>&1; then
  catalog="regenerated CATALOG.md (via $gen_desc)"
else
  catalog="ERROR — gen-catalog.py failed (CATALOG.md NOT regenerated / left stale)"
  consolidate_err="CATALOG regen failed — run: ${gen_cmd[*]}"
  echo "WARNING: $consolidate_err" >&2
fi
# Touch the CANONICAL INDEX.md when present (prefer the exact name over an INDEX-*.md sibling), guarded so a
# permission error degrades to an honest report instead of a silent mis-report.
index="skipped (no INDEX*.md)"
idx="$corpus/INDEX.md"; [ -f "$idx" ] || idx="$(find "$corpus" -maxdepth 1 -name 'INDEX*.md' 2>/dev/null | sort | head -1)"
if [ -n "$idx" ] && [ -f "$idx" ]; then
  if [ "$dry" = 1 ]; then index="would touch $(basename "$idx")"
  elif touch "$idx" 2>/dev/null; then index="touched $(basename "$idx")"
  else index="ERROR — could not touch $(basename "$idx") (permission?)"; consolidate_err="${consolidate_err:-touch INDEX failed}"; fi
fi
echo "  -- consolidate --"
echo "    catalog        : $catalog"
echo "    index          : $index"

# --- MIRROR FACTS: computed for the close-checklist (archive is CORPUS-scoped; it never edits \$KIT/TARGETS.md) --
# Count blocks with gen-catalog.py's OWN discriminator (`<prefix>-block|bloque<num>.md`), not a loose
# `*block*.md` glob — otherwise a decoy like `blocked-notes.md` inflates the count fed to the TARGETS.md row.
blocks="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' | wc -l | tr -d ' ')"
retros="$(find "$corpus" "$target" -maxdepth 2 -path '*/retros/*.md' 2>/dev/null | sort -u | wc -l | tr -d ' ')"
# Iteration-history rows: data rows in the "## Iteration history" table (numeric first cell; header/separator excluded).
histrows="$(awk 'index($0,"## Iteration history")==1{f=1;next} /^## /{f=0} f' "$state" \
  | awk '{l=$0; gsub(/^[ \t]+|[ \t]+$/,"",l); sub(/^\|/,"",l); n=split(l,a,"|"); gsub(/^[ \t]+|[ \t]+$/,"",a[1]); if (a[1] ~ /^[0-9]+$/) c++} END{print c+0}')"
echo "  -- mirror facts (for the TARGETS.md row refresh; not applied here) --"
echo "    blocks on disk : $blocks · retros: $retros · iteration-history rows: $histrows"

# --- CLOSE CHECKLIST: the JUDGMENT / content-authoring / side-effecting steps archive REFUSES to guess ---
echo "  -- JUDGMENT follow-ups (NOT mechanizable — do these to complete the close) --"
[ -n "$consolidate_err" ] && echo "    · ⚠ CONSOLIDATE: $consolidate_err (a mechanical step failed — fix before relying on the archive)."
echo "    · SYNTHESIS block (§8, optional): author a focus-closing block consolidating this focus, if terminal."
echo "    · RETRO (§18): delegate a fresh-context retro agent → $target/retros/<date>-<focus>.md (review-status: pending)."
if find "$corpus" -maxdepth 1 -type d -name 'codegen*' 2>/dev/null | grep -q .; then
  echo "    · PARITY (§19): a codegen/ deliverable exists — run verify-parity.sh <deliverable> <block-or-corpus> per"
  echo "      built artifact so a drifted/invented value can't ship. NOT auto-gated here: the deliverable↔block map is"
  echo "      corpus-specific, and verify-parity is a targeted (deliverable, block) check, not a corpus-wide lint."
fi
if [ "$histrows" -gt 25 ]; then
  echo "    · COLLAPSE iteration-history (§8): $histrows rows > 25 — collapse prior runs to one line/run (blocks, gaps, ratio, retro link)."
fi
echo "    · MIRROR: refresh this target's row in \$KIT/TARGETS.md with the counts above (blocks=$blocks, retros=$retros)."
echo "    · COMMIT (corpus only): git -C $corpus add -A && git -C $corpus commit  (orchestrator artifacts stay gitignored, §15)."

echo "  archived$([ "$dry" = 1 ] && echo ' (dry-run — nothing mutated)')."
exit 0
