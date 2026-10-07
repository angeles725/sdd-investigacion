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
#   research-sdd-archive.sh <target-dir>                          gate + consolidate (regenerate CATALOG, touch INDEX) + checklist
#   research-sdd-archive.sh <target-dir> --dry-run                report what WOULD happen; mutate nothing
#   research-sdd-archive.sh <target-dir> --focus <name>           scope UF gate to a single focus (RESEARCH-STATE-<name>.md)
#   research-sdd-archive.sh <target-dir> --focus <name> --dry-run scoped dry-run
#   research-sdd-archive.sh <target-dir> --allow-unreciprocated-corrections
#                                                                 override the §14 reciprocity gate (see below)
# Exit: 0 = archived (or dry-run); the GATE is the archive decision — consolidate steps are BEST-EFFORT and a
#           failure there is reported LOUDLY (stderr + checklist) but keeps exit 0, so callers gate on 0/2/3.
#       2 = bad args / no RESEARCH-STATE (nothing to archive) / unknown --focus slug.
#       3 = REFUSED: a consistency gate (verify-state / verify-sources / verify-corrections / scan-secrets / undocumented_findings / MISSING-RETRO) did not pass — reconcile first.
# §14 reciprocity gate (verify-corrections.sh, issue #1790 step 4; was an advisory WARN under #1787). Verdict lines:
#   ok                  every declared correction is reciprocated (or none declared)
#   n/a                 no block files (nothing to check)
#   PARTIAL — N ...     linter said ok-partial: N declared corrections had an ambiguous/missing target and were NOT
#                       checked (K of them typed `AMBIG` lines: object/locator/assumption/cross-focus/bare, #1868).
#                       Passes (an unverifiable claim is not a one-directional one), but is typed + WARNed on stderr,
#                       never a bare ok.
#   FAIL — N ...        one-directional correction(s); REFUSES (exit 3), the failing pairs are listed.
#   DEGRADED — ...      the linter said it could not look (`degraded:`); REFUSES — an unreadable instrument is not a pass.
#   ERROR — ...         bad args / missing / non-executable / unexpected exit / exit 0 without an `ok` verdict line /
#                       exit 1 with no findings and no `degraded:` (could not run?) / --focus prefix unresolvable; REFUSES.
#   SIBLING — N pair(s) outside focus <slug> not enforced   (--focus only) the failing pairs all belong to sibling
#                       focuses; typed + stderr WARN, does NOT refuse (same scoping rule as verify-state, #647).
# Under --focus a failing pair refuses only when its TARGET block carries the focus's prefix (derive_focus_prefix of the
# focus state file, lib/focus-prefix.sh) or the focus owns a block with the correcting block's number (conservative:
# the linter's FAIL line names the correcting block by number only). No block file carries the focus prefix => ERROR.
# --allow-unreciprocated-corrections turns a FAIL / DEGRADED / ERROR refusal for THIS gate into a typed
# `OVERRIDDEN — ...` line (and a stderr WARN) and lets the close proceed; it never affects any other gate.
set -uo pipefail

target=""; dry=0; focus_slug=""; allow_vc=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift;;
    --allow-unreciprocated-corrections) allow_vc=1; shift;;  # AR-VCORR-OVERRIDE-FLAG
    --focus)
      focus_slug="${2:-}"
      [ -n "$focus_slug" ] || { echo "research-sdd-archive: --focus requires a focus name" >&2; exit 2; }
      shift 2;;
    -*) echo "research-sdd-archive: unknown flag: $1" >&2; exit 2;;
    *)  [ -z "$target" ] && target="$1" || { echo "research-sdd-archive: unexpected extra arg: $1" >&2; exit 2; }; shift;;
  esac
done
[ -n "$target" ] && [ -d "$target" ] || { echo "usage: research-sdd-archive.sh <target-dir> [--focus <name>] [--dry-run] [--allow-unreciprocated-corrections]" >&2; exit 2; }
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

# Shared focus -> block-prefix derivation (single source of truth with verify-state / status) — used to scope the
# §14 reciprocity gate under --focus. Fail-closed like the other helpers.
_fplib="$here/lib/focus-prefix.sh"
if [ ! -f "$_fplib" ]; then echo "research-sdd-archive: cannot find helper $_fplib" >&2; exit 1; fi
# shellcheck source=lib/focus-prefix.sh
. "$_fplib"
declare -F derive_focus_prefix >/dev/null 2>&1 \
  || { echo "research-sdd-archive: helper $_fplib failed to define derive_focus_prefix" >&2; exit 1; }
unset _fplib

# Resolve the state file via the shared lib/state-files.sh resolver (kit issue #1818): shallowest wins, and
# the root RESEARCH-STATE.md beats every RESEARCH-STATE-<focus>.md at that depth (a lexical `sort | head -1`
# picked a focus file first). Typed outcomes: 1 absent · 2 tie across directories (split layout) · 3 unusable input.
declare -F resolve_state_file >/dev/null 2>&1 \
  || { echo "research-sdd-archive: helper lib/state-files.sh failed to define resolve_state_file" >&2; exit 1; }
