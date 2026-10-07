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
#     $TARGET/corpus/), keyed on ANY corpus marker (INDEX/RESEARCH-STATE/RESEARCH-STATE-<focus>
#     §16 multi-focus form/CATALOG) — so it never clobbers hand-curated state and never
#     duplicates a corpus.
#   - PRE-FLIGHT writability probe: fails BEFORE any mutation if $TARGET is read-only.
#   - `set -euo pipefail` + a ROLLBACK trap: any mid-run failure removes exactly what
#     THIS run created (never a pre-existing file) and exits non-zero — no half-scaffold
#     left behind, no green report over a broken tree.
#   - POST-FLIGHT verification: success is printed only after all artifacts are confirmed.
#
# Usage: research-sdd-init.sh <target-dir> [--corpus auto|nested|flat] [--prefix <slug>] [--subject "<phrase>"]
#        [--force] [--wire] [--no-wire] [--scaffold] [--document]
# ENGRAM (kit issue #1903): a scaffold also writes <target>/.engram/config.json ({"project_name": "<dir name, lowercased, non-alphanumeric runs -> ->"}),
# CREATE-ONLY (an existing config is kept: `kept:` line; a dangling symlink at the path is refused, exit 2; a directory name with no
# usable character is a typed `WARN:` line and no file). INIT CANNOT CALL MCP: the AGENT must call
# mem_session_start(directory=<target>) before the first §20 mirror (mem_save), else mem_save(project=<new>) fails unknown_project.
# HOOK PLACEHOLDERS (kit issue #1845): hook-sessionstart.sh carries three LIVE (non-comment) placeholders, listed ONCE in
# _RSDD_HOOK_PLACEHOLDERS and shared by the fill and the guard: <SUBJECT> (filled by --subject "<phrase>", a noun phrase read
# as "research of <phrase>"), <prefix> (filled by --prefix) and the <path to ...> primary-sources placeholder (no flag can
# fill it: --wire WARNs with the next step). The fill happens only when THIS run creates the hook (scaffold, or --wire creating
# an absent one). On EVERY path (scaffold, scaffold+wire, wire-only) --subject against an EXISTING hook is REFUSED (exit 3,
# typed REFUSED line, nothing written) — never a silent overwrite — unless --force, which (as always) re-scaffolds over the
# corpus and hook. --prefix (also the corpus block-prefix flag, re-passed on re-wires) leaves an existing hook untouched and
# prints a typed `note:` (exit 0); a scaffold with NEITHER flag over an existing hook keeps it as well (`kept:`, kit #1860). A bad value (blank, multi-line, a control character, starting with `--`, or containing a
# placeholder token) is exit 2 before any write, on re-wires too; so is --subject/--prefix as the last argument with no value.
# On the wire-only path the SessionStart hook is filled in a staging dir BEFORE anything is created, so a failed fill writes
# nothing (an unusable TMPDIR is a typed FATAL, exit 2, before any write); the hook is then installed no-clobber (a hook that
# appeared after the existence check is kept); the staging dir is removed right after the install, and the trap removes it
# (and the fill temp file) on EXIT, INT and TERM for every other path.
# --wire still gates SessionStart registration on <SUBJECT> ONLY: the code never treated the others as blocking, and the
# already-wired fleet carries <prefix>/<path to ...> in adapted hooks; they are named WARNs, not blockers.
# Exit: 0 = scaffolded · 2 = bad args/target/not-writable/a newline in the target path / a dangling symlink at any path the run would write (.claude, .claude/hooks, hooks, scaffold files; settings.json only with --wire) (kit issue #1043: refused before any write) · 3 = corpus already exists (refused) ·
#       4 = wire-only: existing .claude/settings.json is non-empty but not a JSON object with a
#           valid .hooks shape or is a dangling symlink (wire-only), OR the settings.json merge/atomic install itself failed (refused/aborted,
#           nothing written — never reported as success) ·
#       5 = --wire refused: no corpus marker (INDEX.md/RESEARCH-STATE.md/RESEARCH-STATE-<focus>.md/
#           CATALOG.md) was found at $target or $target/corpus, and --scaffold was not also given —
#           nothing written at all, REGARDLESS of --force (kit issue #1047: an operator asking to
#           WIRE never intends to SCAFFOLD; --force only bypasses the anti-clobber guard on an
#           EXISTING corpus, never implicit scaffolding of a marker-less target) · --scaffold given
#           without --wire is a usage error (exit 2): it has no effect on its own.
#
# PROPOSE-NEVER-APPLY (METHODOLOGY): by default, prints the .claude/settings.json hook wiring snippet
# for the operator to paste. Pass --wire to have the script write it automatically (requires jq);
# --no-wire is a backward-compat alias for the default (print-only, no write).
#
# VENDOR-LEAK GUARD WIRING (kit issue #1271 slice 2; also run by --wire on an EXISTING corpus, kit issue #1800 — a corpus that went
# PUBLIC after it was scaffolded gets the same step, same bounded probe, same typed states; a plain run on an existing corpus stays
# refused, so there the write needs --wire; jq-absent wire-only degrades before it and skips it): after a scaffold the script asks
# `gh repo view` whether the target's remote is PUBLIC. PUBLIC → scaffold a stub .research-sdd/vendor-leak.conf
# (never overwritten) and propose a CI workflow running scan-vendor-leak.sh (printed; written to
# .github/workflows/vendor-leak.yml only with --wire, never overwritten). Typed states, all on stdout under
# "vendor-leak:" (PUBLIC also proposes — printed; written with --wire into the git hooks dir, honouring core.hooksPath — a pre-push hook
# running scan-vendor-leak.sh --tracked; a pre-push hook that is not ours is NEVER touched: typed "skipped (foreign pre-push hook)" + the line to add by hand): SUBDIR (target is not the repo root: nothing probed or written) · NO-REMOTE (no gh call) · PRIVATE (no scaffold) · PUBLIC · DEGRADED (gh missing/failing/
# unrecognised answer — never a silent pass, never fails the corpus scaffold).
#
# DOCUMENT-CYCLE SCAFFOLD VARIANT (kit issue #1114): --document swaps the RESEARCH-STATE.md source
# template from RESEARCH-STATE.template.md (gap-discovery / NORMAL CYCLE) to
# RESEARCH-STATE-document.template.md (OUTLINE-driven / DOCUMENT CYCLE, METHODOLOGY §20). The
# generic template seeds discovery-style Gap-backlog placeholder rows a document-cycle run never
# discovers or closes — PROMPT-LOOP's DOCUMENT CYCLE preflight passes --document precisely to avoid
# that mismatch. The flag affects ONLY which RESEARCH-STATE.md source is copied during a full
# scaffold. On the wire-only-repair path (an EXISTING corpus, --wire, no --force) it is REJECTED
# (exit 2) rather than silently ignored, since that path never touches RESEARCH-STATE.md — see the
# rejection guard further down, nested inside the wire-only-repair section. Omitted, the default
# scaffold is unchanged.
#
# WIRE-ONLY REPAIR (kit issue #1038, hardened by #1040 rounds 2 and 3): --wire on a target whose
# corpus already exists (and no --force) skips the scaffold and instead REPAIRS whatever hooks
# are missing — it creates any absent hook file (never overwrites an existing one; a hand-adapted
# hook is untouched) and merges .claude/settings.json (pretty-printed, so a hand-maintained file
# keeps its indentation). An existing NON-EMPTY settings.json is validated as a JSON object with
# a valid .hooks shape BEFORE any hook file is created (exit 4, nothing written, otherwise — this
# catches an unparseable file, a top-level array, and an object whose .hooks is not itself an
# object; a ZERO-BYTE file is treated as {}, not refused); a merge failure downstream ALSO exits
# 4, never 0. Dedup recognises a hook already registered via $CLAUDE_PROJECT_DIR — unquoted,
# variable-quoted, brace-expanded, or the WHOLE command string quoted — as the SAME hook as the
# absolute path this script writes, on both Stop and SessionStart, and reports "already wired"
# rather than re-claiming credit for an entry that was already there (including when SessionStart
# wiring is itself skipped for a live placeholder but an earlier entry is already present).
# SessionStart is wired only when research-protocol.sh EXISTS and no longer carries a LIVE
# (non-comment-line) <SUBJECT> placeholder; an absent or unadapted hook prints a WARN and is
# skipped, while Stop is still merged. jq absent ⇒ no writes at all (no hook files, no
# settings.json) — print-only, and the printed snippet also honors the #959 SessionStart guard
# (including when the hook file does not exist yet).
#
# --wire REFUSES TO IMPLICITLY SCAFFOLD (kit issue #1047): when NO corpus marker is found at
# either candidate root ($target or $target/corpus), --wire alone REFUSES (typed message, exit 5,
# nothing written — no dirs, no .gitignore edit, no git init) instead of silently falling through
# to a full scaffold. An operator asking to WIRE never intends to SCAFFOLD. This refusal applies
# EVEN WITH --force (round 2 hardening: --force previously bypassed it entirely, silently
# scaffolding a marker-less target) — --force only ever means "bypass the anti-clobber guard on an
# EXISTING corpus", never "scaffold something that does not exist yet". Pass --scaffold together
# with --wire to opt in to scaffolding AND wiring in one call (--scaffold without --wire is a
# usage error, exit 2 — it has no effect on its own); that combined path applies the SAME
# <SUBJECT> SessionStart guard as the wire-only repair path above — a freshly-copied
# hook-sessionstart.sh always carries a LIVE (non-comment) <SUBJECT> placeholder, so SessionStart
# wiring is skipped (WARN) until the operator adapts it, exactly like the repair path. The
# recognized corpus-marker forms (both here and in the anti-clobber guard) are INDEX.md,
# RESEARCH-STATE.md, the §16 multi-focus RESEARCH-STATE-<focus>.md, and CATALOG.md — a
# multi-focus-only corpus (no plain RESEARCH-STATE.md) is still a real, present corpus.

set -Eeuo pipefail   # -E: ERR trap must be inherited into functions, or rollback never fires

# -P/pwd -P: see research-sdd/toolbelt/verify-cd-physical.sh's own header for why (kit issue
# #1024). CONSEQUENCE (round 5, Opus finding 4): $KIT — and therefore every path this script
# PERSISTS into a newly-scaffolded target (the retro-gate hook's <KIT> substitution) or PRINTS as
# user-facing guidance (the "REGISTER ... in $KIT/TARGETS.md" / "$KIT/toolbelt/..." lines) — is
# now the PHYSICALLY resolved kit path, following any symlink in this script's own invocation
# path. If the kit checkout is reached through a symlink, these name the symlink's REAL target,
# not the symlink path — intentional, not a regression to work around.
_RSDD_TB="$(cd -P "$(dirname "$0")" && pwd -P)"   # toolbelt dir, resolved ONCE (a later cwd change must not break $0-relative lookups)
KIT="$(cd -P "$(dirname "$0")/.." && pwd -P)"     # .../research-sdd
TPL="$KIT/templates"
# kit issue #1732: the return-token Stop gate is NOT copied into the target (it needs no per-target placeholder and
# must track the kit): the second Stop entry points at the kit script itself, which defaults its target to the hook cwd.
# The registered command is DOUBLE-QUOTED so a kit path with spaces (WSL /mnt/c/Users/First Last/...) is not word-split.
_RSDD_GATE_PATH="$KIT/toolbelt/return-token-gate.sh"
_RSDD_GATE_CMD="\"$_RSDD_GATE_PATH\""
# kit issue #1787 item 1: the stale-KIT drift hook (verify-skill-drift-hook.sh -> install --verify) is wired into a target's
# SessionStart the same way (kit-path command, double-quoted, no per-target copy), so a target session running hooks from a
# shared kit checkout that is behind origin/main is told so. The hook bounds itself (a watchdog around install --verify),
# needs no cwd or env, is silent when nothing is stale and always exits 0, so it cannot block a session start.
_RSDD_DRIFT_PATH="$KIT/toolbelt/verify-skill-drift-hook.sh"
_RSDD_DRIFT_CMD="\"$_RSDD_DRIFT_PATH\""

# Shared corpus-marker predicate (kit issue #1108): single source of truth with
# verify-registry.sh's registered-path marker check — see lib/corpus-markers.sh for why.
_ri_cm_lib="$(cd "$(dirname "$0")" && pwd)/lib/corpus-markers.sh"
if [ ! -f "$_ri_cm_lib" ]; then echo "research-sdd-init: cannot find helper $_ri_cm_lib" >&2; exit 1; fi
# shellcheck source=lib/corpus-markers.sh
. "$_ri_cm_lib"
declare -F corpus_has_marker >/dev/null 2>&1 || { echo "research-sdd-init: helper $_ri_cm_lib failed to define corpus_has_marker" >&2; exit 1; }
unset _ri_cm_lib

