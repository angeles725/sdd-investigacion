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
# Usage: research-sdd-init.sh <target-dir> [--corpus auto|nested|flat] [--prefix <slug>] [--force]
#        [--wire] [--no-wire] [--scaffold] [--document]
# Exit: 0 = scaffolded · 2 = bad args/target/not-writable · 3 = corpus already exists (refused) ·
#       4 = wire-only: existing .claude/settings.json is non-empty but not a JSON object with a
#           valid .hooks shape, OR the settings.json merge itself failed (refused/aborted,
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
# DOCUMENT-CYCLE SCAFFOLD VARIANT (kit issue #1114): --document swaps the RESEARCH-STATE.md source
# template from RESEARCH-STATE.template.md (gap-discovery / NORMAL CYCLE) to
# RESEARCH-STATE-document.template.md (OUTLINE-driven / DOCUMENT CYCLE, METHODOLOGY §20). The
# generic template seeds discovery-style Gap-backlog placeholder rows a document-cycle run never
# discovers or closes — PROMPT-LOOP's DOCUMENT CYCLE preflight passes --document precisely to avoid
# that mismatch. The flag affects ONLY which RESEARCH-STATE.md source is copied during a full
# scaffold; it has no effect on the wire-only-repair path (which never touches RESEARCH-STATE.md) and
# no effect when omitted (the default scaffold is unchanged).
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
KIT="$(cd -P "$(dirname "$0")/.." && pwd -P)"     # .../research-sdd
TPL="$KIT/templates"

# Shared corpus-marker predicate (kit issue #1108): single source of truth with
# verify-registry.sh's registered-path marker check — see lib/corpus-markers.sh for why.
_ri_cm_lib="$(cd "$(dirname "$0")" && pwd)/lib/corpus-markers.sh"
if [ ! -f "$_ri_cm_lib" ]; then echo "research-sdd-init: cannot find helper $_ri_cm_lib" >&2; exit 1; fi
# shellcheck source=lib/corpus-markers.sh
. "$_ri_cm_lib"
declare -F corpus_has_marker >/dev/null 2>&1 || { echo "research-sdd-init: helper $_ri_cm_lib failed to define corpus_has_marker" >&2; exit 1; }
unset _ri_cm_lib

target=""; corpus_mode="auto"; prefix=""; force=0; wire=0; scaffold=0; document=0
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus)   corpus_mode="${2:-auto}"; shift 2;;
    --prefix)   prefix="${2:-}"; shift 2;;
    --force)    force=1; shift;;
    --wire)     wire=1; shift;;
    --no-wire)  wire=0; shift;;   # backward-compat: same as default (print-only)
    --scaffold) scaffold=1; shift;;   # kit issue #1047: explicit opt-in to scaffold+wire in one call
    --document) document=1; shift;;   # kit issue #1114: seed the DOCUMENT CYCLE (outline-driven) RESEARCH-STATE variant
    -*)         echo "unknown flag: $1" >&2; exit 2;;
    *)          target="$1"; shift;;
  esac
done
[ -n "$target" ] && [ -d "$target" ] || { echo "usage: research-sdd-init.sh <target-dir> [--corpus auto|nested|flat] [--prefix <slug>] [--force] [--wire] [--no-wire] [--scaffold] [--document]" >&2; exit 2; }
# kit issue #1047: --scaffold has no effect on its own — it only opts a marker-less target INTO
# scaffolding when paired with --wire. Reject rather than silently ignore, so a typo (or a
# --wire dropped by mistake) fails loudly instead of behaving as a no-op default scaffold run.
[ "$scaffold" = 1 ] && [ "$wire" = 0 ] && { echo "usage: --scaffold requires --wire (it only opts a marker-less target into scaffold+wire; pass --scaffold --wire, or drop --scaffold for the ordinary print-only scaffold)" >&2; exit 2; }
target="$(cd "$target" && pwd)"