# T-AR1: when --focus <slug> was given, select the focus-specific state file.
# Exit 2 when the requested focus does not exist under $target.
if [ -n "$focus_slug" ]; then
  state="$(resolve_state_file "$target" --focus "$focus_slug")"; _rsf_rc=$?
  if [ "$_rsf_rc" = 1 ]; then
    if [ -z "$(list_state_files "$target")" ]; then
      echo "research-sdd-archive: no RESEARCH-STATE*.md under $target — nothing to archive (run research-sdd-init.sh)" >&2; exit 2
    fi
    echo "research-sdd-archive: focus '$focus_slug' not found under $target (no RESEARCH-STATE-${focus_slug}.md)" >&2; exit 2
  fi
else
  state="$(resolve_state_file "$target")"; _rsf_rc=$?
  [ "$_rsf_rc" != 1 ] \
    || { echo "research-sdd-archive: no RESEARCH-STATE*.md under $target — nothing to archive (run research-sdd-init.sh)" >&2; exit 2; }
fi

# rc 2 (equal-rank candidates in different directories) is the legitimate SPLIT layout — one corpus dir per
# focus; the resolver's deterministic first pick is the corpus and the UF gate scopes to $target (below).
# Any other non-zero status (3 = unusable input) is a loud refusal, never a silent pick.
{ [ "$_rsf_rc" = 0 ] || [ "$_rsf_rc" = 2 ]; } && [ -n "$state" ] && [ -f "$state" ] \
  || { echo "research-sdd-archive: cannot resolve a RESEARCH-STATE file under $target (resolver status $_rsf_rc)" >&2; exit 2; }
corpus="$(dirname "$state")"
rel="${corpus#"$target"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="(flat)"

echo "== research-sdd-archive: $(basename "$target")  ·  corpus: $rel$([ "$dry" = 1 ] && echo '  ·  DRY-RUN') =="

# Helper used by both the MISSING-RETRO gate and the ONE-BLOCK-PER-COMMIT detector.
rsdd_added_epoch() {  # <repo-dir> <file> → git first-commit(added, under CURRENT path — no --follow,
  # same rename tradeoff as sweep-retros.sh) epoch if tracked, else file mtime, else 0
  local d="$1" f="$2" e
  e="$(git -C "$d" log --no-renames --diff-filter=A --format=%ct -1 -- "$f" 2>/dev/null)"
  [ -n "$e" ] || e="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  printf '%s' "$e"
}