target=""; corpus_mode="auto"; prefix=""; subject=""; subject_given=0; force=0; wire=0; scaffold=0; document=0
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus)   corpus_mode="${2:-auto}"; shift 2;;
    --prefix)   [ $# -ge 2 ] || { echo "usage: --prefix needs a value" >&2; exit 2; }; prefix="$2"; shift 2;;
    --subject)  subject="${2:-}"; subject_given=1; shift $(( $# >= 2 ? 2 : 1 ));;   # kit issue #1845: fills <SUBJECT> when the hook is created
    --force)    force=1; shift;;
    --wire)     wire=1; shift;;
    --no-wire)  wire=0; shift;;   # backward-compat: same as default (print-only)
    --scaffold) scaffold=1; shift;;   # kit issue #1047: explicit opt-in to scaffold+wire in one call
    --document) document=1; shift;;   # kit issue #1114: seed the DOCUMENT CYCLE (outline-driven) RESEARCH-STATE variant
    -*)         echo "unknown flag: $1" >&2; exit 2;;
    *)          target="$1"; shift;;
  esac
done
[ -n "$target" ] && [ -d "$target" ] || { echo "usage: research-sdd-init.sh <target-dir> [--corpus auto|nested|flat] [--prefix <slug>] [--subject \"<phrase>\"] [--force] [--wire] [--no-wire] [--scaffold] [--document]" >&2; echo "       a new target is made Engram-writable (.engram/config.json, create-only); init cannot call MCP, so the AGENT must call mem_session_start(directory=<target>) before the first section-20 mirror (kit issue #1903)" >&2; exit 2; }
# kit issue #1047: --scaffold has no effect on its own — it only opts a marker-less target INTO
# scaffolding when paired with --wire. Reject rather than silently ignore, so a typo (or a
# --wire dropped by mistake) fails loudly instead of behaving as a no-op default scaffold run.
[ "$scaffold" = 1 ] && [ "$wire" = 0 ] && { echo "usage: --scaffold requires --wire (it only opts a marker-less target into scaffold+wire; pass --scaffold --wire, or drop --scaffold for the ordinary print-only scaffold)" >&2; exit 2; }
target="$(cd "$target" && pwd)"
# kit issue #1043 (3): a newline in the target path cannot be rendered into the one-line hook
# placeholders (or the printed snippet) — refuse up front, typed, before any write.
case "$target" in *$'\n'*) echo "FATAL: target path contains a newline — refusing (nothing written): $target" >&2; exit 2;; esac

# templates must exist or we fail CLEANLY (never a half-scaffold)
for t in INDEX.template.md RESEARCH-STATE.template.md SOURCES.template.md hook-sessionstart.sh hook-stop-retro-gate.sh hook-pretool-pkill-guard.sh tools-README.template.md; do
  [ -f "$TPL/$t" ] || { echo "FATAL: missing kit template $TPL/$t" >&2; exit 2; }
done
# kit issue #1114: RESEARCH-STATE-document.template.md is required ONLY when --document is actually
# going to be used — a target missing it must not break the (far more common) default scaffold path.
if [ "$document" = 1 ]; then
  [ -f "$TPL/RESEARCH-STATE-document.template.md" ] || { echo "FATAL: missing kit template $TPL/RESEARCH-STATE-document.template.md (required by --document)" >&2; exit 2; }
fi

# --- corpus_present helper (shared by wire-only, anti-clobber, and #1047 refusal sections) ---
# RESEARCH-STATE*.md covers BOTH the single-focus RESEARCH-STATE.md AND the §16 multi-focus
# naming convention RESEARCH-STATE-<focus>.md (same glob lib/state-files.sh's list_state_files
# uses for corpus-wide state-file enumeration) — a multi-focus-only corpus (no plain
# RESEARCH-STATE.md, only RESEARCH-STATE-<focus>.md files) is still a real, present corpus.
# *.template.md is excluded so a stray copied template never counts as a marker.
# kit issue #1108: the predicate itself now lives in lib/corpus-markers.sh (single source of
# truth with verify-registry.sh's registered-path marker check) — this wrapper keeps the
# established name/call sites in this script unchanged.
corpus_present() {
  corpus_has_marker "$1"
}

# kit issue #1043 (1): escape the three characters that are special in the REPLACEMENT of a
# `sed "s|...|...|"` expression — backslash (escape), `&` (re-inserts the match) and `|` (our
# delimiter) — so a target/kit path containing them is rendered literally, not mangled or rejected.
_rsdd_sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# kit issue #1043 (1): render the <KIT>/<TARGET> placeholders of a copied hook template in place.
_rsdd_render_hook() {
  local f="$1" k t
  k="$(_rsdd_sed_escape "$KIT")"; t="$(_rsdd_sed_escape "$target")"
  sed -i "s|<KIT>|$k|g; s|<TARGET>|$t|g" "$f"
}

# kit issue #1043 (2)/(3): a DANGLING symlink (-L but not -e) at a path this script would write
# makes `cp` refuse mid-run and, on the scaffold path, lets the rollback delete the user's link.
# Callers check every such path BEFORE any write; this prints the offenders and returns 1.
_rsdd_dangling_symlinks() {
  local p bad=0
  for p in "$@"; do
    if [ -L "$p" ] && [ ! -e "$p" ]; then echo "FATAL: $p is a dangling symlink — refusing before any write (nothing created or changed). Fix or remove the link, then re-run." >&2; bad=1; fi
  done
  return "$bad"
}

# kit issue #1043 (3): install a freshly-merged settings file ATOMICALLY. The temp file is created
# in the SAME directory as the real destination (so the final mv is a same-filesystem rename), the
# mode of an existing file is copied onto it, and a symlinked settings.json is resolved first so the
# rename replaces the link TARGET and the link itself survives. A failed write removes the temp and
# leaves the original bytes untouched (an in-place `cat >` would truncate them). Caller guarantees
# $2 is not a dangling symlink.
_rsdd_install_settings() {
  local tmp="$1" dest="$2" real tmp2
  real="$(readlink -f -- "$dest")" || { rm -f "$tmp"; return 1; }
  tmp2="$(mktemp "$(dirname "$real")/.settings.XXXXXX")" || { rm -f "$tmp"; return 1; }
  if cat "$tmp" > "$tmp2" \
     && { [ ! -e "$real" ] || chmod --reference="$real" "$tmp2"; } \
     && { [ -e "$real" ] || chmod "$(printf '%o' $((0666 & ~$(umask))))" "$tmp2"; } \
     && mv -f "$tmp2" "$real"; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp" "$tmp2"; return 1
}

# kit issue #1845: the ONE list of live placeholders of hook-sessionstart.sh. The fill (_rsdd_fill_hook) and every guard
# (_rsdd_hook_has_placeholder / _rsdd_warn_other_placeholders) iterate THIS list, so they cannot diverge when the template
# grows a placeholder. Never match on template line numbers: three template generations exist in the field.
_RSDD_PH_SUBJECT='<SUBJECT>'
_RSDD_HOOK_PLACEHOLDERS=("$_RSDD_PH_SUBJECT" '<prefix>' '<path to binaries/decompiled output/source code of the system under study>')

# kit issue #1040 finding 3 (round 2 of #1038): detect a placeholder only in NON-COMMENT lines. The
# shipped template's own header comments legitimately contain the literal token, and a real
# adaptation that leaves those comments untouched (api-paneles repro) must not be misread as
# unadapted — that silently blocks SessionStart forever.
_rsdd_hook_has_placeholder() {
  local f="$1" ph="$2"
  [ -f "$f" ] || return 1
  grep -qF -- "$ph" < <(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null)
}
# SessionStart registration is gated on <SUBJECT> ONLY (see the header): this is the gate every call site uses.
_rsdd_has_live_subject_placeholder() { _rsdd_hook_has_placeholder "$1" "$_RSDD_PH_SUBJECT"; }

# kit issue #1845: WARN (stderr) naming every live placeholder OTHER than the gating <SUBJECT> one (the call sites keep
# their own, context-specific <SUBJECT> WARN) with the exact next step. None of these blocks SessionStart wiring.
_rsdd_warn_other_placeholders() {
  local f="$1" ph step
  for ph in "${_RSDD_HOOK_PLACEHOLDERS[@]}"; do
    [ "$ph" = "$_RSDD_PH_SUBJECT" ] && continue
    _rsdd_hook_has_placeholder "$f" "$ph" || continue
    case "$ph" in
      '<prefix>') step="replace it with the block-file prefix (the --prefix slug) by hand";;
      *)          step="no flag can fill it: edit the hook and list the real primary-source paths (binaries / decompiled output / source of the system under study) under item 3";;
    esac
    echo "WARN: $f still contains the $ph placeholder — $step. SessionStart wiring is NOT blocked by it." >&2
  done
}

# kit issue #1845: the value a flag supplies for one placeholder; rc 1 = no flag fills it (or it was not given).
_rsdd_placeholder_value() {
  case "$1" in
    "$_RSDD_PH_SUBJECT") [ "$subject_given" = 1 ] && printf '%s' "$subject";;
    '<prefix>')          [ -n "$prefix" ] && printf '%s' "$prefix";;
    *)                   return 1;;
  esac
}
# Escape the regex metacharacters of a LITERAL placeholder for the pattern side of `sed "s|...|...|"`.
_rsdd_sed_pattern_escape() { printf '%s' "$1" | sed -e 's/[][\\.*^$|]/\\&/g'; }

# kit issue #1845: the fill's temp file and the wire-only staging dir, removed by the trap below on EXIT, INT and TERM.
_RSDD_FILL_TMP=""; _RSDD_STAGE=""; _RSDD_OWNED_DEST=""
_rsdd_cleanup_tmp() {
  [ -z "$_RSDD_FILL_TMP" ] || rm -f -- "$_RSDD_FILL_TMP"
  [ -z "$_RSDD_OWNED_DEST" ] || rm -f -- "$_RSDD_OWNED_DEST"   # kit issue #1914 review: an exclusively-created hook a signal interrupted before it was filled
  [ -z "$_RSDD_STAGE" ] || rm -rf -- "$_RSDD_STAGE"
}
trap '_rsdd_cleanup_tmp' EXIT
trap '_rsdd_cleanup_tmp; exit 130' INT
trap '_rsdd_cleanup_tmp; exit 143' TERM

# kit issue #1845: every failed fill removes its temp file and returns 1 with a typed FATAL; the hook stays exactly as copied.
_rsdd_fill_abort() {  # <tmp> <message>
  rm -f "$1"
  _RSDD_FILL_TMP=""
  echo "FATAL: $2" >&2
  return 1
}

# kit issue #1845: fill the flag-supplied placeholders of a freshly copied hook, NON-COMMENT lines only, in ONE rewrite: all
# substitutions go through a single temp file in the hook's own directory (never `sed -i`, whose flag differs on BSD/macOS)
# and are installed with one mv, so a failure at any step leaves the hook as copied (never half-filled) and no temp file.
# A typed FATAL (rc 1, never a silent no-op) when a placeholder a flag was given for is absent from the template or survives.
_rsdd_fill_hook() {
  local f="$1" ph val tmp
  local -a exprs=()
  for ph in "${_RSDD_HOOK_PLACEHOLDERS[@]}"; do
    val="$(_rsdd_placeholder_value "$ph")" || continue
    if ! _rsdd_hook_has_placeholder "$f" "$ph"; then
      echo "FATAL: the kit template $TPL/hook-sessionstart.sh carries no live $ph placeholder — nothing to fill from the flag (hook as copied: $f)" >&2; return 1
    fi
    exprs+=(-e "/^[[:space:]]*#/! s|$(_rsdd_sed_pattern_escape "$ph")|$(_rsdd_sed_escape "$val")|g")
  done
  [ "${#exprs[@]}" -gt 0 ] || return 0
  tmp="$(mktemp "$(dirname "$f")/.hook.XXXXXX")" || { echo "FATAL: could not create a temp file beside $f (hook left as copied)" >&2; return 1; }
  _RSDD_FILL_TMP="$tmp"   # the INT/TERM/EXIT trap removes it if the run is interrupted before the mv
  cp -p "$f" "$tmp" || { _rsdd_fill_abort "$tmp" "could not copy $f to its temp file (hook left as copied)"; return 1; }   # carries the mode over
  sed "${exprs[@]}" "$f" > "$tmp" || { _rsdd_fill_abort "$tmp" "sed failed filling $f (hook left as copied)"; return 1; }
  for ph in "${_RSDD_HOOK_PLACEHOLDERS[@]}"; do
    _rsdd_placeholder_value "$ph" >/dev/null || continue
    if _rsdd_hook_has_placeholder "$tmp" "$ph"; then _rsdd_fill_abort "$tmp" "$ph survived the fill of $f (hook left as copied)"; return 1; fi
  done
  mv -f "$tmp" "$f" || { _rsdd_fill_abort "$tmp" "could not install the filled hook over $f (hook left as copied)"; return 1; }
  _RSDD_FILL_TMP=""
}

