#!/usr/bin/env bash
# research-sdd-init.sh — mechanical BOOTSTRAP scaffolder for a Research-SDD corpus.
#
# WHY: the BOOTSTRAP steps in PROMPT-LOOP were PROSE a human/agent executed by hand
# (mkdir, copy templates, git init). Prose rots and drifts. This mechanizes the
# DETERMINISTIC half so a bootstrap is code, not a checklist. The JUDGMENT half
# (classify the artifact, declare the angle, seed the real gaps, register the target
# in TARGETS.md, register + adapt the hook) stays with the agent — this script PRINTS
# those follow-ups; it never guesses them.
#
# SAFETY (each backed by a red-first test):
#   - REFUSES if a corpus already exists at EITHER candidate root ($TARGET or
#     $TARGET/corpus/), keyed on ANY corpus marker (INDEX/RESEARCH-STATE/CATALOG) —
#     so it never clobbers hand-curated state and never duplicates a corpus.
#   - PRE-FLIGHT writability probe: fails BEFORE any mutation if $TARGET is read-only.
#   - `set -euo pipefail` + a ROLLBACK trap: any mid-run failure removes exactly what
#     THIS run created (never a pre-existing file) and exits non-zero — no half-scaffold
#     left behind, no green report over a broken tree.
#   - POST-FLIGHT verification: success is printed only after all artifacts are confirmed.
#
# Usage: research-sdd-init.sh <target-dir> [--corpus auto|nested|flat] [--prefix <slug>] [--force]
# Exit: 0 = scaffolded · 2 = bad args/target/not-writable · 3 = corpus already exists (refused).

set -Eeuo pipefail   # -E: ERR trap must be inherited into functions, or rollback never fires

KIT="$(cd "$(dirname "$0")/.." && pwd)"          # .../research-sdd
TPL="$KIT/templates"

target=""; corpus_mode="auto"; prefix=""; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus) corpus_mode="${2:-auto}"; shift 2;;
    --prefix) prefix="${2:-}"; shift 2;;
    --force)  force=1; shift;;
    -*)       echo "unknown flag: $1" >&2; exit 2;;
    *)        target="$1"; shift;;
  esac
done
[ -n "$target" ] && [ -d "$target" ] || { echo "usage: research-sdd-init.sh <target-dir> [--corpus auto|nested|flat] [--prefix <slug>] [--force]" >&2; exit 2; }
target="$(cd "$target" && pwd)"

# templates must exist or we fail CLEANLY (never a half-scaffold)
for t in INDEX.template.md RESEARCH-STATE.template.md SOURCES.template.md hook-sessionstart.sh tools-README.template.md; do
  [ -f "$TPL/$t" ] || { echo "FATAL: missing kit template $TPL/$t" >&2; exit 2; }
done