# --- GATE: never archive an inconsistent corpus (this is the load-bearing part) --------------------
# Delegate to the sibling linters via gate(). verify-state catches the stale-mirror / premature-STOP
# desync; verify-sources catches a broken source registry. Either non-zero blocks the close
# (fail-closed). A linter that exits >1 (missing / not executable / bad args) is reported DISTINCTLY
# from a real content FAIL so a broken toolchain is not mistaken for a stale mirror. The scan-secrets
# gate (below, after verify-sources) does NOT go through gate(): it scans a list of every regular
# file under the physical target (via `scan-secrets.sh --files-from`, #1015 — never the
# default-mode block-dir narrowing) and, for a git-backed repo-root target, ALSO the committed history
# (issue #970), with git-state branching gate()'s single-target-arg shape does not cover — so it is
# special-cased inline instead.
gate_rc=0
gate() {  # <label> <sibling-script> <content-fail-message> [extra-args...]
  local rc _label="$1" _script="$2" _msg="$3"; shift 3
  "$here/$_script" "$corpus" "$@" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) echo "    $_label : ok";;
    1) echo "    $_label : FAIL — $_msg"; gate_rc=1;;
    *) echo "    $_label : ERROR — $_script did not run (exit $rc) — check it exists and is executable"; gate_rc=1;;
  esac
}
echo "  -- gates --"
# AR2-VSTATE-FOCUS-SCOPE: when --focus is given, scope verify-state to that focus so a stale sibling
# focus does not block a clean focus from archiving (issue #647). verify-state already supports --focus.
_vstate_args=()
[ -n "$focus_slug" ] && _vstate_args=("--focus" "$focus_slug")  # AR2-VSTATE-FOCUS-SCOPE
gate "verify-state  " verify-state.sh   "living mirror inconsistent (stale summary / premature STOP)" "${_vstate_args[@]}"
gate "verify-sources" verify-sources.sh "source registry incomplete (preserved-source markers without a registry, a cited file missing, a fabricated registry citation, or an unregistered web-snapshot)"
# --- GATE: §14 one-directional corrections (verify-corrections.sh; advisory under #1787, gate under #1790) ----
# Exit 0 = ok (or ok-partial -> PARTIAL), 1 = findings (FAIL) or the linter's own `degraded:` (DEGRADED), 2 = no
# block files (n/a) or bad args (ERROR; told apart by the stderr reason), anything else = did not run (ERROR).
# FAIL/DEGRADED/ERROR set gate_rc=1 unless --allow-unreciprocated-corrections (then a typed OVERRIDDEN line).
# Why a gate (#1790): a §14 correction with no reciprocal backlink leaves the corrected block asserting the old
# claim to every later reader. The advisory WARN was ignored, so archive now refuses until the backlink exists or
# the operator overrides explicitly. Measured before promotion (2026-10-05, after #1835's false-FAIL fixes): 6 of
# 20 present targets would be refused; each refusal names its pairs, the verify command and the override flag.
_vc_out="$("$here/verify-corrections.sh" "$corpus" 2>&1)"; _vc_rc=$?  # AR-VCORR-GATE
_vc_pfx() { basename "$1" | sed -E 's/^(.*)-(block|bloque)0*[0-9]+.*/\1/'; }  # block filename -> focus prefix (BASENAME only, #1857)
_vc_refuse() {  # <state-label> <detail> — refuse, or (override flag) record a typed OVERRIDDEN line
  if [ "$allow_vc" = 1 ]; then  # AR-VCORR-OVERRIDE
    echo "    verify-corrections : OVERRIDDEN — $2 (--allow-unreciprocated-corrections given; gate NOT enforced)"
    echo "WARN: verify-corrections gate overridden by --allow-unreciprocated-corrections — $2." >&2
  else
    echo "    verify-corrections : $1 — $2 (override: --allow-unreciprocated-corrections)"
    gate_rc=1  # vcorr-gate-refuse
  fi
}
case "$_vc_rc" in
  0) if grep -q '^ *ok-partial ' <<<"$_vc_out"; then  # AR-VCORR-PARTIAL
       _vc_u="$(sed -n 's/^ *ok-partial \([0-9][0-9]*\) .*/\1/p' <<<"$_vc_out" | head -n 1)"
       _vc_amb="$(grep -c '^ *AMBIG ' <<<"$_vc_out")"  # AR-VCORR-AMBIG-COUNT (typed ambiguous lines, #1868; never a refusal)
       echo "    verify-corrections : PARTIAL — ${_vc_u:-some} declared correction(s) NOT checked (${_vc_amb:-0} typed ambiguous, rest ambiguous/missing target; run verify-corrections.sh for the AMBIG/WARN lines)"
       echo "WARN: verify-corrections ok-partial — ${_vc_u:-some} declared correction(s) could not be checked." >&2
     elif grep -q '^ *ok ' <<<"$_vc_out"; then  # AR-VCORR-OK-POSITIVE
       echo "    verify-corrections : ok"
     else
       _vc_refuse ERROR "verify-corrections.sh exited 0 without an 'ok' verdict line (contract drift — the check may not have run)"
     fi;;
  # Output contract (verify-corrections.sh): one `   FAIL   B<n> corrects [Block <m>] but <file> has no reciprocal ...`
  # line per finding; an instrument that could not look says `degraded:` and exits 1 with NO FAIL lines.
  1) _vc_n="$(grep -c '^ *FAIL ' <<<"$_vc_out")"  # AR-VCORR-COUNT
     if grep -q 'degraded:' <<<"$_vc_out"; then  # AR-VCORR-DEGRADED
       _vc_refuse DEGRADED "verify-corrections.sh reported degraded: $(grep -m1 'degraded:' <<<"$_vc_out" | sed 's/^.*degraded: *//')"
     elif [ "$_vc_n" -gt 0 ]; then
       _vc_fails="$(grep '^ *FAIL ' <<<"$_vc_out")"
       _vc_infocus="$_vc_fails"; _vc_sib=0; _vc_scope_err=""
       if [ -n "$focus_slug" ]; then  # AR-VCORR-FOCUS-SCOPE
         _vc_fslug="$(derive_focus_prefix "$state")"; _vc_fslug="${_vc_fslug%-}"
         _vc_fcount=0
         while IFS= read -r _vc_f; do
           [ -n "$_vc_f" ] || continue
           [ "$(_vc_pfx "$_vc_f")" = "$_vc_fslug" ] || continue
           _vc_fcount=$((_vc_fcount+1))
         done < <(find "$corpus" -maxdepth 3 -type f -name '*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null | block_file_filter)
         if [ -z "$_vc_fslug" ] || [ "$_vc_fcount" -eq 0 ]; then
           _vc_scope_err="cannot scope the §14 gate to focus $focus_slug (no block file carries its prefix '${_vc_fslug:-?}-'); $_vc_n finding(s) NOT classified"  # AR-VCORR-FOCUS-UNRESOLVED
         else
           _vc_infocus=""
           while IFS= read -r _vc_l; do
             _vc_c="$(sed -nE 's/^ *FAIL +B0*([0-9]+) corrects.*/\1/p' <<<"$_vc_l")"
             _vc_t="$(sed -nE 's/^.* but ([^ ]+) has no reciprocal.*/\1/p' <<<"$_vc_l")"
             _vc_tp="$(_vc_pfx "$_vc_t")"
             # The correcting block's OWN file (`[correcting: <file>]`, #1857) decides ownership by prefix: a focus that merely
             # owns another block with the same NUMBER does not own this pair. Unparseable line (or a linter that does not
             # name the correcting file) => treated as in-focus (never silently dropped).
             _vc_cf="$(sed -nE 's/^.*\[correcting: ([^]]+)\] *$/\1/p' <<<"$_vc_l")"
             _vc_cp=""; [ -z "$_vc_cf" ] || _vc_cp="$(_vc_pfx "$_vc_cf")"
             if [ -z "$_vc_c" ] || [ -z "$_vc_t" ] || [ -z "$_vc_cf" ] || [ "$_vc_tp" = "$_vc_fslug" ] || [ "$_vc_cp" = "$_vc_fslug" ]; then  # AR-VCORR-IN-FOCUS
               _vc_infocus="${_vc_infocus:+$_vc_infocus$'\n'}$_vc_l"
             else _vc_sib=$((_vc_sib+1)); fi
           done <<<"$_vc_fails"
         fi
       fi
       if [ -n "$_vc_scope_err" ]; then
         _vc_refuse ERROR "$_vc_scope_err"
       else
         if [ -n "$_vc_infocus" ]; then
           _vc_nf="$(grep -c '' <<<"$_vc_infocus")"
           _vc_refuse FAIL "$_vc_nf one-directional §14 correction(s) — add the reciprocal 'corrected in BN' note to the corrected block(s)"
           sed 's/^ */      /' <<<"$_vc_infocus"
         fi
         if [ "$_vc_sib" -gt 0 ]; then
           echo "    verify-corrections : SIBLING — $_vc_sib pair(s) outside focus $focus_slug not enforced"
           echo "WARN: verify-corrections found $_vc_sib one-directional pair(s) outside focus $focus_slug — not enforced for this --focus close." >&2
         fi
       fi
     else
       _vc_refuse ERROR "verify-corrections exited 1 with no findings (could not run?) — see verify-corrections.sh output"
     fi;;
  2) if grep -q 'no block files' <<<"$_vc_out"; then   # exit 2 is ambiguous: no-blocks vs bad args — read the reason
       echo "    verify-corrections : n/a — no block files"
     else
       _vc_refuse ERROR "verify-corrections.sh did not run (bad args, exit 2) — the §14 reciprocity check was NOT performed"
     fi;;
  *) _vc_refuse ERROR "verify-corrections.sh did not run (exit $_vc_rc) — check it exists and is executable";;
