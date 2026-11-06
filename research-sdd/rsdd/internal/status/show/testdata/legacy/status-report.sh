# --- default: structured status report ---------------------------------------------------------
rel="${corpus#"$target"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="(flat)"
metric="$(cov_ratio)"
covered="$(section '## Coverage' | grep -iE 'covered blocks' | grep -oE '[0-9]+' | head -1)"
# B5 FIX: derive per-focus block count (mirrors --sync-state and verify-state.sh).
_stpfx="$(derive_focus_prefix "$state")"
_strange=""   # kit #906
if [ -z "$_stpfx" ]; then _strange="$(derive_focus_range "$state")"; focus_range_report "$state" 'status: %s: %s\n' >&2; case "$_strange" in '!'*) _strange="" ;; esac; fi  # RANGE-REPORT
if [ -n "$_stpfx" ]; then
  ondisk="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
    | block_file_filter "${_stpfx}" | wc -l | tr -d ' ')"
elif [ -n "$_strange" ]; then
  ondisk="$(focus_range_block_count "$corpus" "$_strange" "$state")"  # RANGE-DISPLAY-COUNT
else
  ondisk="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
    | block_file_filter | wc -l | tr -d ' ')"
fi
inv="$(inv_count)"
req="$(req_prose)"   # token-anchored + paren-stripped (a bare first-integer grep grabbed §8 on logosoft)
blk="$(derive_blocked_open)"; _blk_rc=$?   # disk-DERIVED (needs:-anchored) — NOT the stop-control prose, whose bare first-integer grep grabbed a "§8" section number (logosoft showed blocked=8)
# BO-DEGRADED-DISPLAY (#2017): a failed derivation is shown as DEGRADED, never as a blank/0/`?` count. Exit stays 0 by
# this script's contract (findings are REPORTED in the output, see the final exit); the typed line goes to stderr.
if [ "$_blk_rc" -ne 0 ]; then
  blk="DEGRADED"; inv="DEGRADED"   # every count derived from the blocked sections is untrustworthy now, not just blocked_open
  printf 'research-sdd-status: blocked_open derivation degraded (blocked_open_count rc %s on %s)\n' "$_blk_rc" "$state" >&2
fi
ph=$(backlog_rows 2>/dev/null | awk -F'\t' '$2~/~~/{next} {st=$3; sub(/^\*\*/, "", st); sub(/\*\*$/, "", st)} st=="pending"{n[$1]++} END{printf "high=%d medium=%d low=%d", n["high"], n["medium"], n["low"]}')

_RC_DEGRADED_PRINTED=0   # set by every typed `degraded:` echo of the report body (W6 footer below); outside the RC-WIRE region so the blocked_open line can set it too
echo "== research-sdd-status: $(basename "$target")  ·  corpus: $rel =="
[ "$_blk_rc" -eq 0 ] || { _RC_DEGRADED_PRINTED=1; echo "degraded: blocked_open: blocked_open_count rc $_blk_rc — blocked/investigable/next step not derived (CLAUDE.md §7: not a zero)"; }   # BO-DEGRADED-LINE (S5, #2024 item 4/6): inside the report body, flag set so the footer covers it
_chk_abs="$(CDPATH="" cd -- "$target" 2>/dev/null && pwd)"  # kit #1150 item 1: name the directory the wiring was checked at
echo "  Stop hook       : $(hook_stop_wiring_state "$target") (checked: ${_chk_abs:-$target})"
echo "  coverage metric : ${metric:-<none>}"
echo "  covered blocks  : ${covered:-<none>} claimed · ${ondisk} on disk"
echo "  pending backlog : $ph"
echo "  stop-control    : investigable=${inv:-?} · requires-execution=${req:-?} · blocked=${blk:-?}"
_rt="$(count_retyped_in_table)"
[ "${_rt:-0}" -gt 0 ] && echo "  re-typed in table : ${_rt} — row(s) carry the literal 're-typed' Status — use 'blocked (requires-<what>)' (METHODOLOGY §8b); counted in no bucket"  # RETYPED-VISIBLE (#1638)
if [ "$_doc_mode" = 1 ]; then outline_summary; outline_line
elif [ "$_doc_noheading" = 1 ]; then echo "  outline         : (no ## Outline section — gap-centric verdicts kept)"; fi
mapfile -t ledgers < <(contra_ledgers)
if [ "${#ledgers[@]}" -eq 0 ]; then
  echo "  contradictions  : (no ledger)"
