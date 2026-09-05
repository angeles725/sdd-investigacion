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
# Absolutize a RELATIVE target NOW, before it seeds $state/$corpus. Left relative, `find "$corpus" ...`
# below yields relative paths, and `git -C "$corpus" log -- "$rf"` (rsdd_added_epoch) double-resolves them
# against the already-`-C`-rebased cwd (e.g. `git -C niagara log -- niagara/…`) — never matches, so the
# MISSING-RETRO detector silently degrades to the mtime fallback for EVERY file, with no error.
raw_target="$target"
target="$(cd "$target" 2>/dev/null && pwd)" || { echo "research-sdd-archive: not a directory: $raw_target" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"

# Source the shared retro helper (retro_is_excluded) — fail-closed: a missing helper means we
# cannot filter excluded retros from the retros count or MISSING-RETRO detector.
_lib="$here/lib/retro-status.sh"
if [ ! -f "$_lib" ]; then echo "research-sdd-archive: cannot find helper $_lib" >&2; exit 1; fi
# shellcheck source=lib/retro-status.sh
. "$_lib"
declare -F retro_is_excluded >/dev/null 2>&1 \
  || { echo "research-sdd-archive: helper $_lib failed to define retro_is_excluded" >&2; exit 1; }
# retro_review_status is also needed for the format lint at close time.
declare -F retro_review_status >/dev/null 2>&1 \
  || { echo "research-sdd-archive: helper $_lib failed to define retro_review_status" >&2; exit 1; }
declare -F retro_has_bare_marker >/dev/null 2>&1 \
  || { echo "research-sdd-archive: helper $_lib failed to define retro_has_bare_marker" >&2; exit 1; }
unset _lib

_bflib="$here/lib/block-files.sh"
if [ ! -f "$_bflib" ]; then echo "research-sdd-archive: cannot find helper $_bflib" >&2; exit 1; fi
# shellcheck source=lib/block-files.sh
. "$_bflib"
declare -F block_file_filter >/dev/null 2>&1 \
  || { echo "research-sdd-archive: helper lib/block-files.sh failed to define block_file_filter" >&2; exit 1; }
unset _bflib

# Source the shared state-file enumerator — required for the multi-focus undocumented_findings gate.
_sflib="$here/lib/state-files.sh"
if [ ! -f "$_sflib" ]; then echo "research-sdd-archive: cannot find helper $_sflib" >&2; exit 1; fi
# shellcheck source=lib/state-files.sh
. "$_sflib"
declare -F list_state_files >/dev/null 2>&1 \
  || { echo "research-sdd-archive: helper $_sflib failed to define list_state_files" >&2; exit 1; }
unset _sflib

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
# undocumented_findings gate — scope is $target, NOT $corpus. INVARIANT: inspect EVERY focus under
# the target, not only those under the first-discovered corpus directory. WHY: in a SPLIT layout
# (focuses in sibling subdirectories rather than flat in one dir), $corpus is only the FIRST focus's
# directory (line ~72: corpus=dirname of the shallowest state file). Scoping to $corpus silently
# skips sibling focuses; any UF debt in them passes this gate unseen. The _uf_sf_count guard below
# catches EMPTY enumeration (zero files inspected) but NOT PARTIAL enumeration (some focuses missed)
# — that is why the scope itself must be $target so list_state_files reaches all focuses at maxdepth 3.
# Multi-focus corpora have one state file per focus (RESEARCH-STATE-<slug>.md). Absent field or
# non-integer → treated as 0 (legacy corpora predate this field). Any positive value in ANY focus
# means at least one finding was saved to memory without a block; refuse until the researcher writes
# the block(s), decrements the counter in the state file, then --sync-state.
_uf_sf_count=0
while IFS= read -r _uf_sf; do
  [ -f "$_uf_sf" ] || continue
  # Increment AFTER the -f guard so the counter measures files actually inspected, not lines
  # the enumerator returned. If every enumerated path fails -f (e.g. paths that vanished
  # between the find scan and this loop, or a broken enumerator outputting garbage), the
  # counter stays 0 and the empty-inspection guard below fires — making this strictly
  # stronger than counting enumerated lines.
  _uf_sf_count=$((_uf_sf_count + 1))
  _uf_val="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && $1=="undocumented_findings:"{print $2; exit}' "$_uf_sf" 2>/dev/null)"
  case "${_uf_val:-0}" in
    *[!0-9]*) ;;
    0)         ;;
    *)
      echo "    undocumented_findings: REFUSE — $(basename "$_uf_sf"): undocumented_findings=${_uf_val} must be 0 before closing (write the missing block(s), decrement the counter in the state file, then --sync-state)"
      gate_rc=1  # uf-gate-refuse
      ;;
  esac