esac
# --- SECRETS GATE: the archive's packaging list + committed history, for a git-backed repo root (#970 #1014 #1015) ----
# Round 2 of this gate built a mirror that re-implemented `git status -z` parsing; it was REMOVED (round 3,
# Opus re-review) because it inherited scan-secrets.sh's corpus-root narrowing, could not see gitignored files,
# resolved nested-target paths against the wrong root, followed symlinks into a /tmp copy and swallowed
# per-file copy failures. Do not re-introduce a git-status-driven delta.
#
# WHAT IS SCANNED (kit issue #1015): the gate scans every regular file under the physical $target, git-ignored
# files included — the PROMPT-LOOP close gate / #970 doctrine: the working tree is read as it sits on disk, so
# a secret in a git-ignored file refuses (symlinks are not followed and `.git` is not authored content). This
# does NOT model what any packaging step would ship; it is a conservative whole-target read. The list is computed
# HERE (_ss_build_list) and handed to `scan-secrets.sh --files-from`, which applies its
# own file scope (*.md + high-risk config, vendored/decompiled trees excluded) to it. scan-secrets.sh's default
# mode narrows to the shallowest block directory, so it is NOT used by this gate: a secret-bearing notes.md
# outside that directory was skipped although it lies under the target. There is deliberately NO git-ignore
# filter (it reversed #970 and its output filter was fail-open). If the list cannot be computed (find failed
# for a reason other than an unreadable subtree) or comes out EMPTY (a target with a RESEARCH-STATE.md always
# lists at least that file) the gate REFUSES with a typed ERROR — an unproven look is never a pass (§7). An
# unreadable DIRECTORY (find: "Permission denied", and nothing else on stderr) cannot be added to git either: it
# is counted, WARNed on stderr and disclosed on the verdict line instead of refusing. An unreadable in-scope FILE
# or any grep read error is scan-secrets.sh exit 3 (DEGRADED) → typed ERROR + REFUSE, never `ok`.
#   (b) `scan-secrets.sh --committed "$target"` — everything ever committed, reachable from HEAD. It REFUSES
#       (exit 3) a SUBDIRECTORY of its repo (MAJOR3 in scan-secrets.sh), and $corpus can be a subdirectory of
#       $target in a nested/SPLIT layout (research-sdd-init.sh runs `git init` ONCE, at $target) — so (b)
#       always targets $target (the repo root), never $corpus.
# A leak in either REFUSES; dirtiness alone never does (round-1 lesson, kept): the PROMPT-LOOP close flow always
# leaves the tree dirty here (`--sync-state` rewrites RESEARCH-STATE.md; CONSOLIDATE below writes CATALOG.md;
# the corpus commit is a checklist step AFTER archive, not a precondition).
#
# THE GIT STATES this gate tells apart (§7 — a downgrade that can't prove it looked is a bug):
#   - $target has no git repo of its own — git POSITIVELY reports "not a git repository", and there is no
#     `.git` entry — packaging-list scan only (pre-#970 behaviour; a corpus mid-BOOTSTRAP may not be versioned).
#   - $target is a SUBDIRECTORY of a LARGER enclosing repo (`git rev-parse --show-toplevel` resolves above the
#     PHYSICAL $target, `pwd -P` — a symlinked root is not nested, #1014) — history scanning is skipped with a
#     loud WARN naming the enclosing root.
#   - $target is a repo root with NO COMMITS at all (research-sdd-init.sh runs `git init` without a commit, the
#     corpus commit comes after archive; #1014) — nothing to scan in history: typed WARN, packaging-list scan only.
#   - ANY OTHER git failure — missing/stubbed git, "dubious ownership", a malformed global config, … — is NOT
#     "no repo": this gate refuses loudly (F3) instead of guessing.
_ss_phys="$(cd -P "$target" 2>/dev/null && pwd -P)"
_ss_list=""; _ss_ferr=""; _ss_unreadable=0; _ss_wt_why=""; _ss_leak_wt=0; _ss_leak_hist=0
trap 'rm -f "$_ss_list" "$_ss_ferr"' EXIT
_ss_build_list() {  # → rc 0 list ready · 1 cannot be computed · 2 computed but EMPTY; fills _ss_list/_ss_unreadable
  _ss_unreadable=0
  [ -n "$_ss_phys" ] || return 3
  _ss_list="$(mktemp)" && _ss_ferr="$(mktemp)" || return 1
  local frc
  LC_ALL=C find "$_ss_phys" \( -name .git -type d \) -prune -o -type f -print0 > "$_ss_list" 2> "$_ss_ferr"; frc=$?  # SS-PACKAGING-LIST
  if [ "$frc" -ne 0 ]; then
    # only "Permission denied" (an unreadable subtree) is tolerated, and only with PROOF: stderr must be non-empty
    # and every line must be that message. Any other error — or a failure with silent stderr — = list not computed.
    [ -s "$_ss_ferr" ] || return 1
    if grep -qv 'Permission denied' "$_ss_ferr"; then return 1; fi
    _ss_unreadable="$(grep -c 'Permission denied' "$_ss_ferr")"
    echo "WARN: scan-secrets packaging list skipped $_ss_unreadable unreadable path(s) — unreadable by this process, not scanned" >&2
  fi
  [ -s "$_ss_list" ] || return 2
  return 0
}
_ss_wt_scan() {  # → _ss_wt_rc: scan-secrets.sh's own rc over the packaging list; 90 = list not computable · 91 = list empty
  _ss_build_list; _ss_wt_rc=$?
  case "$_ss_wt_rc" in
    0) "$here/scan-secrets.sh" --files-from "$_ss_list" "$_ss_phys" >/dev/null 2>&1; _ss_wt_rc=$?;;  # SS-WT-SCAN
    3) _ss_wt_rc=90; _ss_wt_why="the target directory could not be resolved physically (cd -P failed) — refusing rather than scanning an unknown location";;
    1) _ss_wt_rc=90; _ss_wt_why="the packaging list could not be computed (find failed) — refusing rather than scanning an unknown file set";;
    *) _ss_wt_rc=91; _ss_wt_why="the packaging list is EMPTY (no file under the target) — refusing rather than reporting a scan that looked at nothing";;
  esac
}
# rc 3 from the working-tree scan is DEGRADED: an unreadable in-scope file or a grep read error — never a clean scan.
_ss_degraded_note() { if [ "$1" = 3 ]; then printf ' — DEGRADED: an unreadable in-scope file or a grep read error, scan incomplete'; fi; return 0; }
_ss_unread_note() { if [ "$_ss_unreadable" -gt 0 ]; then printf ', %s unreadable path(s) not scanned' "$_ss_unreadable"; fi; return 0; }
# Verdict for a working-tree-only scan (non-git / nested / unborn). $1 = context suffix for the ok/FAIL/ERROR lines.
_ss_wt_only_verdict() {
  case "$_ss_wt_rc" in
    0) echo "    scan-secrets  : ok$1$(_ss_unread_note)";;
    1) echo "    scan-secrets  : FAIL — a high-confidence secret VALUE leaked into the working tree$1 (SECRETS DISCIPLINE)"
       gate_rc=1; _ss_leak_wt=1  # scan-secrets-gate-fail
       ;;
    90|91) echo "    scan-secrets  : ERROR — $_ss_wt_why$1"
       gate_rc=1  # scan-secrets-gate-list-error
       ;;
    *) echo "    scan-secrets  : ERROR — scan-secrets.sh did not run cleanly (exit $_ss_wt_rc)$(_ss_degraded_note "$_ss_wt_rc")$1"
       gate_rc=1  # scan-secrets-gate-run-error
       ;;
  esac
}
if ! command -v git >/dev/null 2>&1; then
  echo "    scan-secrets  : ERROR — git not found on PATH — cannot tell whether \$target is a git repository (needed to also scan committed history) — refusing rather than silently scanning the working tree only"
  gate_rc=1  # scan-secrets-gate-no-git