else
  [ "${#ledgers[@]}" -gt 1 ] && echo "WARN: multiple CONTRADICTIONS*.md ledgers under $corpus — counting all ${#ledgers[@]}" >&2
  nopen="$(count_open_contra "${ledgers[@]}")"
  [ "$nopen" -gt 0 ] && echo "  contradictions  : ${nopen} open" || echo "  contradictions  : (none)"
fi
# remote_visibility_block — read back each git remote's visibility (kit issue #1245). ensure-remote.sh
# verifies PRIVATE only at creation and short-circuits on an existing origin, so a remote made PUBLIC later
# is invisible without this. Surfaces the state; NEVER flips it (visibility is the owner's decision).
#   PUBLIC             -> `WARN public-remote: <remote> ...` (stdout, part of the report)
#   PRIVATE / INTERNAL -> silent;  no .git or no remote -> silent (nothing to read back)
#   gh absent / failing / empty or unrecognised answer -> typed `degraded: remote-visibility: ...`
#   (§7: a read-back that could not run is never a silent pass).
# RSDD_GH_BIN overrides the gh binary (tests stub it; no network). Only the remote NAME is printed and
# only OWNER/REPO reaches gh's argv: a remote URL may embed credentials. Empty / non-github URL,
# or a gh call over RSDD_GH_TIMEOUT seconds (default 10 here, 20 in the shared lib/gh-visibility.sh; later remotes are skipped after the first timeout; GH_PROMPT_DISABLED=1) -> typed degraded.
remote_visibility_block() {
  [ -e "$target/.git" ] || return 0
  local _rv_gh="${RSDD_GH_BIN:-gh}" _rv_arr=() _rv_r _rv_url _rv_slug _rv_vis _rv_stalled=0
  command -v git >/dev/null 2>&1 || { _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: git not found — cannot read the remotes of $target"; return 0; }
  mapfile -t _rv_arr < <(git -C "$target" remote 2>/dev/null)
  [ "${#_rv_arr[@]}" -gt 0 ] || return 0
  # Remotes are enumerated BEFORE the lib check (kit issue #1843): a target with no remote needs no probe, so a
  # missing lib/gh-visibility.sh is only worth a degraded line when there is something to probe.
  # shellcheck source=lib/gh-visibility.sh
  . "$here/lib/gh-visibility.sh" 2>/dev/null && declare -F gh_visibility_probe >/dev/null 2>&1 \
    || { _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: lib/gh-visibility.sh unavailable — cannot probe the visibility of the remotes of $target"; return 0; }
  for _rv_r in "${_rv_arr[@]}"; do
    [ -n "$_rv_r" ] || continue
    if ! command -v "$_rv_gh" >/dev/null 2>&1; then
      _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: gh not found — cannot verify the visibility of remote $_rv_r"; continue
    fi
    _rv_url="$(git -C "$target" remote get-url "$_rv_r" 2>/dev/null)" || _rv_url=""
    if [ -z "$_rv_url" ]; then
      _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: $_rv_r url empty or unreadable — visibility unverified"; continue
    fi
    # Reduce the URL to OWNER/REPO (scheme + userinfo + host stripped) so no credential reaches gh's argv;
    # anything that is not a github.com owner/repo is never handed to gh (it could resolve the cwd repo).
    _rv_slug=""
    if [[ "$_rv_url" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)?([^/]*@)?github\.com[:/]+([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9_.-]+)/?$ ]]; then
      _rv_slug="${BASH_REMATCH[3]}/${BASH_REMATCH[4]%.git}"
    fi
    if [ -z "$_rv_slug" ]; then
      _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: $_rv_r not a github owner/repo — visibility unverified"; continue
    fi
    # The bounded probe is the shared one (kit issue #1820, lib/gh-visibility.sh): RSDD_GH_TIMEOUT seconds (default 10 here,
    # 20 in init / ensure-remote), GH_PROMPT_DISABLED=1; `timeout`, else `gtimeout`, else a bash watchdog. Any
    # non-decided result is a typed degraded line — never read as PRIVATE.
    # Latency budget (status runs from the stop/terminal path): historical 10 s default (RSDD_GH_TIMEOUT overrides), and
    # after the FIRST timeout the remaining remotes are not probed — N stalled remotes cost one bound, not N.
    if [ "$_rv_stalled" = 1 ]; then
      _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: skipped after timeout for remote $_rv_r — visibility unverified"; continue
    fi
    GHV_DEFAULT_BOUND=10 gh_visibility_probe "$_rv_gh" "$_rv_slug" || :
    case "$GHV_STATE" in
      TIMEOUT) _rv_stalled=1; _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: gh timed out for remote $_rv_r — visibility unverified"; continue ;;
      GH_ERROR) _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: gh failed (rc=$GHV_RC) for remote $_rv_r — visibility unverified"; continue ;;
      GH_MISSING|PROBE_FAILED) _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: gh probe could not run ($GHV_STATE) for remote $_rv_r — visibility unverified"; continue ;;
    esac
    _rv_vis="$GHV_RAW"
    case "$_rv_vis" in
      PUBLIC) echo "WARN public-remote: $_rv_r is PUBLIC — METHODOLOGY §15: a corpus remote is NEVER public; audit tracked files (ls-files) for decompiled/proprietary paths before any push. Visibility is the owner's call; this check never changes it." ;;
      PRIVATE|INTERNAL) ;;
      *) _RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility: unrecognised gh answer [$_rv_vis] for remote $_rv_r — visibility unverified" ;;
    esac
  done
}
if [ "$_doc_mode" = 1 ]; then  # DOC-SAT-BRANCH
  echo "  saturation      : n/a (method: document-cycle — gap saturation does not apply; the ## Outline decides)"