# kit issue #1860: stage + fill the SessionStart hook in a mktemp dir OUTSIDE the target (wire-only path). An unwritable or
# missing TMPDIR is a typed FATAL (exit 2) with nothing written: the staging runs before anything is created in the target.
_rsdd_stage_hook() {
  _RSDD_STAGE="$(mktemp -d)" || { _RSDD_STAGE=""; echo "FATAL: could not create a staging directory for the hook (nothing written; check TMPDIR)" >&2; exit 2; }
  cp "$TPL/hook-sessionstart.sh" "$_RSDD_STAGE/hook" || { echo "FATAL: could not stage $TPL/hook-sessionstart.sh (nothing written)" >&2; exit 2; }
  _rsdd_fill_hook "$_RSDD_STAGE/hook" || exit 2
}

# kit issue #1914 review: copy <ref>'s permission bits onto <dest> on GNU AND BSD userlands. GNU `chmod --reference` first; else the
# octal mode via GNU `stat -c %a`, then BSD `stat -f %Lp` (on GNU `stat -f` is filesystem-status, never a mode, so it is only tried
# after `-c` failed). Any failure returns 1 — the caller turns it into the typed install FATAL.
_rsdd_copy_mode() {  # <ref> <dest>
  local m
  chmod --reference="$1" "$2" 2>/dev/null && return 0
  m="$(stat -c %a "$1" 2>/dev/null)" || m="$(stat -f %Lp "$1" 2>/dev/null)" || return 1
  case "$m" in ''|*[!0-7]*) return 1;; esac
  chmod "$m" "$2"
}

# kit issue #1860: install <src> at <dest> WITHOUT ever overwriting: copy to a same-directory temp (same filesystem, mode
# carried), then `ln` it into place — ln refuses an existing path (EEXIST, a dangling symlink included), which is the "kept"
# outcome (rc 1; a directory at <dest> is also kept: ln would drop the temp INSIDE it, which the -ef check detects and undoes).
# Any other ln failure (no hard links: vfat/exFAT/SMB/FUSE/9p…) falls back to an exclusive noclobber create + copy + mode; if
# that fails too it is a typed FATAL (exit 2) carrying the real ln error, never reported as kept.
_rsdd_install_noclobber() {  # <src> <dest>
  local src="$1" dest="$2" tmp rc=0
  tmp="$(mktemp "$(dirname "$dest")/.hook.XXXXXX")" || { echo "FATAL: could not create a temp file beside $dest" >&2; exit 2; }
  _RSDD_FILL_TMP="$tmp"
  cp -p "$src" "$tmp" || { echo "FATAL: could not copy $src beside $dest" >&2; exit 2; }
  local err=""
  if err="$(ln "$tmp" "$dest" 2>&1)"; then
    # a directory (or a symlink to one) at <dest> makes ln create <dest>/<tmp name>: that is not an install, it is "kept"
    if ! [ "$tmp" -ef "$dest" ]; then rm -f -- "$dest/$(basename "$tmp")"; rc=1; fi
  elif [ -e "$dest" ] || [ -L "$dest" ]; then
    rc=1   # EEXIST: the path appeared after the check
  elif ( set -C; : > "$dest" ) 2>/dev/null; then
    # no hard links here (vfat/exFAT/SMB/FUSE/9p…): exclusive create (noclobber) then fill + copy the mode; we own <dest> now
    _RSDD_OWNED_DEST="$dest"   # the trap removes it if a signal lands before the fill + mode finish (an empty hook must never read as `kept:` later)
    { cat "$tmp" > "$dest" && _rsdd_copy_mode "$tmp" "$dest"; } \
      || { rm -f -- "$dest" "$tmp"; _RSDD_OWNED_DEST=""; _RSDD_FILL_TMP=""; echo "FATAL: could not install $dest (ln: $err; fallback copy failed)" >&2; exit 2; }
    _RSDD_OWNED_DEST=""   # fully installed: the trap must not remove it
  elif [ -e "$dest" ] || [ -L "$dest" ]; then
    rc=1   # the exclusive create lost a race: kept
  else
    rm -f -- "$tmp"; _RSDD_FILL_TMP=""; echo "FATAL: could not install $dest (ln: $err)" >&2; exit 2
  fi
  rm -f -- "$tmp"; _RSDD_FILL_TMP=""
  return "$rc"
}

# kit issue #1845: validate a --subject/--prefix value BEFORE any write: non-blank, one line, no control character, no leading
# `--` (a flag swallowed as the value, e.g. `--subject --wire`), and no placeholder token (it would re-introduce a live
# placeholder, or be re-filled by a later one).
_rsdd_check_flag_value() {
  local name="$1" v="$2" ph
  if [ -z "${v//[[:space:]]/}" ]; then echo "usage: $name needs a non-blank value" >&2; return 1; fi
  case "$v" in --*) echo "usage: $name value '$v' starts with -- and looks like another flag (a missing value?)" >&2; return 1;; esac
  if [[ "$v" == *[[:cntrl:]]* ]]; then echo "usage: $name must be a single line without control characters (a newline or tab cannot be rendered into the hook)" >&2; return 1; fi
  for ph in "${_RSDD_HOOK_PLACEHOLDERS[@]}"; do
    case "$v" in *"$ph"*) echo "usage: $name must not contain the hook placeholder $ph" >&2; return 1;; esac
  done
}
[ "$subject_given" = 1 ] && { _rsdd_check_flag_value --subject "$subject" || exit 2; }
[ -n "$prefix" ] && { _rsdd_check_flag_value --prefix "$prefix" || exit 2; }
# kit issue #1845: the flags fill only a hook THIS run creates. An existing hook is never overwritten: --subject REFUSES (exit 3,
# before any write); --prefix is also the corpus block-prefix flag that operators re-pass on re-wires, so it is a typed note.
_rsdd_refuse_fill_on_existing_hook() {
  local f="$1"
  [ -e "$f" ] || return 0
  if [ "$subject_given" = 1 ]; then
    echo "REFUSED: --subject only fills a hook this run creates, but $f already exists (nothing written). Edit it by hand, or pass --force to re-scaffold the WHOLE corpus (destructive: it clobbers hand-adapted hooks, INDEX.md and backlog rows, kit issue #1038)." >&2
    exit 3
  fi
  [ -z "$prefix" ] || echo "note: --prefix not applied to existing $f (fill <prefix> by hand)"
  return 0
}

# kit issue #1040 finding 1 (round 2 of #1038), extended round 3: a hook may already be
# registered via $CLAUDE_PROJECT_DIR in any of FIVE equivalent forms instead of the absolute
# path this script writes — unquoted, the variable alone double-quoted, brace-expanded, or the
# WHOLE command string double-quoted (the form Claude Code's own docs use and the kit's own
# settings.json templates carry, kit issue #1040 round 3 finding 2). Missing any of these made a
# real target's SessionStart hook run twice (cloudflare repro: $CLAUDE_PROJECT_DIR/<rel> was
# already registered, and the literal-string dedup appended the absolute-path form alongside it).
_rsdd_cmd_variants_json() {
  local abs="$1" rel="$2"
  jq -cn --arg a "$abs" --arg r "$rel" '[
    $a,
    ("$CLAUDE_PROJECT_DIR/" + $r),
    ("\"$CLAUDE_PROJECT_DIR\"/" + $r),
    ("${CLAUDE_PROJECT_DIR}/" + $r),
    ("\"$CLAUDE_PROJECT_DIR/" + $r + "\"")
  ]'
}