done < <(list_state_files "$target")
# Fail-closed invariant: $target was verified above (find at line ~70 resolved a RESEARCH-STATE*.md
# under it), so ZERO inspected files here is an IMPOSSIBLE state — the enumerator malfunctioned
# (returned nothing or only non-existent paths) rather than debt being absent. Report as a toolchain
# ERROR (distinct from a content FAIL, following the established gate() convention) so a broken
# enumerator is never mistaken for a clean corpus. Third silent-pass shape in this family.
# Note: this guard catches EMPTY enumeration; PARTIAL enumeration (some focuses missed) is prevented
# by the $target scope above — this counter alone cannot substitute for the correct scope.
if [ "$_uf_sf_count" -eq 0 ]; then
  echo "    undocumented_findings: ERROR — could not enumerate state files (impossible: corpus was located but list_state_files returned nothing — inspect lib/state-files.sh)"
  gate_rc=1  # uf-gate-enum-empty
fi
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
blocks="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null | block_file_filter | wc -l | tr -d ' ')"
# Count only non-excluded retros — files carrying '<!-- kit-retro: exclude -->' are not §18 kit retros.
retros=0
while IFS= read -r _rfe; do
  [ -n "$_rfe" ] || continue
  retro_is_excluded "$_rfe" && continue
  retros=$((retros + 1))
done < <(find "$corpus" "$target" -maxdepth 2 -path '*/retros/*.md' 2>/dev/null | sort -u)
# Iteration-history rows: data rows in the "## Iteration history" table (numeric first cell; header/separator excluded).
histrows="$(awk 'index($0,"## Iteration history")==1{f=1;next} /^## /{f=0} f' "$state" \
  | awk '{l=$0; gsub(/^[ \t]+|[ \t]+$/,"",l); sub(/^\|/,"",l); n=split(l,a,"|"); gsub(/^[ \t]+|[ \t]+$/,"",a[1]); if (a[1] ~ /^[0-9]+$/) c++} END{print c+0}')"
echo "  -- mirror facts (for the TARGETS.md row refresh; not applied here) --"
echo "    blocks on disk : $blocks · retros: $retros · iteration-history rows: $histrows"

# --- MISSING-RETRO detector (Feature #25a, §18): catch a run that CLOSED without producing a fresh retro
# (lost feedback). Compares the newest BLOCK's date against the newest RETRO's date using the SAME date source
# for both (git FIRST-COMMIT/added epoch, fallback to file mtime when untracked) — a like-for-like comparison,
# so a block ADDED after the newest retro means the corpus advanced past it. A mixed git-commit-vs-mtime
# comparison would fire on almost every git target (any unrelated commit is newer than a checkout mtime), so
# the added-date of the block itself is the signal. PURE DETECTION — advisory WARN (exit stays 0, like the
# codegen/ parity WARN); it never auto-generates a retro (propose-never-apply).
rsdd_added_epoch() {  # <repo-dir> <file> → git first-commit(added, under CURRENT path — no --follow,
  # same rename tradeoff as sweep-retros.sh) epoch if tracked, else file mtime, else 0
  local d="$1" f="$2" e
  e="$(git -C "$d" log --diff-filter=A --format=%ct -1 -- "$f" 2>/dev/null)"
  [ -n "$e" ] || e="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  printf '%s' "$e"
}
newest_retro_epoch=0
while IFS= read -r rf; do
  [ -n "$rf" ] || continue
  retro_is_excluded "$rf" && continue   # excluded retros do not count toward MISSING-RETRO detection
  m="$(rsdd_added_epoch "$corpus" "$rf")"; [ "${m:-0}" -gt "$newest_retro_epoch" ] && newest_retro_epoch="$m"