# --- resolve $CORPUS ---------------------------------------------------------
# auto: the target is IN-PROJECT (→ nested) if it holds any entry (incl. dotfiles) that
# is NOT a corpus artifact NOR VCS/orchestrator infra — i.e. the subject's own material.
is_inproject() {
  local d="$1" e had_glob=0
  shopt -q nullglob && had_glob=1; shopt -s nullglob dotglob
  local found=1
  for e in "$d"/*; do
    case "$(basename "$e")" in
      INDEX.md|CATALOG.md|RESEARCH-STATE*.md|HANDBOOK.md|WORKFLOW.md|*block*.md|*bloque*.md|sources|tools|retros|corpus) ;;
      .git|.gitignore|.claude|.atl) ;;
      *) found=0; break;;
    esac
  done
  [ "$had_glob" = 1 ] || shopt -u nullglob; shopt -u dotglob
  return $found
}
case "$corpus_mode" in
  flat)   corpus="$target";;
  nested) corpus="$target/corpus";;
  auto)   if is_inproject "$target"; then corpus="$target/corpus"; else corpus="$target"; fi;;
  *) echo "bad --corpus value: $corpus_mode (want auto|nested|flat)" >&2; exit 2;;
esac

# --- anti-clobber / anti-duplicate guard (the safety invariant) --------------
# A corpus is "present" at a root if ANY marker exists there — not just INDEX.md, so a
# deleted INDEX cannot expose RESEARCH-STATE to a clobber. Check BOTH candidate roots so
# a mode/heuristic mismatch cannot scaffold a second corpus alongside an existing one.
corpus_present() { local r="$1" m; for m in INDEX.md RESEARCH-STATE.md CATALOG.md; do [ -e "$r/$m" ] && return 0; done; return 1; }
if [ "$force" = 0 ]; then
  for cand in "$target" "$target/corpus"; do
    if corpus_present "$cand"; then
      echo "REFUSED: a corpus already exists at $cand (found a corpus marker)." >&2
      echo "         Not scaffolding — this would clobber or duplicate it. RESUME it, or use --force." >&2
      exit 3
    fi
  done
fi

# --- pre-flight writability (fail BEFORE any mutation) -----------------------
probe="$target/.rsdd-init-writeprobe.$$"
( : > "$probe" ) 2>/dev/null || { echo "FATAL: $target is not writable — cannot scaffold." >&2; exit 2; }
rm -f "$probe"

# --- scaffold with rollback --------------------------------------------------
created=()
rollback() { echo "FATAL: scaffold failed mid-run — rolling back what THIS run created." >&2; local p; for p in "${created[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done; }
trap rollback ERR
mk()  { if [ ! -e "$1" ]; then local top="$1"; while [ ! -e "$(dirname "$top")" ]; do top="$(dirname "$top")"; done; created+=("$top"); fi; mkdir -p "$1"; }  # track the TOPMOST newly-created ancestor so rollback leaves no orphaned empty dir
cpf() { [ -e "$2" ] || created+=("$2"); cp "$1" "$2"; }
# eje #2 — NO per-target tools/gen-catalog.py copy: research-sdd-archive.sh regenerates CATALOG.md by
# driving the KIT generator (research-sdd/templates/gen-catalog.py) over the corpus root. Seeding a copy
# only re-created the drift eje #2 eliminates (the recent BLOCK_RE change never reached seeded targets).
# tools/ IS now scaffolded as a PROVENANCE LEDGER (tools/README.md — kit-sup #5): WHY each tool exists
# (used-as-is / adapted / downloaded / created / updated-in-use). This is a different purpose from the
# gen-catalog.py drift eje #2 resolved — no per-version copy is seeded. (`tools` stays in
# is_inproject's ignore list so legacy targets that already have a tools/ dir classify correctly.)
mk  "$corpus/sources"; mk "$target/.claude/hooks"; mk "$target/retros"; mk "$target/tools"
cpf "$TPL/INDEX.template.md"          "$corpus/INDEX.md"
cpf "$TPL/RESEARCH-STATE.template.md" "$corpus/RESEARCH-STATE.md"
cpf "$TPL/SOURCES.template.md"        "$corpus/sources/SOURCES.md"
cpf "$TPL/hook-sessionstart.sh"       "$target/.claude/hooks/research-protocol.sh"
cpf "$TPL/tools-README.template.md"   "$target/tools/README.md"

# .gitignore guard (METHODOLOGY §15). Ensure a trailing newline first so we never fuse
# onto a pre-existing last line the user authored.
gi="$target/.gitignore"
if [ -f "$gi" ] && [ -s "$gi" ] && [ "$(tail -c1 "$gi" 2>/dev/null)" != "" ]; then printf '\n' >> "$gi"; fi
[ -e "$gi" ] || created+=("$gi")
for pat in '.atl/' '.claude/'; do grep -qxF "$pat" "$gi" 2>/dev/null || printf '%s\n' "$pat" >> "$gi"; done

# version the corpus in the TARGET (never the kit — METHODOLOGY §15); record if we init'd
git_did_init=0
if ! git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then git -C "$target" init -q; git_did_init=1; fi

# --- post-flight verification (success is EARNED, not assumed) ----------------
for f in "$corpus/INDEX.md" "$corpus/RESEARCH-STATE.md" "$corpus/sources/SOURCES.md" \
         "$target/.claude/hooks/research-protocol.sh" "$target/tools/README.md"; do
  [ -f "$f" ] || { echo "FATAL: expected artifact missing after scaffold: $f" >&2; exit 1; }
done
trap - ERR   # scaffold verified — disarm rollback

# --- seed the research-state.v1 envelope from ground truth --------------------
# The copied template ships a placeholder envelope; re-seed it so a FRESH corpus starts CONTRACT-VALID
# (covered_blocks/investigable_open/blocked_open matching the seeded backlog), i.e. verify-state.sh passes
# and --next never opens on a STALE gate. Best-effort: if the seeder is unavailable (e.g. a copied-toolbelt
# test tree without status.sh), the placeholder envelope still stands — never fail the scaffold over it.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SELF_DIR/research-sdd-status.sh" ] || [ -f "$SELF_DIR/research-sdd-status.sh" ]; then
  bash "$SELF_DIR/research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1 || echo "  note: could not seed the research-state.v1 envelope (run --sync-state manually)"
fi

# --- report ------------------------------------------------------------------
rel="${corpus#"$target"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="(target root, flat)"
echo "== research-sdd-init: scaffolded =="
echo "  target : $target"
echo "  corpus : ${rel}"
echo "  created: INDEX.md · RESEARCH-STATE.md · sources/SOURCES.md · hook · retros/ · tools/README.md · .gitignore"
echo "  catalog: CATALOG.md is regenerated by research-sdd-archive.sh via the KIT generator (no per-target copy — eje #2)"
[ "$git_did_init" = 1 ] && echo "  git    : initialized a new repo in the target" \
                        || echo "  git    : target is ALREADY under git — files land as untracked (git add as needed)"
echo "  remote : no remote — run $KIT/toolbelt/ensure-remote.sh $target --yes when you consent to push (PRIVATE, consent-gated)"
echo
echo "-- JUDGMENT follow-ups (NOT mechanizable — do these next) --"
echo "  1. REGISTER the target row in $KIT/TARGETS.md (name·path·maturity·artifact·wrapper·language)"
echo "     — else sweep-retros.sh cannot see its retros/ (§18)."
echo "  2. CLASSIFY the artifact + declare the ANGLE (PROMPT-LOOP §b/§b2); run profile-target.sh + detect-tools.sh."
echo "  3. SEED 5-15 real gaps into $corpus/RESEARCH-STATE.md (audit-first for a mature corpus)."
echo "  4. REGISTER + ADAPT the hook: put research-protocol.sh in $target/.claude/settings.json"
echo "     (matcher startup|resume|clear); replace <SUBJECT> + real source paths."
[ "$rel" != "(target root, flat)" ] && echo "     For this NESTED corpus, PREFIX the hook's block/INDEX/CATALOG paths with corpus/."
[ -n "$prefix" ] && echo "  5. Block files use the prefix: ${prefix}-blockN.md"
echo "== done =="