else
  _ss_top_out="$(git -C "$target" rev-parse --show-toplevel 2>&1)"; _ss_top_rc=$?
  if [ "$_ss_top_rc" -ne 0 ] && grep -qi 'not a git repository' <<<"$_ss_top_out" && [ ! -e "$target/.git" ]; then
    # confirmed NOT a git repo — working-tree-only fallback over the packaging list.
    _ss_wt_scan
    _ss_wt_only_verdict ""
  elif [ "$_ss_top_rc" -ne 0 ]; then
    echo "    scan-secrets  : ERROR — could not determine whether \$target is a git repository (git rev-parse --show-toplevel: $(printf '%s' "$_ss_top_out" | head -1 | cut -c1-160)) — refusing rather than guessing"
    gate_rc=1  # scan-secrets-gate-git-probe-error
  elif [ "$(cd -P "$_ss_top_out" 2>/dev/null && pwd -P)" != "$_ss_phys" ]; then  # SS-NESTED-PHYSICAL
    # NESTED TARGET (F4): $target has no repo of its own — it lives inside the enclosing repo at
    # $_ss_top_out. Working-tree-only coverage, loudly disclosed; never the misleading generic error.
    echo "WARN: history not scanned — target is inside enclosing repo $_ss_top_out" >&2  # SS-NESTED-WARN
    _ss_wt_scan
    _ss_wt_only_verdict " (working tree only — target nested inside $_ss_top_out, see WARN above)"
  elif ! git -C "$target" rev-parse --verify -q HEAD >/dev/null 2>&1 \
       && _ss_refs="$(git -C "$target" for-each-ref --count=1 refs/ 2>/dev/null)" && [ -z "$_ss_refs" ]; then
    # UNBORN repo (#1014): `git init` with no commit anywhere. There is no history to scan.
    echo "WARN: history not scanned — repository has no commits yet" >&2  # SS-UNBORN-WARN
    _ss_wt_scan
    _ss_wt_only_verdict " (working tree only — repository has no commits yet, see WARN above)"
  else
    _ss_wt_scan
    "$here/scan-secrets.sh" --committed "$target" >/dev/null 2>&1; _ss_hist_rc=$?
    _ss_where=""
    [ "$_ss_wt_rc" = 1 ] && _ss_where="the working tree"
    if [ "$_ss_hist_rc" = 1 ]; then
      if [ -n "$_ss_where" ]; then _ss_where="$_ss_where and committed history"
      else _ss_where="committed history"; fi
    fi
    if [ -n "$_ss_where" ]; then
      echo "    scan-secrets  : FAIL — a high-confidence secret VALUE leaked into $_ss_where (SECRETS DISCIPLINE)"
      gate_rc=1; _ss_leak_wt=0; _ss_leak_hist=0  # scan-secrets-gate-fail
      [ "$_ss_wt_rc" = 1 ] && _ss_leak_wt=1
      [ "$_ss_hist_rc" = 1 ] && _ss_leak_hist=1
    elif [ "$_ss_wt_rc" = 90 ] || [ "$_ss_wt_rc" = 91 ]; then
      echo "    scan-secrets  : ERROR — $_ss_wt_why"
      gate_rc=1  # scan-secrets-gate-list-error
    elif [ "$_ss_wt_rc" != 0 ] || [ "$_ss_hist_rc" != 0 ]; then
      echo "    scan-secrets  : ERROR — did not run cleanly (working-tree rc=$_ss_wt_rc, committed-history rc=$_ss_hist_rc)$(_ss_degraded_note "$_ss_wt_rc") — check git/awk/tr are available and \$target has at least one commit"
      gate_rc=1  # scan-secrets-gate-run-error
    else
      echo "    scan-secrets  : ok$(_ss_unread_note)"
    fi
  fi