# templates must exist or we fail CLEANLY (never a half-scaffold)
for t in INDEX.template.md RESEARCH-STATE.template.md SOURCES.template.md hook-sessionstart.sh hook-stop-retro-gate.sh tools-README.template.md; do
  [ -f "$TPL/$t" ] || { echo "FATAL: missing kit template $TPL/$t" >&2; exit 2; }
done
# kit issue #1114 review RDD-SUGGESTION: RESEARCH-STATE-document.template.md is required ONLY when
# --document is actually going to be used — a target missing it must not break the (far more common)
# default scaffold path.
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

# kit issue #1040 finding 3 (round 2 of #1038): detect <SUBJECT> only in NON-COMMENT lines. The
# shipped template's own header comments legitimately contain the literal token, and a real
# adaptation that leaves those comments untouched (api-paneles repro) must not be misread as
# unadapted — that silently blocks SessionStart forever.
_rsdd_has_live_subject_placeholder() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -vE '^[[:space:]]*#' "$f" 2>/dev/null | grep -qF '<SUBJECT>'
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

# kit issue #1040 finding 2 (round 2 of #1038): the print-only fallback — jq absent, or jq
# processing failure — must honor the SAME #959 guard as the live-write path: never offer a
# SessionStart line to paste while research-protocol.sh still carries a live <SUBJECT>.
_rsdd_print_wire_snippet() {
  local stop_cmd="$1" ss_cmd="$2" skip_ss="$3" tgt="$4"
  echo "-- §479 HOOK WIRING snippet (paste into $tgt/.claude/settings.json) --"
  if [ "$skip_ss" = "true" ]; then
    printf '%s\n' '{' \
      '  "hooks": {' \
      '    "Stop": [' \
      "      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$stop_cmd\"}]}" \
      '    ]' \
      '  }' \
      '}'
    echo "-- SessionStart omitted: $ss_cmd still has the <SUBJECT> placeholder (adapt it first, PROMPT-LOOP §c follow-up) --"
  else
    printf '%s\n' '{' \
      '  "hooks": {' \
      '    "Stop": [' \
      "      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$stop_cmd\"}]}" \
      '    ],' \
      '    "SessionStart": [' \
      "      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$ss_cmd\"}]}" \
      '    ]' \
      '  }' \
      '}'
  fi
}

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

# kit issue #1114 review LOW-2 (following the #1047 no-silent-no-op precedent): --document has NO
# EFFECT on the wire-only-repair path below — --wire on an EXISTING corpus without --force only
# REPAIRS hooks/settings.json and never touches RESEARCH-STATE.md. Reject rather than silently
# ignore the flag, exactly as --scaffold-without-wire is rejected above.
if [ "$wire" = 1 ] && [ "$force" = 0 ] && [ -n "$_wo_corpus_root" ] && [ "$document" = 1 ]; then
  echo "usage: --document has no effect here — --wire on an existing corpus (without --force) only REPAIRS hooks/settings.json and never touches RESEARCH-STATE.md (kit issue #1114). Drop --document, pass --force to re-scaffold RESEARCH-STATE.md with the document-cycle variant, or run --document against a NEW target instead." >&2
  exit 2
fi