# Echo the bare absolute path of a command that is exactly a bare or double-quoted absolute path to
# return-token-gate.sh; return 1 for any other form. Used to classify STALE candidates.
_rsdd_gate_stale_path() {
  local c="$1" p="$1" quoted=0
  if [[ "$c" == \"*\" && ${#c} -ge 2 ]]; then p="${c:1:${#c}-2}"; quoted=1; fi
  case "$p" in /*/return-token-gate.sh) ;; *) return 1 ;; esac  # RSDD-GATE-STRICT
  [[ "$p" == *[\"\$\~\`\']* || "$p" == *$'\n'* ]] && return 1
  if [ "$quoted" = 0 ] && [[ "$p" == *[[:space:]]* ]]; then return 1; fi
  printf '%s' "$p"
}

# kit issue #1496 (RDD round 1): ONE merge + dedup predicate for BOTH the wire-only repair and the
# scaffold --wire path, so the two can never diverge on which already-registered forms count as the
# same hook (they did: scaffold --wire matched exact strings only). Reads the base settings JSON on
# stdin; args: <stop-abs> <ss-abs> <pk-abs> <stop-rel> <ss-rel> <pk-rel> <skip_ss true|false> <gate-abs>
# (kit issue #1732: the return-token gate command, an explicit argument, no global). Emits
# {settings, has_stop, has_ss, has_pk, has_gate, has_current, repaired, requoted, others}; a skipped SessionStart never removes an
# existing entry.
# GATE (<gate-abs> is passed double-quoted): the CURRENT gate is a Stop command equal to it, or to its bare unquoted path.
# STALE means ONLY a command that is exactly a bare or double-quoted ABSOLUTE path to .../return-token-gate.sh (no
# arguments, no interpreter prefix, no `$`, no `~`) that does NOT exist on disk (the kit moved): all such entries are DROPPED
# and listed in `repaired`. EVERY other gate-looking command (interpreter-prefixed, with arguments, relative, `~`,
# $CLAUDE_PROJECT_DIR, or an absolute path that still exists) is a working gate in another form: it is never touched, it is
# listed in `others`, and it counts as registered (has_gate), so the current <gate-abs> is appended only when no working
# gate exists in any form.
# A bare (unquoted) CURRENT gate path containing whitespace word-splits and never runs (kit issue #1757): it is NOT a current
# form (`spaced_bare`, computed once). It is rewritten to the quoted form (the kit's own entry, so safe): the bare entry goes into
# the separate `requoted` bucket (dropped like a stale one, but reported as "requoted", never "stale") and the quoted one is appended.
_rsdd_merge_settings() {
  local sv ssv pv gv base c _gp _gpath spaced_bare=0 stale='[]' requoted='[]' others='[]'
  _gpath="${8#\"}"; _gpath="${_gpath%\"}"   # <gate-abs> arrives double-quoted; the bare path is also a CURRENT form
  [[ "$_gpath" == *[[:space:]]* ]] && spaced_bare=1   # RSDD-GATE-SPACED-BARE: computed ONCE; the bare form of a spaced path is unrunnable
  sv="$(_rsdd_cmd_variants_json "$1" "$4")"; ssv="$(_rsdd_cmd_variants_json "$2" "$5")"
  pv="$(_rsdd_cmd_variants_json "$3" "$6")"
  if [ "$spaced_bare" = 1 ]; then gv="$(jq -cn --arg g "$8" '[$g]')"
  else gv="$(jq -cn --arg g "$8" --arg p "$_gpath" '[$g, $p]')"; fi
  base="$(cat)"
  while IFS= read -r c; do
    [ "$c" = "$8" ] && continue
    if [ "$c" = "$_gpath" ]; then
      if [ "$spaced_bare" = 1 ]; then requoted="$(jq -c --arg c "$c" '. + [$c]' <<<"$requoted")"; fi
      continue
    fi
    if _gp="$(_rsdd_gate_stale_path "$c")" && [ "$_gp" != "$_gpath" ]; then
      [ -e "$_gp" ] || { stale="$(jq -c --arg c "$c" '. + [$c]' <<<"$stale")"; continue; }  # RSDD-GATE-STALE
    fi
    others="$(jq -c --arg c "$c" '. + [$c]' <<<"$others")"
  done < <(jq -r '(.hooks.Stop // [])[]? | (.hooks // [])[]? | (.command // empty) | select(type == "string" and contains("return-token-gate.sh"))' <<<"$base" 2>/dev/null)
  jq --arg sc "$1" --arg ac "$2" --arg pc "$3" --arg gc "$8" \
    --argjson stop_variants "$sv" --argjson ss_variants "$ssv" --argjson pk_variants "$pv" \
    --argjson gate_variants "$gv" --argjson stale "$stale" --argjson requoted "$requoted" --argjson others "$others" \
    --argjson skip_ss "$7" '
    ((.hooks.Stop // []) | map(.hooks // [] | map(.command)) | add // []) as $stop_cmds |
    ((.hooks.SessionStart // []) | map(.hooks // [] | map(.command)) | add // []) as $ss_cmds |
    ($stop_cmds | any(. as $c | ($stop_variants | index($c)) != null)) as $has_stop |
    # kit issue #1732: has_current = the CURRENT gate command is registered; has_gate = ANY working gate (current or another form).
    ($stop_cmds | any(. as $c | ($gate_variants | index($c)) != null)) as $has_current |
    ($has_current or ($others | length) > 0) as $has_gate |
    ($ss_cmds | any(. as $c | ($ss_variants | index($c)) != null)) as $has_ss |
    # kit issue #1509: the guard only protects Bash, so a registration counts as "present" ONLY under
    # a matcher that fires for Bash ("" / absent / "*" / a regex that fully matches "Bash"); the same
    # command under e.g. matcher "Edit" is not the guard wired. An invalid regex counts as not covering.
    def covers_bash: (.matcher // "") as $m |
      ($m == "" or $m == "*" or (try ("Bash" | test("^(?:" + $m + ")$")) catch false));
    ((.hooks.PreToolUse // []) | map(select(covers_bash) | .hooks // [] | map(.command)) | add // []) as $pk_cmds |
    ($pk_cmds | any(. as $c | ($pk_variants | index($c)) != null)) as $has_pk |
    (.hooks.PreToolUse = (if $has_pk then (.hooks.PreToolUse // [])
      else (.hooks.PreToolUse // []) + [{"matcher":"Bash","hooks":[{"type":"command","command":$pc}]}] end)) |
    (.hooks.Stop = ((.hooks.Stop // [])
      + (if $has_stop then [] else [{"matcher":"","hooks":[{"type":"command","command":$sc}]}] end)
      + (if $has_gate then [] else [{"matcher":"","hooks":[{"type":"command","command":$gc}]}] end))) |
    (($stale + $requoted)) as $drop |
    (if ($drop | length) > 0 then
       # drop EVERY stale gate hook plus any unrunnable bare spaced current entry (the current quoted one was appended above only
       # when NO working gate exists); an entry emptied by the drop is removed, every other entry is left byte-identical.
       (.hooks.Stop |= map(. as $e | ($e.hooks // []) as $h | ($h | map(select(((.command // "") | IN($drop[])) | not))) as $n
                           | if ($n | length) == ($h | length) then $e elif ($n | length) == 0 then empty else ($e | .hooks = $n) end))
     else . end) |
    (.hooks.SessionStart = (if $skip_ss or $has_ss then (.hooks.SessionStart // [])
      else (.hooks.SessionStart // []) + [{"matcher":"","hooks":[{"type":"command","command":$ac}]}] end)) |
    {settings: ., has_stop: $has_stop, has_ss: $has_ss, has_pk: $has_pk, has_gate: $has_gate, has_current: $has_current, repaired: $stale, requoted: $requoted, others: $others}
  ' <<<"$base"
}

# kit issue #1732: ONE reporting block for the gate's status, shared by the wire-only repair and scaffold --wire paths
# (they carried two hand-copied renderings). Args: <merge-output-json> <settings-path>.
_rsdd_report_gate() {
  local out="$1" settings="$2" _old
  if [ "$(jq -r '.repaired | length' <<<"$out")" != 0 ]; then
    jq -r '.repaired[] | ltrimstr("\"") | rtrimstr("\"")' <<<"$out" | while IFS= read -r _old; do
      echo "  wired  : Stop return-token gate repaired (stale path $_old) in $settings"
    done
  fi
  if [ "$(jq -r '.requoted | length' <<<"$out")" != 0 ]; then
    jq -r '.requoted[]' <<<"$out" | while IFS= read -r _old; do
      echo "  wired  : Stop return-token gate requoted (unquoted path with whitespace $_old would word-split) in $settings"
    done
  fi
  if [ "$(jq -r '.has_current | not' <<<"$out")" = "true" ] && [ "$(jq -r '.others | length' <<<"$out")" != 0 ]; then
    echo "  wired  : Stop return-token gate already wired (other form: $(jq -r '.others[0]' <<<"$out")) in $settings"
  elif [ "$(jq -r '(.repaired | length) + (.requoted | length)' <<<"$out")" != 0 ]; then :
  elif [ "$(jq -r '.has_gate' <<<"$out")" = "true" ]; then
    echo "  wired  : Stop return-token gate already wired in $settings"
  else
    echo "  wired  : Stop return-token gate registered in $settings"
  fi
}

# kit issue #1787 item 1: register the stale-KIT drift hook under SessionStart of an ALREADY-merged settings file, with the
# gate's machinery: the current command is the double-quoted kit path; a bare current path with whitespace word-splits and is
# rewritten (requoted); an exact bare/quoted ABSOLUTE path to .../verify-skill-drift-hook.sh that no longer exists is STALE and
# dropped (the kit moved); every other form (interpreter prefix, arguments, relative, ~, $CLAUDE_PROJECT_DIR, an absolute
# path that still exists) is a working registration in another form: never touched, and nothing is added next to it. Other
# SessionStart entries stay byte-identical; a re-run that changes nothing writes nothing. Prints typed "wired" lines.
# Args: <settings-path>. rc 1 = could not read/merge/install (the caller must not report success).
_rsdd_wire_drift() {
  local settings="$1" base c p quoted have=0 add=true drop='[]' others="" tmp rep=""
  # ADVISORY (RDD round 1): a failure here is a typed WARN on stdout + rc 1, never fatal for the core wire (the caller keeps going).
  local w="  WARN   : drift hook not registered:"
  # RSDD_TEST_DRIFT_FAIL is a test seam only: it forces this failure path (the real ones need a broken filesystem).
  [ -z "${RSDD_TEST_DRIFT_FAIL:-}" ] || { echo "$w forced failure (test seam) — $settings left as the core wire wrote it"; return 1; }
  [ -s "$settings" ] || { echo "$w $settings is missing or empty"; return 1; }
  base="$(cat "$settings")" || { echo "$w could not read $settings"; return 1; }
  while IFS= read -r c; do
    if [ "$c" = "$_RSDD_DRIFT_CMD" ]; then have=1; continue; fi
    if [ "$c" = "$_RSDD_DRIFT_PATH" ]; then
      if [[ "$c" == *[[:space:]]* ]]; then   # RSDD-DRIFT-SPACED-BARE
        drop="$(jq -c --arg c "$c" '. + [$c]' <<<"$drop")"
        rep="$rep  wired  : SessionStart stale-KIT drift hook requoted (unquoted path with whitespace $c would word-split) in $settings"$'\n'
      else have=1; fi
      continue
    fi
    p="$c"; quoted=0
    if [[ "$c" == \"*\" && ${#c} -ge 2 ]]; then p="${c:1:${#c}-2}"; quoted=1; fi
    if [[ "$p" == /*/verify-skill-drift-hook.sh && "$p" != *[\"\$\~\`\']* && "$p" != *$'\n'* && ! -e "$p" ]] \
       && { [ "$quoted" = 1 ] || [[ "$p" != *[[:space:]]* ]]; }; then   # RSDD-DRIFT-STALE
      drop="$(jq -c --arg c "$c" '. + [$c]' <<<"$drop")"
      rep="$rep  wired  : SessionStart stale-KIT drift hook repaired (stale path $p) in $settings"$'\n'
      continue
    fi
    [ -n "$others" ] || others="$c"
  done < <(jq -r '(.hooks.SessionStart // [])[]? | (.hooks // [])[]? | (.command // empty) | select(type == "string" and contains("verify-skill-drift-hook.sh"))' <<<"$base" 2>/dev/null)
  if [ "$have" = 1 ] || [ -n "$others" ]; then add=false; fi
  if [ "$drop" = '[]' ] && [ "$add" = false ]; then
    if [ "$have" = 1 ]; then echo "  wired  : SessionStart stale-KIT drift hook already wired in $settings"
    else echo "  wired  : SessionStart stale-KIT drift hook already wired (other form: $others) in $settings"; fi
    return 0
  fi
  tmp="$(mktemp)" || { echo "$w mktemp failed"; return 1; }
  if ! jq --argjson drop "$drop" --argjson add "$add" --arg cmd "$_RSDD_DRIFT_CMD" '
      (if ($drop | length) > 0 then
         (.hooks.SessionStart |= map(. as $e | ($e.hooks // []) as $h | ($h | map(select(((.command // "") | IN($drop[])) | not))) as $n
                                     | if ($n | length) == ($h | length) then $e elif ($n | length) == 0 then empty else ($e | .hooks = $n) end))
       else . end)
      | if $add then .hooks.SessionStart = ((.hooks.SessionStart // []) + [{"matcher":"","hooks":[{"type":"command","command":$cmd,"timeout":15}]}]) else . end
    ' <<<"$base" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then rm -f "$tmp"; echo "$w jq could not edit $settings (unexpected SessionStart shape?)"; return 1; fi
  _rsdd_install_settings "$tmp" "$settings" || { echo "$w could not write $settings (left untouched)"; return 1; }
  printf '%s' "$rep"
  if [ "$add" = true ] && [ -z "$rep" ]; then echo "  wired  : SessionStart stale-KIT drift hook registered in $settings"
  elif [ "$add" = false ]; then
    # a stale/requoted entry was dropped in this run AND a working registration remains: say which one remains (never an empty "other form")
    if [ "$have" = 1 ]; then echo "  wired  : SessionStart stale-KIT drift hook already wired in $settings"
    else echo "  wired  : SessionStart stale-KIT drift hook already wired (other form: $others) in $settings"; fi
  fi
  return 0
}

# kit issue #1040 finding 2 (round 2 of #1038): the print-only fallback — jq absent, or jq
# processing failure — must honor the SAME #959 guard as the live-write path: never offer a
# SessionStart line to paste while research-protocol.sh still carries a live <SUBJECT>.
_rsdd_print_wire_snippet() {
  local stop_cmd="$1" ss_cmd="$2" skip_ss="$3" tgt="$4" pk_cmd="$5"
  echo "-- §479 HOOK WIRING snippet (paste into $tgt/.claude/settings.json) --"
  _rsdd_print_wire_block "$stop_cmd" "$ss_cmd" "$skip_ss" "$pk_cmd"
  if [ "$skip_ss" = "true" ]; then
    echo "-- SessionStart omitted: $ss_cmd still has the <SUBJECT> placeholder (adapt it first, PROMPT-LOOP §c follow-up) --"
  fi
}

# JSON-escape one string value in pure bash (the degraded snippet is printed when jq is absent): backslash and quote.
_rsdd_json_esc() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }

# kit issue #1509: the JSON block alone, shared by the wire-only/degraded snippet above AND the
# scaffold print-only snippet (they used to carry two hand-copied renderings of the same block).
_rsdd_print_wire_block() {
  local stop_cmd ss_cmd="$2" skip_ss="$3" pk_cmd gate_cmd
  stop_cmd="$(_rsdd_json_esc "$1")"; ss_cmd="$(_rsdd_json_esc "$ss_cmd")"; pk_cmd="$(_rsdd_json_esc "$4")"; gate_cmd="$(_rsdd_json_esc "$_RSDD_GATE_CMD")"
  # kit issue #1496: PreToolUse (matcher Bash) carries the pkill-guard; it takes no per-target
  # params, so it is always offered (like Stop). SessionStart is omitted while unadapted (#959).
  local pk_entry="      {\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$pk_cmd\"}]}"
  local stop_entry="      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$stop_cmd\"}]}"
  local ss_entry="      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$ss_cmd\"}]}"
  local gate_entry="      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$gate_cmd\"}]}"
  local drift_entry drift_cmd
  drift_cmd="$(_rsdd_json_esc "$_RSDD_DRIFT_CMD")"
  drift_entry="      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$drift_cmd\",\"timeout\":15}]}"
  if [ "$skip_ss" = "true" ]; then
    printf '%s\n' '{' \
      '  "hooks": {' \
      '    "Stop": [' "$stop_entry," "$gate_entry" '    ],' \
      '    "PreToolUse": [' "$pk_entry" '    ],' \
      '    "SessionStart": [' "$drift_entry" '    ]' \
      '  }' \
      '}'
  else
    printf '%s\n' '{' \
      '  "hooks": {' \
      '    "Stop": [' "$stop_entry," "$gate_entry" '    ],' \
      '    "PreToolUse": [' "$pk_entry" '    ],' \
      '    "SessionStart": [' "$ss_entry," "$drift_entry" '    ]' \
      '  }' \
      '}'
  fi
}

# kit issue #1804 (follow-up of #1178): the block resume plan lives at .research-sdd/plan/current-plan.txt and must never be
# committed. Belt-and-braces against a broad `git add -A`: ensure the target's .gitignore ignores .research-sdd/plan/. Idempotent
# (an equivalent spelling already present counts: no second line), never rewrites a user line, trailing-newline safe; a
# symlinked / non-regular .gitignore is a typed DEGRADED (never written through, NOT a pass). Shared by scaffold and --wire repair.
_rsdd_gitignore_plan() {
  local tag="  gitignore:" gi="$target/.gitignore" want='.research-sdd/plan/' l
  if [ -L "$gi" ] || { [ -e "$gi" ] && [ ! -f "$gi" ]; }; then
    echo "$tag DEGRADED $gi is a symlink or not a regular file — $want not added (NOT a pass); add it by hand"; return 0
  fi
  if [ -f "$gi" ]; then
    # Like git, the LAST applicable rule wins: scan every line, remember the final ignore / negation that touches the plan dir.
    # An ignore line is "already ignored"; a final negation (`!<plan spelling>` or a `!` on its parent) re-includes the dir, which
    # is the user's explicit choice — typed NEGATED, nothing appended (propose-never-apply), never a false "already ignored".
    local n=0 st="" stl="" stn=0 core
    while IFS= read -r l || [ -n "$l" ]; do
      n=$((n + 1)); l="${l%$'\r'}"; l="${l%"${l##*[![:space:]]}"}"
      core="$l"; [ "${l#!}" != "$l" ] && core="${l#!}"
      case "$core" in
        '.research-sdd/plan/'|'/.research-sdd/plan/'|'.research-sdd/plan'|'/.research-sdd/plan'|'.research-sdd/plan/*'|'/.research-sdd/plan/*'|'.research-sdd/plan/**'|'/.research-sdd/plan/**')
          if [ "$core" = "$l" ]; then st=ignored; else st=negated; fi; stl="$l"; stn=$n ;;   # RSDD-GI-EQUIV
        '.research-sdd/*'|'/.research-sdd/*'|'.research-sdd/**'|'/.research-sdd/**')   # only forms matching paths INSIDE the parent; `!.research-sdd/` matches the dir itself and leaves the plan ignored
          if [ "$core" != "$l" ] && [ "$st" = ignored ]; then st=negated; stl="$l"; stn=$n; fi ;;   # a parent-dir negation re-includes the plan dir too
      esac
    done < "$gi"
    case "$st" in
      ignored) echo "$tag $want already ignored in $gi (equivalent line $stn: $stl)"; return 0 ;;
      negated) echo "$tag NEGATED line $stn of $gi ($stl) re-includes $want — not changed (NOT a pass); remove that line or add $want after it by hand"; return 0 ;;   # RSDD-GI-NEG
    esac
  fi
  if { [ ! -s "$gi" ] || [ "$(tail -c1 "$gi" 2>/dev/null)" = "" ] || printf '\n' >> "$gi"; } && printf '%s\n' "$want" >> "$gi"; then
    echo "$tag added $want to $gi (the block resume plan is never committed)"
  else
    echo "$tag DEGRADED could not write $gi — add $want by hand (NOT a pass)"
  fi
}

# --- vendor-leak guard wiring (kit issue #1271 slice 2) -----------------------------------------
# A PUBLIC remote makes a committed vendor binary / decompiled vendor tree a real leak that
# scan-secrets.sh cannot see (it excludes decompiled trees). So when `gh repo view` reports the
# target's remote as PUBLIC: scaffold a stub .research-sdd/vendor-leak.conf (never overwrite) and
# PROPOSE a CI workflow running scan-vendor-leak.sh (written only with --wire, never overwritten).
# Every state is typed — NO-REMOTE / PRIVATE / PUBLIC / DEGRADED — and a gh that is missing, failing or
# answering something unrecognised is DEGRADED, never a silent pass (CLAUDE.md §7). A degraded probe
# never fails the corpus scaffold itself (already verified above).
# kit issue #1271 (last item): the pre-push half of the guard, for a PUBLIC remote. Content that is pushed is already COMMITTED,
# so the hook runs the scanner with --tracked (--staged would see an empty index at push time). It is deliberately NOT --strict
# (the CI workflow is the strict gate; a comment-only stub conf must not block every local push). It is ours only when it
# carries the marker below: a hook the user wrote is NEVER overwritten (typed "skipped (foreign pre-push hook)" plus the line
# to add by hand); our own hook is refreshed with --wire when the kit path changed. Honours core.hooksPath via git-path.
_RSDD_PREPUSH_MARK="# research-sdd vendor-leak guard (pre-push)"
_rsdd_sq() { local v="$1" q="'\\''"; printf "'%s'" "${v//\'/"$q"}"; }   # POSIX single-quote a string
_rsdd_prepush_content() {
  local sc
  sc="$(_rsdd_sq "$KIT/templates/hook-prepush-vendor-leak.sh")"
  # The guard logic lives in the kit (templates/hook-prepush-vendor-leak.sh): it reads the pushed refs from stdin and scans
  # the pushed commits' content, so a push of a non-checked-out branch is checked too. The hook only hands over to it.
  printf '%s\n' '#!/usr/bin/env bash' "$_RSDD_PREPUSH_MARK — written by research-sdd-init.sh --wire (kit issue #1271); safe to delete." \
    "GUARD=$sc" \
    '[ -f "$GUARD" ] || { echo "research-sdd vendor-leak guard: $GUARD not found — this push was NOT checked (reinstall the kit or delete this hook)" >&2; exit 0; }' \
    'exec bash "$GUARD" "$@"'
}
_rsdd_prepush_wiring() {  # <tag>
  local tag="$1" hdir hook want line
  hdir="$(git -C "$target" rev-parse --git-path hooks 2>/dev/null)" && [ -n "$hdir" ] \
    || { echo "$tag DEGRADED could not resolve the git hooks directory — pre-push guard skipped (NOT a pass)"; return 0; }
  case "$hdir" in /*) ;; *) hdir="$target/$hdir" ;; esac
  hook="$hdir/pre-push"
  want="$(_rsdd_prepush_content)"
  # The guard reads git's ref lines on stdin: put this line BEFORE anything of yours that consumes stdin (or feed it a copy).
  line="bash $(_rsdd_sq "$KIT/templates/hook-prepush-vendor-leak.sh") \"\$@\" || exit 1"
  if [ -e "$hook" ] || [ -L "$hook" ]; then
    if [ -L "$hook" ] || [ ! -f "$hook" ] || ! grep -qF "$_RSDD_PREPUSH_MARK" "$hook" 2>/dev/null; then
      echo "$tag pre-push guard skipped (foreign pre-push hook) $hook — never overwritten; add this line to it by hand:"
      echo "    $line"
      return 0
    fi
    if [ "$(cat "$hook")" = "$want" ]; then echo "$tag pre-push guard already wired in $hook"; return 0; fi
    if [ "$wire" != 1 ]; then echo "$tag pre-push guard in $hook is ours but differs from the current kit path (re-run with --wire to refresh it)"; return 0; fi
  elif [ "$wire" != 1 ]; then
    echo "$tag pre-push guard (propose-never-apply: save as $hook and chmod +x, or re-run with --wire; scanner: $KIT/toolbelt/scan-vendor-leak.sh):"
    printf '%s\n' "$want" | sed 's/^/    | /'
    return 0
  fi
  if { [ -L "$hdir" ] || { [ -e "$hdir" ] && [ ! -d "$hdir" ]; }; }; then
    echo "$tag DEGRADED $hdir is a symlink or not a directory — pre-push guard not written"; return 0
  fi
  # atomic: write a sibling temp file, mark it executable, then rename over the destination (never a half-written hook)
  local hook_tmp="$hook.rsdd-tmp.$$"
  if mkdir -p "$hdir" && printf '%s\n' "$want" > "$hook_tmp" && chmod +x "$hook_tmp" && mv -f "$hook_tmp" "$hook"; then
    echo "$tag wrote pre-push guard $hook (runs scan-vendor-leak.sh --tracked before every push; delete the file to remove it)"
  else
    echo "$tag DEGRADED could not write $hook"
  fi
}

_rsdd_vendor_leak_wiring() {
  local tag="  vendor-leak:" remotes vis conf="$target/.research-sdd/vendor-leak.conf" wf="$target/.github/workflows/vendor-leak.yml"
  local tpl_conf="$TPL/vendor-leak.conf.template" tpl_ci="$TPL/vendor-leak-ci.template.yml"
  # kit issue #1800: the "what to do later" guidance must be true for the path that printed it. On an EXISTING corpus a plain run is
  # REFUSED (exit 3), so only --wire gets here again; on the scaffold path a plain run scaffolds the conf (--wire adds the workflow).
  local _vl_how="a plain run scaffolds the conf" _vl_sfx=" (--wire additionally writes the CI workflow)"
  # the mode is an explicit argument (wire | scaffold), never ambient state
  if [ "${1:-scaffold}" = wire ]; then _vl_how="re-run with --wire (a plain run on an existing corpus is refused)"; _vl_sfx=""; fi
  # Not inside a git work tree → there is no remote to ask about (NO-REMOTE); any other rev-parse failure (dubious
  # ownership, corrupt metadata) is a git failure and DEGRADED — never hidden as "nothing to ask about".
  local rp_err
  if ! rp_err="$(git -C "$target" rev-parse --is-inside-work-tree 2>&1 >/dev/null)"; then
    case "$rp_err" in
      *"not a git repository"*) ;;   # VL-NOTREPO
      *) echo "$tag DEGRADED git rev-parse failed in $target — vendor-leak wiring skipped [git: ${rp_err%%$'\n'*}]"; return 0 ;;
    esac
    echo "$tag NO-REMOTE $target is not a git work tree — nothing scaffolded; $_vl_how once the target is a git repo with a remote$_vl_sfx"
    return 0
  fi
  # kit issue #1566 R4: a SUBDIRECTORY of a repo inherits the parent's remotes, but GitHub only reads workflows from the
  # repo root's .github/workflows — wiring here would probe the wrong repo and write a file nothing runs. Typed
  # SUBDIR state, nothing written, no success claim. Both paths are resolved physically (symlinked roots compare equal).
  local _vl_top _vl_here
  _vl_top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" && _vl_here="$(CDPATH="" cd -- "$target" 2>/dev/null && pwd -P)" \
    || { echo "$tag DEGRADED could not resolve the repository root of $target — vendor-leak wiring skipped (NOT a pass)"; return 0; }
  _vl_top="$(CDPATH="" cd -- "$_vl_top" 2>/dev/null && pwd -P)" \
    || { echo "$tag DEGRADED the repository root reported by git is not reachable from $target — vendor-leak wiring skipped (NOT a pass)"; return 0; }
  if [ "$_vl_top" != "$_vl_here" ]; then
    echo "$tag SUBDIR $target is a subdirectory of the repository rooted at $_vl_top — nothing probed, scaffolded or written (GitHub only runs workflows from the repo root's .github/workflows); run the vendor-leak wiring on $_vl_top, or create .research-sdd/vendor-leak.conf and the workflow there by hand (NOT a pass)"
    return 0
  fi
  remotes="$(git -C "$target" remote 2>/dev/null)" || { echo "$tag DEGRADED could not list git remotes in $target — vendor-leak wiring skipped; re-run once git works"; return 0; }
  if [ -z "$remotes" ]; then
    echo "$tag NO-REMOTE no remote configured — nothing scaffolded; once a remote exists, $_vl_how$_vl_sfx, or create $conf by hand before making the repo public"
    return 0
  fi
  # Probe the PUSH remote explicitly — a bare `gh repo view` lets gh choose (GH_REPO, set-default, upstream
  # before origin), which may not be the repo this target publishes to. origin wins; a single other remote
  # is used; several remotes without origin are ambiguous and DEGRADED (never guessed).
  local remote gh_url
  case $'\n'"$remotes"$'\n' in
    *$'\n'origin$'\n'*) remote=origin ;;
    *) if [ "$(printf '%s\n' "$remotes" | wc -l)" -gt 1 ]; then
         echo "$tag DEGRADED ambiguous remote — several remotes and no 'origin' ($(printf '%s' "$remotes" | tr '\n' ' ')) — vendor-leak wiring skipped (NOT a pass)"
         return 0
       fi
       remote="$remotes" ;;
  esac
  gh_url="$(git -C "$target" remote get-url --push "$remote" 2>/dev/null)" && [ -n "$gh_url" ] \
    || { echo "$tag DEGRADED could not read the push URL of remote '$remote' — vendor-leak wiring skipped (NOT a pass)"; return 0; }
  # The probe is the shared bounded one (kit issue #1820, lib/gh-visibility.sh): RSDD_GH_TIMEOUT seconds (a positive
  # integer; default 20; anything else falls back to 20 with a note), GH_PROMPT_DISABLED=1, and with no `timeout`/`gtimeout`
  # a bash watchdog enforces the same bound (kit issue #1800: --wire repair must never hang). Any non-decided result is
  # a typed DEGRADED state and the caller carries on (never read as PRIVATE).
  local _ghv_lib gh_why gh_t vis
  _ghv_lib="$_RSDD_TB/lib/gh-visibility.sh"
  # shellcheck source=lib/gh-visibility.sh
  . "$_ghv_lib" 2>/dev/null && declare -F gh_visibility_probe >/dev/null 2>&1 \
    || { echo "$tag DEGRADED lib/gh-visibility.sh unavailable — cannot probe the remote visibility; vendor-leak wiring skipped (NOT a pass)"; return 0; }
  gh_visibility_probe gh "$gh_url" "$target" || :
  gh_t="$GHV_BOUND"
  [ "$GHV_BAD_TIMEOUT" = 1 ] && echo "$tag note: RSDD_GH_TIMEOUT='${RSDD_GH_TIMEOUT-20}' is not a positive integer — using the default 20s"
  [ "$GHV_BOUNDED_BY" = watchdog ] && echo "$tag note: timeout not found — the gh probe is bounded by a ${gh_t}s watchdog instead"
  gh_why=""; [ -n "$GHV_WHY" ] && gh_why=" [gh: $GHV_WHY]"
  case "$GHV_STATE" in
    PROBE_FAILED)
      echo "$tag DEGRADED could not create a temp file for the bounded gh probe — vendor-leak wiring skipped (NOT a pass)"
      return 0 ;;
    TIMEOUT)
      echo "$tag DEGRADED gh timed out after ${gh_t}s — vendor-leak wiring skipped (NOT a pass)"
      return 0 ;;
    GH_ERROR)
      if [ "$GHV_RC" = 125 ]; then
        echo "$tag DEGRADED timeout could not run gh (exit 125)$gh_why — vendor-leak wiring skipped (NOT a pass)"
      else
        echo "$tag DEGRADED gh repo view failed (auth, network or non-GitHub remote)$gh_why — vendor-leak wiring skipped (NOT a pass)"
      fi
      return 0 ;;
    GH_MISSING)
      echo "$tag DEGRADED gh not found — cannot tell whether the remote is PUBLIC; vendor-leak wiring skipped (NOT a pass). Install gh and re-run, or scaffold $conf by hand"
      return 0 ;;
  esac
  vis="$GHV_RAW"
  case "$vis" in
    PRIVATE|INTERNAL)
      echo "$tag PRIVATE remote '$remote' visibility is $vis — no vendor-leak scaffold written; if it ever becomes PUBLIC, $_vl_how$_vl_sfx"
      return 0 ;;
    PUBLIC) ;;
    *)
      echo "$tag DEGRADED gh reported an unrecognised visibility '$vis' — vendor-leak wiring skipped (NOT a pass)"
      return 0 ;;
  esac
  if [ ! -f "$tpl_conf" ] || [ ! -f "$tpl_ci" ]; then
    echo "$tag DEGRADED PUBLIC remote but kit templates missing ($tpl_conf / $tpl_ci) — nothing scaffolded"
    return 0
  fi
  echo "$tag PUBLIC remote '$remote' is PUBLIC — vendor code (decompiled trees, *.class/*.jar/*.dll/*.so/*.exe) must never be committed"
  if [ -e "$conf" ] || [ -L "$conf" ]; then
    echo "$tag kept existing $conf (never overwritten)"
  elif [ -L "$target/.research-sdd" ] || { [ -e "$target/.research-sdd" ] && [ ! -d "$target/.research-sdd" ]; }; then
    echo "$tag DEGRADED $target/.research-sdd is a symlink or not a directory — conf not scaffolded"
  elif mkdir -p "$target/.research-sdd" && cp "$tpl_conf" "$conf"; then
    echo "$tag scaffolded stub $conf — declare the vendor package prefixes / paths (scan-vendor-leak.v1.md); until then only the binary rule applies"
  else
    echo "$tag DEGRADED could not write $conf"
  fi
  if [ "$wire" = 1 ]; then
    local gh_dir="$target/.github" wf_dir="$target/.github/workflows" bad_dir=""
    if [ -L "$gh_dir" ] || { [ -e "$gh_dir" ] && [ ! -d "$gh_dir" ]; }; then bad_dir="$gh_dir"
    elif [ -L "$wf_dir" ] || { [ -e "$wf_dir" ] && [ ! -d "$wf_dir" ]; }; then bad_dir="$wf_dir"; fi
    if [ -n "$bad_dir" ]; then
      echo "$tag DEGRADED $bad_dir is a symlink or not a directory — workflow not written"
    elif [ -e "$wf" ] || [ -L "$wf" ]; then
      echo "$tag kept existing $wf (never overwritten)"
    elif mkdir -p "$target/.github/workflows" && cp "$tpl_ci" "$wf"; then
      echo "$tag wrote CI workflow $wf — fill <KIT_REPOSITORY> and <KIT_REF> before committing (an unfilled workflow fails loudly)"
    else
      echo "$tag DEGRADED could not write $wf"
    fi
  else
    echo "$tag CI guard (propose-never-apply: save as .github/workflows/vendor-leak.yml, fill the placeholders, or re-run with --wire; scanner: $KIT/toolbelt/scan-vendor-leak.sh):"
    sed 's/^/    | /' "$tpl_ci"
  fi
  _rsdd_prepush_wiring "$tag"
}
# (defined here, ahead of the wire-only repair path, so BOTH the scaffold path and --wire on an existing corpus run it — kit issue #1800)

# --- wire-only path: --wire on an existing corpus REPAIRS absent hooks + merges settings -----
# When --wire is given on a target that already has a corpus (and no --force is set), skip the
# full scaffold and instead: (1) create any hook file that is ABSENT — create-only, NEVER
# overwrite an existing one, so a hand-adapted hook survives byte-for-byte (kit issue #1038: real
# targets have a corpus but predate the hook scaffold, and `--force` is not an option because it
# clobbers hand-adapted hooks); (2) merge .claude/settings.json, wiring SessionStart ONLY when
# research-protocol.sh (existing or just created) no longer carries a LIVE <SUBJECT> placeholder
# (non-comment lines only) — an unadapted hook must never be injected as a live SessionStart card
# (kit issue #959). Stop is always safe to wire (it takes no per-target params). Dedup recognises
# $CLAUDE_PROJECT_DIR-relative forms as equivalent to the absolute path this script writes (kit
# issue #1040 finding 1), an existing settings.json is validated as JSON BEFORE any hook file is
# created (finding 2), and a re-run that finds an entry already present reports "already wired"
# rather than re-claiming credit for it (finding 4). This is both the intended workflow after
# step 4 (adapt the hook, then re-run with --wire to register it) and the repair path for a
# corpus that never had hooks scaffolded.
# --- kit issue #1047 round 2 (R3-force-bypasses-refusal): --wire on a target with NO corpus
# marker at EITHER candidate root REFUSES regardless of --force. The refusal used to live only
# inside the force=0 branch below, so `--force --wire` on a marker-less target silently fell
# through to a full scaffold — --force means "bypass the anti-clobber guard on an EXISTING
# corpus", never "scaffold something that does not exist yet". Corpus presence is computed HERE,
# unconditionally on force, and reused by the wire-only REPAIR path below (which stays
# force=0-gated and unchanged: --force on an EXISTING corpus still intentionally bypasses repair
# and falls through to a full re-scaffold, exactly as before this round).
_wo_corpus_root=""
if [ "$wire" = 1 ]; then
  for _cand in "$target" "$target/corpus"; do
    if corpus_present "$_cand" 2>/dev/null; then _wo_corpus_root="$_cand"; break; fi
  done
  if [ -z "$_wo_corpus_root" ] && [ "$scaffold" = 0 ]; then
    echo "REFUSED: --wire was given but no corpus marker (INDEX.md / RESEARCH-STATE.md / RESEARCH-STATE-<focus>.md / CATALOG.md) was found at $target or $target/corpus — refusing to scaffold implicitly (nothing written: no dirs created, no .gitignore edit, no git init)." >&2
    echo "         An operator asking to WIRE never intends to SCAFFOLD (kit issue #1047). This refusal applies EVEN WITH --force — force only bypasses the anti-clobber guard on an EXISTING corpus, never implicit scaffolding of a marker-less target. Two ways forward:" >&2
    echo "           1. Scaffold first, then wire: run $KIT/toolbelt/research-sdd-init.sh $target (without --wire) to scaffold, then re-run with --wire." >&2
    echo "           2. Scaffold AND wire in one call: re-run with --scaffold --wire." >&2
    exit 5
  fi
fi

# WIRE-ONLY-EXISTING-CORPUS
if [ "$wire" = 1 ] && [ "$force" = 0 ]; then
  if [ -n "$_wo_corpus_root" ]; then
    # kit issue #1114 (following the #1047 no-silent-no-op precedent): --document has NO EFFECT on
    # this path — it only REPAIRS hooks/settings.json and never touches RESEARCH-STATE.md. Reject
    # rather than silently ignore the flag, exactly as --scaffold-without-wire is rejected above.
    # There is no in-place way to add the document-cycle variant to an EXISTING corpus, and --force
    # is NOT a targeted fix for that: it re-scaffolds the WHOLE corpus (INDEX.md, RESEARCH-STATE.md,
    # SOURCES.md, hooks), clobbering hand-adapted hooks, INDEX.md and real backlog rows (#1038's own
    # header note above says exactly this) — never recommend it as a way to "add" the document
    # variant; state its real destructive scope instead.
    if [ "$document" = 1 ]; then
      echo "usage: --document has no effect here — --wire on an existing corpus (without --force) only REPAIRS hooks/settings.json and never touches RESEARCH-STATE.md (kit issue #1114). There is no in-place conversion: drop --document, or scaffold a NEW target with --document instead. --force is NOT a targeted fix for this — it re-scaffolds the WHOLE corpus (INDEX.md, RESEARCH-STATE.md, SOURCES.md, hooks) and clobbers hand-adapted hooks, INDEX.md and real backlog rows (kit issue #1038); it is destructive and only appropriate for a corpus you intend to discard." >&2
      exit 2
    fi
    # kit issue #1845: refuse --subject/--prefix against an existing hook BEFORE any write.
    _rsdd_refuse_fill_on_existing_hook "$target/.claude/hooks/research-protocol.sh"
    # Wire-only: compute paths; NEVER touch any corpus file.
    _wo_stop="$target/.claude/hooks/retro-gate-stop.sh"
    _wo_ss="$target/.claude/hooks/research-protocol.sh"
    _wo_stop_rel=".claude/hooks/retro-gate-stop.sh"
    _wo_ss_rel=".claude/hooks/research-protocol.sh"
    _wo_pk="$target/.claude/hooks/pkill-guard.sh"
    _wo_pk_rel=".claude/hooks/pkill-guard.sh"
    _wo_settings="$target/.claude/settings.json"

    # §7 anti-silent-zero: probe for jq FIRST — jq-absent means NO writes at all, including no
    # hook-file creation, so the target is never left half-wired (some hooks created but
    # settings.json not merged, or vice versa).
    if ! command -v jq >/dev/null 2>&1; then
      echo "degraded: jq not found on PATH — cannot wire settings.json or create hook files; paste the snippet below and create the hooks yourself:" >&2
      # kit issue #1040 round 3 finding 4: omit SessionStart from the snippet not only when the
      # hook file has a LIVE <SUBJECT> placeholder, but also when it does not exist yet — there is
      # nothing to safely offer for a hook the operator has not created (let alone adapted).
      _wo_pre_skip_ss="false"
      if [ ! -e "$_wo_ss" ]; then
        _wo_pre_skip_ss="true"
        echo "WARN: $_wo_ss does not exist yet — the snippet below omits SessionStart until you create and adapt it (PROMPT-LOOP §c follow-up)." >&2
        { [ "$subject_given" = 1 ] || [ -n "$prefix" ]; } && echo "WARN: --subject/--prefix NOT applied: no hook was created (jq is absent, so nothing is written) — re-run with jq installed." >&2
      elif _rsdd_has_live_subject_placeholder "$_wo_ss"; then
        _wo_pre_skip_ss="true"
        echo "WARN: $_wo_ss still contains the <SUBJECT> placeholder — the snippet below omits SessionStart until you adapt it (PROMPT-LOOP §c follow-up)." >&2
      fi
      _rsdd_warn_other_placeholders "$_wo_ss"
      _rsdd_print_wire_snippet "$_wo_stop" "$_wo_ss" "$_wo_pre_skip_ss" "$target" "$_wo_pk"
      echo "== done =="
      exit 0
    fi

    # kit issue #1040 round 3 finding 1: validate an EXISTING, NON-EMPTY settings.json BEFORE
    # creating any hook file — both that it parses AND that its top-level shape is usable. A
    # single `jq empty` check (round 2) let three real shapes through uncaught (parseable but
    # unusable): an empty file, a top-level array (`[]`), and an object whose `.hooks` key is not
    # itself an object (`{"hooks":"x"}`) — each one then let both hook files get created before
    # the merge failed downstream, reporting `degraded:` + exit 0 (a false success). A ZERO-BYTE
    # file is treated as equivalent to `{}` (no hooks registered yet) and is NOT refused — an
    # empty stub is not corrupt, and this keeps `: > settings.json` a harmless no-op starting
    # point. Any NON-EMPTY file that fails to parse, or parses to something other than an object
    # with an object-or-absent `.hooks`, is refused: exit 4, nothing written (no hook file
    # created, settings.json untouched).
    if [ -s "$_wo_settings" ] && ! jq -e 'type=="object" and ((.hooks // {}) | type=="object")' \
        "$_wo_settings" >/dev/null 2>&1; then
      echo "FATAL: $_wo_settings is not a JSON object with a valid .hooks shape — refusing to wire (nothing written: no hook file created, settings.json untouched). Fix or remove it, then re-run --wire." >&2
      exit 4
    fi

    # kit issue #1043: a dangling symlink at a hook path (cp would refuse AFTER the other hook was
    # written) or at settings.json (the merge would fail / write elsewhere) is refused BEFORE any
    # write, so a failure leaves no partial state.
    _rsdd_dangling_symlinks "$target/.claude" "$target/.claude/hooks" "$_wo_stop" "$_wo_ss" "$_wo_pk" || exit 2
    _rsdd_dangling_symlinks "$_wo_settings" || exit 4

    # jq is present and settings.json (if any) is valid JSON: repair absent hook files
    # (create-only — never overwrite an existing one).
    # kit issue #1845: fill the SessionStart hook in a staging dir OUTSIDE the target BEFORE anything is created here, so a
    # failed fill (typed FATAL, exit 2) writes nothing: no dirs, no Stop hook, no settings.json change.
    [ -e "$_wo_ss" ] || _rsdd_stage_hook
    mkdir -p "$target/.claude/hooks"
    if [ -e "$_wo_stop" ]; then
      echo "kept: $_wo_stop"
    else
      cp "$TPL/hook-stop-retro-gate.sh" "$_wo_stop"
      _rsdd_render_hook "$_wo_stop"
      chmod +x "$_wo_stop"
      echo "created: $_wo_stop"
    fi
    if [ -e "$_wo_ss" ]; then
      echo "kept: $_wo_ss"
    else
      # kit issue #1860: the hook existed at staging time and is gone now (nothing staged): stage it now, never `cp` from an empty path.
      [ -n "$_RSDD_STAGE" ] || _rsdd_stage_hook
      # kit issue #1860: no-clobber install — a hook that appeared after the check above is kept, never overwritten.
      if _rsdd_install_noclobber "$_RSDD_STAGE/hook" "$_wo_ss"; then   # the already-filled staged copy
        echo "created: $_wo_ss"
      else
        echo "kept: $_wo_ss"
      fi
    fi
    # kit issue #1860: explicit success-path cleanup of the staging dir (the trap stays the fallback for failures and signals).
    if [ -n "$_RSDD_STAGE" ]; then rm -rf -- "$_RSDD_STAGE"; _RSDD_STAGE=""; fi
    # kit issue #1496: pkill-guard PreToolUse hook — create-only (a hand-adapted copy is never
    # overwritten); no per-target placeholders, so it is copied as-is and always wired.
    if [ -e "$_wo_pk" ]; then
      echo "kept: $_wo_pk"
      # A hand-adapted guard is never modified, but a non-executable one is silently inert once wired.
      [ -x "$_wo_pk" ] || echo "WARN: $_wo_pk is not executable — the PreToolUse hook cannot run until you chmod +x it (left untouched: hand-adapted hooks are never modified)." >&2
    else
      cp "$TPL/hook-pretool-pkill-guard.sh" "$_wo_pk"
      chmod +x "$_wo_pk"
      echo "created: $_wo_pk"
    fi

    # kit issue #959/#1038/#1040: never wire an unadapted SessionStart hook — it would inject a
    # raw <SUBJECT> placeholder card into every session. Stop is always safe to wire. Only a LIVE
    # (non-comment) occurrence counts (finding 3) — the template's own header comments carry the
    # literal token and must not block a real adaptation that left them untouched.
    _wo_skip_ss="false"
    if _rsdd_has_live_subject_placeholder "$_wo_ss"; then
      _wo_skip_ss="true"
      echo "WARN: $_wo_ss still contains the <SUBJECT> placeholder — skipping SessionStart wiring until you adapt it (replace <SUBJECT> and the source paths, PROMPT-LOOP §c follow-up). Re-run with --wire once adapted." >&2
    fi
    _rsdd_warn_other_placeholders "$_wo_ss"   # kit issue #1845: every other live placeholder, named; none blocks SessionStart

    # kit issue #1040 finding 1: recognise $CLAUDE_PROJECT_DIR-relative forms as the same hook.
    # -s (non-empty), not -f: a ZERO-BYTE existing file is treated as {} (see the pre-validation
    # comment above) — reading it with `cat` would otherwise feed jq an empty stdin, which is a
    # jq error (no input value), not an empty object.
    _wo_base='{}'; [ -s "$_wo_settings" ] && _wo_base="$(cat "$_wo_settings")"
    _wo_tmp="$(mktemp)" || { echo "FATAL: could not create a temp file for the settings.json merge (check TMPDIR; hooks above may already be created — re-run --wire after fixing it)" >&2; exit 2; }
    if _wo_merge_out="$(printf '%s' "$_wo_base" | _rsdd_merge_settings "$_wo_stop" "$_wo_ss" "$_wo_pk" \
        "$_wo_stop_rel" "$_wo_ss_rel" "$_wo_pk_rel" "$_wo_skip_ss" "$_RSDD_GATE_CMD" 2>/dev/null)" && [ -n "$_wo_merge_out" ]; then
      # kit issue #1040 round 3 finding 3: pretty-print (not `-c` compact) so a hand-maintained
      # settings.json keeps its indentation instead of collapsing to one line.
      jq '.settings' <<<"$_wo_merge_out" > "$_wo_tmp"
      _rsdd_install_settings "$_wo_tmp" "$_wo_settings" || { echo "FATAL: could not write $_wo_settings" >&2; exit 4; }
      _wo_drift_out="$(_rsdd_wire_drift "$_wo_settings")" || :   # advisory: a typed WARN line is in the output, the core wire carries on
      _wo_has_stop="$(jq -r '.has_stop' <<<"$_wo_merge_out")"
      _wo_has_ss="$(jq -r '.has_ss' <<<"$_wo_merge_out")"
      _wo_has_pk="$(jq -r '.has_pk' <<<"$_wo_merge_out")"
      _rsdd_report_gate "$_wo_merge_out" "$_wo_settings"
      printf '%s\n' "$_wo_drift_out"
      if [ "$_wo_has_pk" = "true" ]; then
        echo "  wired  : PreToolUse pkill-guard hook already wired in $_wo_settings"
      else
        echo "  wired  : PreToolUse pkill-guard hook registered in $_wo_settings"
      fi
      if [ "$_wo_has_stop" = "true" ]; then
        echo "  wired  : Stop hook already wired (wire-only; corpus untouched) in $_wo_settings"
      else
        echo "  wired  : Stop hook registered (wire-only; corpus untouched) in $_wo_settings"
      fi
      # kit issue #1040 round 3 finding 5: when SessionStart is skipped (live <SUBJECT>) but an
      # entry was ALREADY there from an earlier run (left untouched by the merge above — $skip_ss
      # never removes an existing entry), say so — "NOT registered" would misleadingly imply
      # settings.json carries none, when it still carries the one from before.
      if [ "$_wo_skip_ss" = "true" ]; then
        if [ "$_wo_has_ss" = "true" ]; then
          echo "  wired  : SessionStart hook already wired in $_wo_settings (left as-is — <SUBJECT> placeholder is live, so the existing entry was not touched or re-added)"
        else
          echo "  skipped: SessionStart hook NOT registered (unadapted <SUBJECT> placeholder — see WARN above)"
        fi
      elif [ "$_wo_has_ss" = "true" ]; then
        echo "  wired  : SessionStart hook already wired in $_wo_settings"
      else
        echo "  wired  : SessionStart hook registered in $_wo_settings"
      fi
      _rsdd_gitignore_plan
      # kit issue #1800: an existing corpus can go PUBLIC after it was scaffolded — re-probe the push remote here too (same bounded
      # probe, propose-never-apply: conf/workflow/hook are create-only, a foreign or user-modified file is never touched). Advisory:
      # every outcome is a typed `vendor-leak:` line and never changes the exit code.
      _rsdd_vendor_leak_wiring wire
      echo "== done =="
      exit 0
    else
      rm -f "$_wo_tmp"
      echo "degraded: jq failed on $_wo_settings — refusing to report success" >&2
    fi
    # kit issue #1040 round 3 finding 1: a merge failure here must NEVER report success. Print
    # snippet on jq-processing failure (jq present but errored; settings.json shape was already
    # pre-checked above, so this branch is defensive/rare) and exit 4 — hook files created above
    # (if any) already exist on disk, but settings.json was NOT written.
    _rsdd_print_wire_snippet "$_wo_stop" "$_wo_ss" "$_wo_skip_ss" "$target" "$_wo_pk"
    echo "== done =="
    exit 4
  fi
fi  # end wire-only

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
      .git|.gitignore|.claude|.atl|.engram) ;;   # kit issue #1903: the Engram config the scaffold itself writes is infra, never subject material
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
# corpus_present() is defined above (shared with the wire-only path).
if [ "$force" = 0 ]; then
  for cand in "$target" "$target/corpus"; do
    if corpus_present "$cand"; then
      echo "REFUSED: a corpus already exists at $cand (found a corpus marker)." >&2
      echo "         Not scaffolding — this would clobber or duplicate it. RESUME it, or use --force." >&2
      exit 3
    fi
  done
fi
# kit issue #1845: the same existing-hook rule as the wire-only path (a hand-adapted hook can exist without a corpus marker):
# --subject REFUSES (exit 3, nothing written), --prefix prints the note and the hook is left untouched, and a flagless
# run keeps it too (kit #1860). --force re-scaffolds it.
_rsdd_keep_hook=0
if [ "$force" = 0 ]; then
  _rsdd_refuse_fill_on_existing_hook "$target/.claude/hooks/research-protocol.sh"   # scaffold path
  # kit issue #1860: an existing hook is ALWAYS kept (flagless included), independent of which flags were given.
  [ -e "$target/.claude/hooks/research-protocol.sh" ] && _rsdd_keep_hook=1
fi

# --- pre-flight writability (fail BEFORE any mutation) -----------------------
# kit issue #1043 (2): refuse a dangling symlink at any path the scaffold writes BEFORE the first
# write (the ERR rollback would otherwise also delete the user's link).
_rsdd_scaffold_paths=("$corpus/INDEX.md" "$corpus/RESEARCH-STATE.md" "$corpus/sources" "$corpus/sources/SOURCES.md"
  "$target/.claude" "$target/.claude/hooks" "$target/.claude/hooks/research-protocol.sh"
  "$target/.claude/hooks/retro-gate-stop.sh" "$target/.claude/hooks/pkill-guard.sh" "$target/retros" "$target/tools" "$target/tools/README.md")
_rsdd_scaffold_paths+=("$target/.engram" "$target/.engram/config.json")   # kit issue #1903: the Engram config the scaffold writes
# settings.json is written only with --wire (kit issue #1043 item 4), so only then is it a precondition.
[ "$wire" = 1 ] && _rsdd_scaffold_paths+=("$target/.claude/settings.json")
_rsdd_dangling_symlinks "${_rsdd_scaffold_paths[@]}" || exit 2
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
# kit issue #1114: --document swaps in the OUTLINE-driven RESEARCH-STATE variant (METHODOLOGY §20);
# omitted (the default), the scaffold is byte-identical to before this flag existed.
_state_tpl="$TPL/RESEARCH-STATE.template.md"
[ "$document" = 1 ] && _state_tpl="$TPL/RESEARCH-STATE-document.template.md"
cpf "$_state_tpl"                     "$corpus/RESEARCH-STATE.md"
cpf "$TPL/SOURCES.template.md"        "$corpus/sources/SOURCES.md"
if [ "$_rsdd_keep_hook" = 0 ]; then
cpf "$TPL/hook-sessionstart.sh"       "$target/.claude/hooks/research-protocol.sh"
_rsdd_fill_hook "$target/.claude/hooks/research-protocol.sh"   # kit issue #1845: fill --subject/--prefix; a failed fill is a typed FATAL and the ERR trap rolls the scaffold back
else
  echo "kept: $target/.claude/hooks/research-protocol.sh (existing hook, not overwritten — stale? re-run with --force)"
fi   # _rsdd_keep_hook
cpf "$TPL/tools-README.template.md"   "$target/tools/README.md"
# kit issue #1903: make the target Engram-writable. Engram reads <target>/.engram/config.json (project_name); without it
# mem_save(project=<new>) fails unknown_project. Create-only: an existing config is never touched. The name is the directory name
# lowercased, every run of non-alphanumerics collapsed to one `-` (edit the file to use the TARGETS.md/registry name instead).
_eng_cfg="$target/.engram/config.json"; _eng_state=""; _eng_name=""
if [ -e "$_eng_cfg" ] || [ -L "$_eng_cfg" ]; then
  _eng_state="kept"
else
  _eng_name="$(basename "$(cd -P "$target" && pwd -P)" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')"
  if [ -z "$_eng_name" ]; then
    _eng_state="underivable"
  else
    mk "$target/.engram"
    printf '{\n  "project_name": "%s"\n}\n' "$_eng_name" > "$_eng_cfg"
    _eng_state="created"
  fi
fi
# §479 retro-gate Stop hook: copy template and replace <KIT>/<TARGET> placeholders
_rg_hook="$target/.claude/hooks/retro-gate-stop.sh"
cpf "$TPL/hook-stop-retro-gate.sh" "$_rg_hook"
_rsdd_render_hook "$_rg_hook"
chmod +x "$_rg_hook"
# kit issue #1496: pkill-guard PreToolUse hook (no placeholders to render)
_pk_hook="$target/.claude/hooks/pkill-guard.sh"
cpf "$TPL/hook-pretool-pkill-guard.sh" "$_pk_hook"
chmod +x "$_pk_hook"

# .gitignore guard (METHODOLOGY §15; the .research-sdd/plan/ line is added by _rsdd_gitignore_plan in the report below, kit issue #1804). Ensure a trailing newline first so we never fuse
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
         "$target/.claude/hooks/research-protocol.sh" "$target/.claude/hooks/retro-gate-stop.sh" "$target/.claude/hooks/pkill-guard.sh" \
         "$target/tools/README.md"; do
  [ -f "$f" ] || { echo "FATAL: expected artifact missing after scaffold: $f" >&2; exit 1; }
done
trap - ERR   # scaffold verified — disarm rollback

# --- seed the research-state.v1 envelope from ground truth --------------------
# The copied template ships a placeholder envelope; re-seed it so a FRESH corpus starts CONTRACT-VALID
# (covered_blocks/investigable_open/blocked_open matching the seeded backlog), i.e. verify-state.sh passes
# and --next never opens on a STALE gate. Best-effort: if the seeder is unavailable (e.g. a copied-toolbelt
# test tree without status.sh), the placeholder envelope still stands — never fail the scaffold over it.
SELF_DIR="$_RSDD_TB"
if [ -x "$SELF_DIR/research-sdd-status.sh" ] || [ -f "$SELF_DIR/research-sdd-status.sh" ]; then
  bash "$SELF_DIR/research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1 || echo "  note: could not seed the research-state.v1 envelope (run --sync-state manually)"
fi

# --- report ------------------------------------------------------------------
rel="${corpus#"$target"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="(target root, flat)"
echo "== research-sdd-init: scaffolded =="
echo "  target : $target"
echo "  corpus : ${rel}"
echo "  created: INDEX.md · RESEARCH-STATE.md · sources/SOURCES.md · hook · pkill-guard hook · retros/ · tools/README.md · .gitignore"
_rsdd_gitignore_plan
case "$_eng_state" in
  created)     echo "  engram : created: $_eng_cfg (project_name=$_eng_name)";;
  kept)        echo "  engram : kept: $_eng_cfg (existing config, not overwritten)";;
  underivable) echo "WARN: engram: could not derive a project_name from the directory name of $target — write $_eng_cfg by hand ({\"project_name\": \"<name>\"}); mem_save(project=<new>) fails unknown_project without it" >&2;;
esac
echo "  catalog: CATALOG.md is regenerated by research-sdd-archive.sh via the KIT generator (no per-target copy — eje #2)"
if [ "$document" = 1 ]; then
  echo "  mode   : document-cycle scaffold (--document, kit issue #1114) — RESEARCH-STATE.md seeded from the OUTLINE-driven variant (METHODOLOGY §20), not the gap-discovery one"
fi
if [ "$git_did_init" = 1 ]; then
  echo "  git    : initialized a new repo in the target"
else
  echo "  git    : target is ALREADY under git — corpus files land untracked (git add as needed)"
  echo "           the .claude/ hook is gitignored (.claude/ is in .gitignore) — git add --force to track it, or leave it ignored"
fi
echo "  remote : no remote — run $KIT/toolbelt/ensure-remote.sh $target --yes when you consent to push (PRIVATE, consent-gated)"
echo
echo "-- JUDGMENT follow-ups (NOT mechanizable) --"
echo "-- CONFIRM these are done — they belong at PROMPT-LOOP §b/§b2, BEFORE this scaffold (do them NOW if skipped) --"
echo "  1. REGISTER the target row in $KIT/TARGETS.md (name·path·maturity·artifact·wrapper·language) (PROMPT-LOOP §b)"
echo "     — else sweep-retros.sh cannot see its retros/ (§18)."
echo "  2. CLASSIFY the artifact + declare the ANGLE (PROMPT-LOOP §b/§b2); run profile-target.sh + detect-tools.sh."
echo "-- THEN do next (post-scaffold) --"
if [ "$document" = 1 ]; then
  echo "  3. SEED THE OUTLINE into $corpus/RESEARCH-STATE.md's \"## Outline\" section (PROMPT-LOOP DOCUMENT CYCLE step 1, METHODOLOGY §20) — NOT the Gap-backlog, which stays empty in document mode (kit issue #1114)."
else
  echo "  3. SEED 5-15 real gaps into $corpus/RESEARCH-STATE.md (audit-first for a mature corpus) (§e)."
fi
echo "  4. ADAPT + REGISTER the hook (§c follow-up): replace <SUBJECT> + real source paths in"
echo "     $target/.claude/hooks/research-protocol.sh (matcher startup|resume|clear)."
echo "     (--subject \"<phrase>\" / --prefix <slug> fill <SUBJECT> / <prefix> when the hook is created; the <path to ...> primary-sources placeholder is always edited by hand.)"
echo "     Then wire it: re-run with --wire, or paste the wiring snippet below into $target/.claude/settings.json."
[ "$rel" != "(target root, flat)" ] && echo "     For this NESTED corpus, PREFIX the hook's block/INDEX/CATALOG paths with corpus/."
if [ -n "$prefix" ]; then
  echo "  5. Block files use the prefix: ${prefix}-blockN.md"
else
  echo "  (no --prefix given — step 5, block-file prefix, is skipped; pass --prefix to enable it)"
fi
echo "  6. ENGRAM (agent step — init cannot call MCP): call mem_session_start(directory=$(cd -P "$target" && pwd -P)) before the first §20 mirror (mem_save) — the config above makes the project known, the session registers it; skipping it fails mem_save(project=<new>) with unknown_project."
echo
if [ "$document" = 1 ]; then
  echo "NEXT: run $KIT/toolbelt/research-sdd-status.sh $target — its next-step/saturation verdicts are GAP-CENTRIC and NOT meaningful for this document-cycle corpus (kit issue #1152 tracks teaching status to honor method: document-cycle); the \"## Outline\" table in RESEARCH-STATE.md is this mode's real completion signal (PROMPT-LOOP DOCUMENT CYCLE step 7)."
else
  echo "NEXT: run $KIT/toolbelt/research-sdd-status.sh $target — it reports BOOTSTRAP until the follow-ups above are done."
fi
echo "  mental model: you now have a VALID-but-EMPTY corpus; the JUDGMENT follow-ups turn it into a real research target."
echo
# §479 HOOK WIRING — PROPOSE-NEVER-APPLY by default (print snippet); --wire opts in to write.
# Default: always print the JSON block for the operator to paste. --wire writes settings.json.
# --no-wire is a backward-compat alias for the default (print-only, no write).
_stop_cmd="$target/.claude/hooks/retro-gate-stop.sh"
_ss_cmd="$target/.claude/hooks/research-protocol.sh"
_pk_cmd="$target/.claude/hooks/pkill-guard.sh"
# $CLAUDE_PROJECT_DIR-relative forms the shared merge also recognises (kit issue #1509: named once).
_stop_rel=".claude/hooks/retro-gate-stop.sh"
_ss_rel=".claude/hooks/research-protocol.sh"
_pk_rel=".claude/hooks/pkill-guard.sh"
_settings="$target/.claude/settings.json"
_wire_result="skip"

if [ "$wire" = 1 ]; then
  # §7 anti-silent-zero: probe for jq before any write; never silently fail or half-write
  if ! command -v jq >/dev/null 2>&1; then
    echo "degraded: jq not found on PATH — cannot wire settings.json; falling back to print" >&2
    _wire_result="degraded"
  else
    # kit issue #1047: never wire an unadapted SessionStart hook on the scaffold+wire path either
    # — a freshly-copied hook-sessionstart.sh always carries a LIVE (non-comment) <SUBJECT>
    # placeholder (see the template body), so scaffold+wire in one call (--scaffold --wire) must
    # skip SessionStart exactly like the wire-only repair path does (kit issue #959/#1038/#1040).
    _wire_skip_ss="false"
    if _rsdd_has_live_subject_placeholder "$_ss_cmd"; then
      _wire_skip_ss="true"
      echo "WARN: $_ss_cmd still contains the <SUBJECT> placeholder — skipping SessionStart wiring until you adapt it (replace <SUBJECT> and the source paths, PROMPT-LOOP §c follow-up). Re-run with --wire once adapted." >&2
    fi
    _rsdd_warn_other_placeholders "$_ss_cmd"   # kit issue #1845: every other live placeholder, named; none blocks SessionStart

    # Read existing settings or start from empty object; never corrupt if file is invalid JSON
    _wire_base='{}'
    if [ -f "$_settings" ]; then
      _wire_base="$(cat "$_settings")"
    fi
    _tmp_settings="$(mktemp)"
    # Idempotent merge via the SAME shared predicate as the wire-only path (kit issue #1496): Stop,
    # SessionStart and PreToolUse are each added only if no equivalent registration form is present.
    # kit issue #1509: keep the merge's {settings, has_*} output (it used to be piped straight into
    # `jq .settings`, discarding the has-* flags) so each hook's registered/already-wired state is reported.
    # The merge sits INSIDE the if-guard (as in the wire-only path): under `set -e` an unguarded
    # failing assignment would abort with jq's raw exit code (5) and no typed message (kit issue #1509).
    if _wire_merge_out="$(printf '%s' "$_wire_base" | _rsdd_merge_settings "$_stop_cmd" "$_ss_cmd" "$_pk_cmd" \
        "$_stop_rel" "$_ss_rel" "$_pk_rel" "$_wire_skip_ss" "$_RSDD_GATE_CMD" 2>/dev/null)" \
        && [ -n "$_wire_merge_out" ] && jq '.settings' <<<"$_wire_merge_out" > "$_tmp_settings" 2>/dev/null \
        && [ "$(jq -r 'type' "$_tmp_settings" 2>/dev/null)" = "object" ]; then
      _rsdd_install_settings "$_tmp_settings" "$_settings" || { echo "FATAL: could not write $_settings" >&2; exit 4; }
      _wire_drift_out="$(_rsdd_wire_drift "$_settings")" || :   # advisory: a typed WARN line is in the output, the core wire carries on
      _wire_has_stop="$(jq -r '.has_stop' <<<"$_wire_merge_out")"
      _wire_has_ss="$(jq -r '.has_ss' <<<"$_wire_merge_out")"
      _wire_has_pk="$(jq -r '.has_pk' <<<"$_wire_merge_out")"
      _rsdd_report_gate "$_wire_merge_out" "$_settings"
      printf '%s\n' "$_wire_drift_out"
      if [ "$_wire_has_pk" = "true" ]; then
        echo "  wired  : PreToolUse pkill-guard hook already wired in $_settings"
      else
        echo "  wired  : PreToolUse pkill-guard hook registered in $_settings"
      fi
      if [ "$_wire_has_stop" = "true" ]; then
        echo "  wired  : Stop hook already wired in $_settings"
      else
        echo "  wired  : Stop hook registered in $_settings"
      fi
      if [ "$_wire_skip_ss" = "true" ]; then
        if [ "$_wire_has_ss" = "true" ]; then
          echo "  wired  : SessionStart hook already wired in $_settings (left as-is — <SUBJECT> placeholder is live, so the existing entry was not touched or re-added)"
        else
          echo "  skipped: SessionStart hook NOT registered (unadapted <SUBJECT> placeholder — see WARN above)"
        fi
      elif [ "$_wire_has_ss" = "true" ]; then
        echo "  wired  : SessionStart hook already wired in $_settings"
      else
        echo "  wired  : SessionStart hook registered in $_settings"
      fi
      _wire_result="wired"
    else
      rm -f "$_tmp_settings"
      # Same contract as the wire-only path: typed message, snippet to paste, exit 4 (a failed
      # merge must never read as success; the scaffold itself already completed, settings.json is untouched).
      echo "degraded: jq failed on $_settings — refusing to report success (settings.json untouched; paste the snippet below, or fix the file and re-run with --wire)" >&2
      _wire_result="degraded"
      _wire_merge_failed=1
    fi
  fi
fi

# Print the wiring snippet when: default (wire=0) OR --wire degraded fallback (jq absent/failed)
if [ "$wire" = 0 ] || [ "$_wire_result" = "degraded" ]; then
  echo "-- §479 HOOK WIRING (propose-never-apply: paste this yourself, or re-run with --wire) --"
  echo "   Add to $target/.claude/settings.json — merge with any existing hooks:"
  _rsdd_print_wire_block "$_stop_cmd" "$_ss_cmd" "false" "$_pk_cmd"
fi

_rsdd_vendor_leak_wiring

echo "== done =="
# kit issue #1509: a failed settings.json merge on the scaffold --wire path exits 4 (see header).
if [ "${_wire_merge_failed:-0}" = 1 ]; then exit 4; fi