else
  saturation_line
fi
campaign_status_block
# DISPLAY-DEGRADED-GATE (kit #2024): _ns_gap_run walks EVERY focus (and counts paused ones), so the gate must cover every
# state file it walks, not only the head $state whose figures are shown above. Same probe as the --next gate.
mapfile -t _ns_dg_files < <(list_state_files "$target")
_ns_dg_names="$(_blocked_degraded_files ${_ns_dg_files[@]+"${_ns_dg_files[@]}"})"
[ "$_blk_rc" -eq 0 ] || case ",$_ns_dg_names," in *",$(_rel_state "$state"),"*) ;; *) _ns_dg_names="${_ns_dg_names:+$_ns_dg_names,}$(_rel_state "$state")" ;; esac
[ -z "$_ns_dg_names" ] || _RC_DEGRADED_PRINTED=1   # RC-FLAG-NONHEAD (#2024 S1): a degraded non-head focus sets the footer flag too
# W6 (kit issue #1704, widened by #2024): when remote_visibility_block or the blocked_open derivation prints a typed
# `degraded:` line, name the registry that gives its one continuation. SCOPE: this footer covers the remote-visibility
# block and the `degraded: blocked_open:` line ONLY; other blocks that print a typed state are not covered. The block
# runs directly (no subshell, no buffering, stdout/stderr order untouched) and sets _RC_DEGRADED_PRINTED=1 on the same
# line as each of those `degraded:` echoes (the flag is initialised before the report header). Printed only when the
# flag is set, so a clean report stays byte-identical. The registry lives in the kit's toolbelt next to this script,
# not under the target.
# RC-WIRE-BEGIN
remote_visibility_block
if [ "$_RC_DEGRADED_PRINTED" = 1 ]; then  # RC-FOOTER
  echo "  reason codes    : each typed degraded state in this report (remote-visibility, blocked_open, blocked-rows next step) has one continuation in $here/reason-codes.v1.md"