# WIRE-ONLY-EXISTING-CORPUS
if [ "$wire" = 1 ] && [ "$force" = 0 ]; then
  if [ -n "$_wo_corpus_root" ]; then
    # Wire-only: compute paths; NEVER touch any corpus file.
    _wo_stop="$target/.claude/hooks/retro-gate-stop.sh"
    _wo_ss="$target/.claude/hooks/research-protocol.sh"
    _wo_stop_rel=".claude/hooks/retro-gate-stop.sh"
    _wo_ss_rel=".claude/hooks/research-protocol.sh"
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
      elif _rsdd_has_live_subject_placeholder "$_wo_ss"; then
        _wo_pre_skip_ss="true"
        echo "WARN: $_wo_ss still contains the <SUBJECT> placeholder — the snippet below omits SessionStart until you adapt it (PROMPT-LOOP §c follow-up)." >&2
      fi
      _rsdd_print_wire_snippet "$_wo_stop" "$_wo_ss" "$_wo_pre_skip_ss" "$target"
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

    # jq is present and settings.json (if any) is valid JSON: repair absent hook files
    # (create-only — never overwrite an existing one).
    mkdir -p "$target/.claude/hooks"
    if [ -e "$_wo_stop" ]; then
      echo "kept: $_wo_stop"
    else
      cp "$TPL/hook-stop-retro-gate.sh" "$_wo_stop"
      sed -i "s|<KIT>|$KIT|g; s|<TARGET>|$target|g" "$_wo_stop"
      chmod +x "$_wo_stop"
      echo "created: $_wo_stop"
    fi
    if [ -e "$_wo_ss" ]; then
      echo "kept: $_wo_ss"
    else
      cp "$TPL/hook-sessionstart.sh" "$_wo_ss"
      echo "created: $_wo_ss"
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

    # kit issue #1040 finding 1: recognise $CLAUDE_PROJECT_DIR-relative forms as the same hook.
    _wo_stop_variants="$(_rsdd_cmd_variants_json "$_wo_stop" "$_wo_stop_rel")"
    _wo_ss_variants="$(_rsdd_cmd_variants_json "$_wo_ss" "$_wo_ss_rel")"

    # -s (non-empty), not -f: a ZERO-BYTE existing file is treated as {} (see the pre-validation
    # comment above) — reading it with `cat` would otherwise feed jq an empty stdin, which is a
    # jq error (no input value), not an empty object.
    _wo_base='{}'; [ -s "$_wo_settings" ] && _wo_base="$(cat "$_wo_settings")"
    _wo_tmp="$(mktemp)"
    if _wo_merge_out="$(printf '%s' "$_wo_base" | jq --arg sc "$_wo_stop" --arg ac "$_wo_ss" \
        --argjson stop_variants "$_wo_stop_variants" --argjson ss_variants "$_wo_ss_variants" \
        --argjson skip_ss "$_wo_skip_ss" '
        ((.hooks.Stop // []) | map(.hooks // [] | map(.command)) | add // []) as $stop_cmds |
        ((.hooks.SessionStart // []) | map(.hooks // [] | map(.command)) | add // []) as $ss_cmds |
        ($stop_cmds | any(. as $c | ($stop_variants | index($c)) != null)) as $has_stop |
        ($ss_cmds | any(. as $c | ($ss_variants | index($c)) != null)) as $has_ss |
        (.hooks.Stop = (if $has_stop then (.hooks.Stop // [])
          else (.hooks.Stop // []) + [{"matcher":"","hooks":[{"type":"command","command":$sc}]}] end)) |
        (.hooks.SessionStart = (if $skip_ss or $has_ss then (.hooks.SessionStart // [])
          else (.hooks.SessionStart // []) + [{"matcher":"","hooks":[{"type":"command","command":$ac}]}] end)) |
        {settings: ., has_stop: $has_stop, has_ss: $has_ss}
      ' 2>/dev/null)" && [ -n "$_wo_merge_out" ]; then
      # kit issue #1040 round 3 finding 3: pretty-print (not `-c` compact) so a hand-maintained
      # settings.json keeps its indentation instead of collapsing to one line.
      jq '.settings' <<<"$_wo_merge_out" > "$_wo_tmp"
      mv "$_wo_tmp" "$_wo_settings"
      _wo_has_stop="$(jq -r '.has_stop' <<<"$_wo_merge_out")"
      _wo_has_ss="$(jq -r '.has_ss' <<<"$_wo_merge_out")"
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
    _rsdd_print_wire_snippet "$_wo_stop" "$_wo_ss" "$_wo_skip_ss" "$target"
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
# kit issue #1114: --document swaps in the OUTLINE-driven RESEARCH-STATE variant (METHODOLOGY §20);
# omitted (the default), the scaffold is byte-identical to before this flag existed.
_state_tpl="$TPL/RESEARCH-STATE.template.md"
[ "$document" = 1 ] && _state_tpl="$TPL/RESEARCH-STATE-document.template.md"
cpf "$_state_tpl"                     "$corpus/RESEARCH-STATE.md"
cpf "$TPL/SOURCES.template.md"        "$corpus/sources/SOURCES.md"
cpf "$TPL/hook-sessionstart.sh"       "$target/.claude/hooks/research-protocol.sh"
cpf "$TPL/tools-README.template.md"   "$target/tools/README.md"
# §479 retro-gate Stop hook: copy template and replace <KIT>/<TARGET> placeholders
_rg_hook="$target/.claude/hooks/retro-gate-stop.sh"
cpf "$TPL/hook-stop-retro-gate.sh" "$_rg_hook"
sed -i "s|<KIT>|$KIT|g; s|<TARGET>|$target|g" "$_rg_hook"
chmod +x "$_rg_hook"

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
         "$target/.claude/hooks/research-protocol.sh" "$target/.claude/hooks/retro-gate-stop.sh" \
         "$target/tools/README.md"; do
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
echo "     Then wire it: re-run with --wire, or paste the wiring snippet below into $target/.claude/settings.json."
[ "$rel" != "(target root, flat)" ] && echo "     For this NESTED corpus, PREFIX the hook's block/INDEX/CATALOG paths with corpus/."
if [ -n "$prefix" ]; then
  echo "  5. Block files use the prefix: ${prefix}-blockN.md"
else
  echo "  (no --prefix given — step 5, block-file prefix, is skipped; pass --prefix to enable it)"
fi
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

    # Read existing settings or start from empty object; never corrupt if file is invalid JSON
    _wire_base='{}'
    if [ -f "$_settings" ]; then
      _wire_base="$(cat "$_settings")"
    fi
    _tmp_settings="$(mktemp)"
    # Idempotent merge: add Stop + SessionStart entries only if the command is not already present
    if printf '%s' "$_wire_base" | jq --arg sc "$_stop_cmd" --arg ac "$_ss_cmd" --argjson skip_ss "$_wire_skip_ss" '
      ((.hooks.Stop // []) | map(.hooks // [] | map(.command)) | add // [] | contains([$sc])) as $has_stop |
      ((.hooks.SessionStart // []) | map(.hooks // [] | map(.command)) | add // [] | contains([$ac])) as $has_ss |
      .hooks.Stop = (if $has_stop then (.hooks.Stop // [])
        else (.hooks.Stop // []) + [{"matcher":"","hooks":[{"type":"command","command":$sc}]}] end) |
      .hooks.SessionStart = (if $skip_ss or $has_ss then (.hooks.SessionStart // [])
        else (.hooks.SessionStart // []) + [{"matcher":"","hooks":[{"type":"command","command":$ac}]}] end)
    ' > "$_tmp_settings" 2>/dev/null; then
      mv "$_tmp_settings" "$_settings"
      if [ "$_wire_skip_ss" = "true" ]; then
        echo "  wired  : Stop hook registered in $_settings (SessionStart skipped — see WARN above)"
      else
        echo "  wired  : hooks registered in $_settings"
      fi
      _wire_result="wired"
    else
      rm -f "$_tmp_settings"
      echo "degraded: jq failed to process $_settings — falling back to print" >&2
      _wire_result="degraded"
    fi
  fi
fi

# Print the wiring snippet when: default (wire=0) OR --wire degraded fallback (jq absent/failed)
if [ "$wire" = 0 ] || [ "$_wire_result" = "degraded" ]; then
  echo "-- §479 HOOK WIRING (propose-never-apply: paste this yourself, or re-run with --wire) --"
  echo "   Add to $target/.claude/settings.json — merge with any existing hooks:"
  printf '%s\n' '{' \
    '  "hooks": {' \
    '    "Stop": [' \
    '      {"matcher":"","hooks":[{"type":"command","command":"'"$_stop_cmd"'"}]}' \
    '    ],' \
    '    "SessionStart": [' \
    '      {"matcher":"","hooks":[{"type":"command","command":"'"$_ss_cmd"'"}]}' \
    '    ]' \
    '  }' \
    '}'
fi
echo "== done =="