fi
# undocumented_findings gate — default scope is $target, NOT $corpus. INVARIANT: inspect EVERY
# focus under the target, not only those under the first-discovered corpus directory. WHY: in a
# SPLIT layout (focuses in sibling subdirectories rather than flat in one dir), $corpus is only the
# FIRST focus's directory (line ~72: corpus=dirname of the shallowest state file). Scoping to
# $corpus silently skips sibling focuses; any UF debt in them passes this gate unseen. The
# _uf_sf_count guard below catches EMPTY enumeration (zero files inspected) but NOT PARTIAL
# enumeration (some focuses missed) — that is why the scope must be $target so list_state_files
# reaches all focuses at maxdepth 3. EXCEPTION: when --focus <slug> was given (AR1), the gate is
# intentionally scoped to the single named focus; all other focuses are out of scope for this run.
# Multi-focus corpora have one state file per focus (RESEARCH-STATE-<slug>.md). Absent field or
# non-integer → treated as 0 (legacy corpora predate this field). Any positive value in ANY
# inspected focus means at least one finding was saved to memory without a block; refuse until the
# researcher writes the block(s), decrements the counter in the state file, then --sync-state.
# AR1-FOCUS-SCOPE: scope UF enumeration to the single named focus when --focus was given.
_uf_sf_src() {
  [ -n "$focus_slug" ] && printf '%s\n' "$state" || list_state_files "$target"  # AR1-FOCUS-SCOPE
}
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
done < <(_uf_sf_src)
# Report scope so the operator can verify what was inspected (§7: report only what you measured).
if [ -n "$focus_slug" ]; then
  echo "    undocumented_findings: scoped to focus $focus_slug — $_uf_sf_count of $(list_state_files "$target" | wc -l | tr -d ' ') state file(s) inspected"