fi
# RC-WIRE-END
# next step: aggregate across ALL focuses under $target (not just the alphabetically-first one via $state).
# WARNING 3: the default report was binding resolve_next to $state=head-1, so a stopped alpha printed
# "STOP" while beta had open gaps — the supervisor saw misinformation with a green consistency footer.
# Using a subshell keeps $state (and thus $corpus) unchanged in the parent for the footer below.
# Document mode (kit issue #1152): a NEXT / BOOTSTRAP from the Outline is final. STOP is only reported when the
# gap-centric resolver ALSO has no open work: a fully covered Outline does not hide an open investigable gap.
# _ns_gap_run: gap-centric verdict across every focus (subshell: the loop reassigns $state).
_ns_gap_run() (
  _ns_skip_gaps=0
  mapfile -t _ns_states < <(list_state_files "$target")
  for state in "${_ns_states[@]}"; do
    _ns_foc_slug="$(basename "$state" .md)"; _ns_foc_slug="${_ns_foc_slug#RESEARCH-STATE-}"
    _ns_foc_file="$(dirname "$state")/FOCUSES.md"
    _read_focuses_tok_into _ns_foc_tok "$_ns_foc_file" "$(basename "$state")"
    # shellcheck disable=SC2154 # _ns_foc_tok is assigned indirectly by _read_focuses_tok_into via printf -v
    if [ "$_ns_foc_tok" = "stopped" ] || [ "$_ns_foc_tok" = "paused" ]; then
      printf 'INFO: skipped %s (focus-status: %s in FOCUSES.md)\n' "$_ns_foc_slug" "$_ns_foc_tok" >&2
      [ -r "$state" ] || printf 'WARN: cannot read state file %s\n' "$state" >&2
      _ns_inv="$(count_investigable 2>/dev/null)" || { echo "DEGRADED | blocked-rows read failed while counting the paused/stopped focus $(_rel_state "$state") — the no-active-focus count would be inflated; fix the failure named on stderr, then re-run"; exit 0; }
      [ "${_ns_inv:-0}" != "0" ] && _ns_skip_gaps=$(( _ns_skip_gaps + 1 ))
      continue
    fi
    _r="$(resolve_next)"
    case "$_r" in NEXT\ *|DEGRADED\ *) echo "$_r"; exit 0;; esac
  done
  _bu_compute ${_ns_states[@]+"${_ns_states[@]}"}  # BU-REPORT (kit #1959 S1: the default report carries the same qualifier)
  if [ "$_ns_skip_gaps" -gt 0 ]; then
    echo "STOP | no active focus (${_ns_skip_gaps} declared stopped/paused in FOCUSES.md with open gaps)${_BU_SUFFIX}"
  else
    echo "STOP | read-only-investigable exhausted (0)${_BU_SUFFIX}"
  fi
)
_ns_doc=""
if [ "$_doc_mode" = 1 ]; then _ns_doc="$(outline_next_step)"; fi  # DOC-NEXT-BRANCH
case "$_ns_doc" in
  NEXT*|BOOTSTRAP*) printf '  next step       : %s\n' "$_ns_doc" ;;
  *)
    if [ -n "$_ns_dg_names" ]; then printf '  next step       : DEGRADED (blocked-rows derivation unreadable for %s — a next gap or a paused-focus count derived from it would be inflated)\n' "$_ns_dg_names"; else  # NEXT-STEP-DEGRADED-GUARD
    if [ -z "$_ns_doc" ]; then
      printf '  next step       : '
      _ns_gap_run
    else
      _ns_gap="$(_ns_gap_run)"
      case "$_ns_gap" in STOP*) _ns_gap="$_ns_doc" ;; esac  # DOC-STOP-GUARD: only a gap STOP yields to the Outline STOP; NEXT and any other verdict is kept
      printf '  next step       : %s\n' "$_ns_gap"
    fi
    fi
    ;;
esac
echo "  --- consistency (verify-state.sh) ---"
"$here/verify-state.sh" "$corpus" 2>&1 | sed -n '/summary\|FAIL\|WARN\|ok /p' | sed 's/^/  /'
exit 0   # a stale-mirror FAIL is REPORTED in the consistency line above; it must not become our exit code (contract: 0 ok / 2 bad args)