done < <(find "$corpus" "$target" -maxdepth 2 -path '*/retros/*.md' 2>/dev/null | sort -u)
newest_block_epoch=0
while IFS= read -r bf; do
  [ -n "$bf" ] || continue
  m="$(rsdd_added_epoch "$corpus" "$bf")"; [ "${m:-0}" -gt "$newest_block_epoch" ] && newest_block_epoch="$m"
done < <(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null | block_file_filter)
if [ "$blocks" -gt 0 ] && { [ "$retros" -eq 0 ] || [ "$newest_block_epoch" -gt "$newest_retro_epoch" ]; }; then
  if [ "$retros" -eq 0 ]; then rdate="none"; else rdate="$(date -d "@$newest_retro_epoch" +%Y-%m-%d 2>/dev/null || echo '?')"; fi
  echo "WARN: corpus advanced ($blocks block(s)) but the newest §18 retro is $rdate — a retro for this run may be" >&2
  echo "      lost; delegate a fresh-context retro before close (MISSING-RETRO detector never auto-generates one)." >&2
  missing_retro_line="    · ⚠ MISSING-RETRO (§18): corpus advanced past the newest retro ($rdate) — delegate a retro for THIS run before close (propose-never-apply; not auto-generated)."
fi

# --- ONE-BLOCK-PER-COMMIT detector (§ PROMPT-LOOP LOOP CONTINUATION): the "one block per commit" hard rule
# was violated in prose-only practice despite a named precedent (three.js B15+B16; ug67 B29+B30, B32+B33) —
# prose alone did not hold it. Mechanize it as a cheap git gate (mirroring §11's endorsement of corpus-level
# mechanical checks): flag any commit in THIS run (newer than the newest retro; ALL history when there is no
# retro yet) whose diff touches 2+ distinct block files. PURE DETECTION — advisory WARN (exit stays 0, like
# MISSING-RETRO / codegen parity); it never rewrites history. Uses the corpus-wide block-file discriminator.
multi_block_commits=""
if git -C "$corpus" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # Count only ADDED block files (--diff-filter=A), so the rule is "one NEW block per commit": an iteration
    # that adds one block AND MODIFIES an existing block to add the §14 reciprocal 'corrected in BN' backlink
    # (which the sibling verify-corrections feature now mandates in the SAME iteration) is NOT a violation.
    nbf="$(git -C "$corpus" show --diff-filter=A --name-only --format= "$sha" 2>/dev/null \
      | block_file_filter | sort -u | wc -l | tr -d ' ')"
    [ "${nbf:-0}" -ge 2 ] && multi_block_commits="${multi_block_commits}${multi_block_commits:+ }${sha:0:9}(${nbf} blocks)"
  done < <(git -C "$corpus" log --format=%H --since="@${newest_retro_epoch:-0}" 2>/dev/null)
fi
if [ -n "$multi_block_commits" ]; then
  echo "WARN: ONE-BLOCK-PER-COMMIT violated — commit(s) landing 2+ block files this run: $multi_block_commits" >&2
  echo "      the loop's LOOP CONTINUATION rule is one block per iteration, one commit per block." >&2
  one_block_line="    · ⚠ ONE-BLOCK-PER-COMMIT (§ LOOP CONTINUATION): commit(s) $multi_block_commits landed 2+ blocks — keep future commits to one block each (this run's history is advisory, not rewritten)."
fi