fi
# Fail-closed invariant: $target was verified above (resolve_state_file above resolved a RESEARCH-STATE*.md
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
# --- MISSING-RETRO gate (D6: promoted from advisory WARN — § niagara-research retro 2026-08-25):
# A corpus that has advanced past the newest §18 retro must be refused, not merely warned.
# States: blocks=0 → no advancement (silent); retros=0 with blocks>0 → no qualifying retro ever
# (gate fires); retros>0 but newest_block_epoch>newest_retro_epoch → corpus advanced (gate fires);
# retros>0 with newest_retro_epoch>=newest_block_epoch → valid retro covers this run (silent).
# Computed here (before the gate decision) so the close is refused BEFORE consolidation runs.
# Respects retro_is_excluded() — excluded retros (kit-retro: exclude) are not §18 retros.
#
# newest_block_epoch is computed FIRST so prior_retro_epoch (the newest retro ≤ newest_block_epoch)
# can be tracked inline in the retro loop. prior_retro_epoch is the ONE-BLOCK-PER-COMMIT detector's
# window start (the previous run's retro), kept distinct from newest_retro_epoch (the close retro).
blocks="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null | block_file_filter | wc -l | tr -d ' ')"
newest_block_epoch=0
while IFS= read -r _mr_bf; do
  [ -n "$_mr_bf" ] || continue
  _mr_e="$(rsdd_added_epoch "$corpus" "$_mr_bf")"; [ "${_mr_e:-0}" -gt "$newest_block_epoch" ] && newest_block_epoch="$_mr_e"
done < <(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null | block_file_filter)
retros=0; newest_retro_epoch=0; prior_retro_epoch=0
while IFS= read -r _mr_rf; do
  [ -n "$_mr_rf" ] || continue
  retro_is_excluded "$_mr_rf" && continue
  retros=$((retros + 1))
  _mr_e="$(rsdd_added_epoch "$corpus" "$_mr_rf")"
  [ "${_mr_e:-0}" -gt "$newest_retro_epoch" ] && newest_retro_epoch="$_mr_e"
  # prior_retro_epoch: the newest qualifying retro whose epoch is ≤ newest_block_epoch — this is the
  # "end of the previous run" and anchors the ONE-BLOCK-PER-COMMIT window so that a close retro
  # (added after blocks to satisfy this gate) does not shift the OBPC window past all the blocks.
  [ "${_mr_e:-0}" -le "$newest_block_epoch" ] && [ "${_mr_e:-0}" -gt "$prior_retro_epoch" ] && prior_retro_epoch="$_mr_e"
done < <(find "$corpus" "$target" -maxdepth 2 -path '*/retros/*.md' 2>/dev/null | sort -u)
if [ "${blocks:-0}" -gt 0 ] && { [ "$retros" -eq 0 ] || [ "$newest_block_epoch" -gt "$newest_retro_epoch" ]; }; then
  if [ "$retros" -eq 0 ]; then _mr_rdate="none"
  else _mr_rdate="$(date -d "@$newest_retro_epoch" +%Y-%m-%d 2>/dev/null || echo '?')"; fi
  echo "    MISSING-RETRO  : REFUSE — corpus advanced past the newest §18 retro ($_mr_rdate) — delegate a retro before closing (propose-never-apply)"
  gate_rc=1  # missing-retro-gate-refuse