# --- RETRO FORMAT LINT: warn on retros with malformed or absent review-status markers.
# The sweeper gates on the LEADING HTML-comment block — a bare-text 'review-status:' line (not
# wrapped in '<!-- ... -->') is invisible to it, so the retro sits in an ambiguous, un-reviewable
# state indefinitely.  Catch this at close time with an advisory WARN (exit stays 0, consistent
# with MISSING-RETRO and codegen parity).  Does not block: the marker is advisory at close time;
# the human owns the retro content.
while IFS= read -r _lint_f; do
  [ -n "$_lint_f" ] || continue
  retro_is_excluded "$_lint_f" && continue   # excluded retros do not carry a §18 status marker
  _lint_status="$(retro_review_status "$_lint_f")"
  if [ -z "$_lint_status" ]; then
    _lint_base="$(basename "$_lint_f")"
    # retro_has_bare_marker uses head -10 — same algorithm the inline code used.
    if retro_has_bare_marker "$_lint_f"; then
      echo "WARN: malformed review-status in $_lint_base — bare text marker in first 10 lines; wrap in '<!-- review-status: ... -->'" >&2
    else
      echo "WARN: no review-status marker in leading block of $_lint_base — add '<!-- review-status: pending -->' at the top" >&2
    fi
  fi
done < <(find "$corpus" "$target" -maxdepth 2 -path '*/retros/*.md' -not -iname '*index*.md' 2>/dev/null | sort -u)

# --- CLOSE CHECKLIST: the JUDGMENT / content-authoring / side-effecting steps archive REFUSES to guess ---
echo "  -- JUDGMENT follow-ups (NOT mechanizable — do these to complete the close) --"
[ -n "$consolidate_err" ] && echo "    · ⚠ CONSOLIDATE: $consolidate_err (a mechanical step failed — fix before relying on the archive)."
echo "    · SYNTHESIS block (§8, optional): author a focus-closing block consolidating this focus, if terminal."
echo "    · RETRO (§18): delegate a fresh-context retro agent → $target/retros/<date>-<focus>.md (review-status: pending)."
[ -n "${missing_retro_line:-}" ] && echo "${missing_retro_line}"
[ -n "${one_block_line:-}" ] && echo "${one_block_line}"
# pipefail-audit: external `find` producer looking for at most 1 directory entry (<100 B).
# Race onset for external producers: ~64 KB. Fleet max << onset; 0/200 trials. Not reproduced.
if find "$corpus" -maxdepth 1 -type d -name 'codegen' 2>/dev/null | grep -q .; then
  # ACTIVE detection (not a passive reminder): a shipped deliverable can close green with deliverable↔block
  # parity UNVERIFIED, contradicting "a green report can never sit over a broken corpus". Emit a LOUD warning
  # to stderr — advisory, NOT a hard refuse: kept a warning (exit stays 0) so a legitimate close with no
  # per-(deliverable,block) mapping is not bricked. verify-parity is a targeted check, not a corpus-wide gate,
  # and applies to token/color-based deliverables — not every codegen/ output fits that shape.
  echo "WARN: deliverable (codegen/) present but verify-parity was NOT run — deliverable↔block drift is unchecked;" >&2
  echo "      if this is a token/color-based deliverable, run $here/verify-parity.sh <deliverable> <block> before trusting this close." >&2
  echo "    · PARITY (§19): ⚠ codegen/ deliverable present — verify-parity was NOT run here (see WARN above). For"
  echo "      token/color-based deliverables, run verify-parity.sh <deliverable> <block-or-corpus> per built artifact"
  echo "      so a drifted/invented value can't ship. NOT auto-gated: the deliverable↔block map is corpus-specific."
fi
if [ "$histrows" -gt 25 ]; then
  echo "    · COLLAPSE iteration-history (§8): $histrows rows > 25 — collapse prior runs to one line/run (blocks, gaps, ratio, retro link)."
fi
echo "    · MIRROR: refresh this target's row in \$KIT/TARGETS.md with the counts above (blocks=$blocks, retros=$retros)."
echo "    · COMMIT (corpus only): git -C $corpus add -A && git -C $corpus commit  (orchestrator artifacts stay gitignored, §15)."

echo "  archived$([ "$dry" = 1 ] && echo ' (dry-run — nothing mutated)')."
exit 0