fi
if [ "$gate_rc" != 0 ]; then
  echo "  REFUSED: reconcile the failing gate(s) before archiving. Run for detail:"
  echo "    $here/verify-state.sh $corpus"
  echo "    $here/verify-sources.sh $corpus"
  echo "    $here/verify-corrections.sh $corpus"
  # Mirror the SAME git-state classification the gate above used, INCLUDING the ambiguous-failure case
  # (#970 round 3 fix #7): a shallower re-check here previously fell through to suggesting a
  # scan-secrets command in the F3 ambiguous-git-failure case too, even though the gate refused BEFORE
  # ever running scan-secrets there — printing a command the gate never ran. Say so instead.
  if ! command -v git >/dev/null 2>&1; then
    echo "    git probe failed — fix git first (git not found on PATH)"
  else
    _hint_top_out="$(git -C "$target" rev-parse --show-toplevel 2>&1)"; _hint_top_rc=$?
    _hint_top_phys=""; [ "$_hint_top_rc" -ne 0 ] || _hint_top_phys="$(cd -P "$_hint_top_out" 2>/dev/null && pwd -P)"
    # The packaging-list scan, as a pasteable command (every path shell-quoted with %q).
    if [ -z "$_ss_phys" ]; then  # SS-UNRESOLVABLE-HINT
      echo "    target unresolvable — cd -P failed on $target, so the scan command cannot be printed; fix the path/permissions first"
    else
    _q_phys="$(printf '%q' "$_ss_phys")"; _q_here="$(printf '%q' "$here")"; _q_target="$(printf '%q' "$target")"
    _hint_wt="find $_q_phys \\( -name .git -type d \\) -prune -o -type f -print0 | $_q_here/scan-secrets.sh --files-from - $_q_phys"
    if [ "$_hint_top_rc" -eq 0 ] && [ "$_hint_top_phys" = "$_ss_phys" ]; then
      echo "    $_hint_wt   # working tree (dirty/untracked/ignored — file scope: *.md + config)"
      echo "    $_q_here/scan-secrets.sh --committed $_q_target   # + committed history"
    elif [ "$_hint_top_rc" -eq 0 ]; then
      echo "    $_hint_wt   # working tree only — target is nested inside $(printf '%q' "$_hint_top_out")"
    elif grep -qi 'not a git repository' <<<"$_hint_top_out" && [ ! -e "$target/.git" ]; then
      echo "    $_hint_wt"
    else
      echo "    git probe failed — fix git first"
    fi
    fi
    if [ "$_ss_leak_wt" = 1 ]; then  # SS-REMEDY-HINT
      echo "    A secret in a git-ignored file still refuses (the gate reads the working tree as it sits on disk): move the"
      echo "    secret store OUTSIDE the target directory and keep only its path/structure in the corpus. There is no override."
    fi
    if [ "$_ss_leak_hist" = 1 ]; then  # SS-HIST-HINT
      echo "    A secret in committed history is not fixed by editing the tree: the history must be rewritten (e.g. git filter-repo),"
      echo "    then rotate the credential. ensure-remote.sh refuses the same way."
    fi
  fi
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
# $blocks and $retros are already computed in the MISSING-RETRO gate section above (same discriminators:
# gen-catalog strict block-file filter; excluded retros omitted from the count).
# Iteration-history rows: data rows in the "## Iteration history" table (numeric first cell; header/separator excluded).
histrows="$(awk 'index($0,"## Iteration history")==1{f=1;next} /^## /{f=0} f' "$state" \
  | awk '{l=$0; gsub(/^[ \t]+|[ \t]+$/,"",l); sub(/^\|/,"",l); n=split(l,a,"|"); gsub(/^[ \t]+|[ \t]+$/,"",a[1]); if (a[1] ~ /^[0-9]+$/) c++} END{print c+0}')"
echo "  -- mirror facts (for the TARGETS.md row refresh; not applied here) --"
echo "    blocks on disk : $blocks · retros: $retros · iteration-history rows: $histrows"

# --- ONE-BLOCK-PER-COMMIT detector (§ PROMPT-LOOP LOOP CONTINUATION): the "one block per commit" hard rule
# was violated in prose-only practice despite a named precedent (three.js B15+B16; ug67 B29+B30, B32+B33) —
# prose alone did not hold it. Mechanize it as a cheap git gate (mirroring §11's endorsement of corpus-level
# mechanical checks): flag any commit in THIS run (newer than the PRIOR retro — the latest retro at or before the newest block, so a close retro added AFTER the blocks keeps the window; ALL history when there is no
# retro yet) whose diff touches 2+ distinct block files. PURE DETECTION — advisory WARN (exit stays 0, like
# the codegen parity check; the MISSING-RETRO gate below now REFUSES instead of warning); it never rewrites history. Uses the corpus-wide block-file discriminator.
multi_block_commits=""
if git -C "$corpus" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # Count only ADDED block files (--diff-filter=A), so the rule is "one NEW block per commit": an iteration
    # that adds one block AND MODIFIES an existing block to add the §14 reciprocal 'corrected in BN' backlink
    # (which the sibling verify-corrections feature now mandates in the SAME iteration) is NOT a violation.
    # -M/--find-renames (RDD round 2, F4 — same class as retro-gate.sh's #984 fix): force rename
    # detection regardless of the corpus's diff.renames config. Without it, renaming an existing
    # block file (e.g. a filename cleanup) in the same commit as a genuinely new block shows as a
    # plain D+A pair under diff.renames=false — the renamed file's Added half is indistinguishable
    # from the new block, so this would count 2 ADDED block files and false-WARN a violation.
    nbf="$(git -C "$corpus" show --diff-filter=A -M --name-only --format= "$sha" 2>/dev/null \
      | block_file_filter | sort -u | wc -l | tr -d ' ')"
    [ "${nbf:-0}" -ge 2 ] && multi_block_commits="${multi_block_commits}${multi_block_commits:+ }${sha:0:9}(${nbf} blocks)"
  done < <(git -C "$corpus" log --format=%H --since="@${prior_retro_epoch:-0}" 2>/dev/null)
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
# with the codegen parity check).  Does not block: the marker is advisory at close time;
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
[ -n "${one_block_line:-}" ] && echo "${one_block_line}"
# fixed under #1444: `[ -n "$(find ... -print -quit)" ]`, no pipe, so no SIGPIPE race is possible.
if [ -n "$(find "$corpus" -maxdepth 1 -type d -name 'codegen' -print -quit 2>/dev/null)" ]; then
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
