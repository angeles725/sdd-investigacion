#!/usr/bin/env bash
# research-sdd-status-next-scope.test.sh — `--next` scopes to the PICKED state file when --root or --focus is
# given (kit issue #1837; maintainer decision recorded on the issue: yes).
#
# Before: `--next` aggregated over EVERY state file under the target (first active focus wins) whatever
# --root said, so `--root --next` on a multi-focus corpus could report a FOCUS file's next step. Now:
#   no flag        -> aggregate over every state file (unchanged: "first active focus")
#   --root         -> NEXT/STOP from the un-suffixed root file only
#   --focus <slug> -> NEXT/STOP from RESEARCH-STATE-<slug>.md only (already true before #1837; pinned here)
#   --all          -> explicit corpus-wide form (#1543), same as the no-flag aggregate
#
# NOT scoped by --root: the STALE gate (verify-state over the whole target). Only --focus narrows it (#1543), so an
# active stale sibling still makes `--root --next` print STALE (case 6d pins that boundary).
#
# Two flat-corpus fixtures with opposite shapes, so a mode that picked the wrong file is visible either way:
#   A: root EXHAUSTED (covered), focus `act` has a pending gap  -> only the aggregate / --focus can say NEXT
#   B: root has a pending gap, focus `act` EXHAUSTED            -> only the aggregate / --root can say NEXT
#
# Usage: research-sdd-status-next-scope.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT_UNDER_TEST:-$HERE/../research-sdd-status.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TB="$HERE/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-next-scope.test.sh =="

# mk_state FILE STATUS INVESTIGABLE NAME [BSR] — a clean, derived-consistent state with ONE high gap "the NAME gap";
# BSR (default 0) is the envelope's blocks_since_retro (> 10 makes --next answer RETRO-DUE for that file).
mk_state() {
  {
    echo "# S — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: %s\nrequires_execution_open: 0\nblocked_open: 0\nblocks_since_retro: %s\n<!-- /research-state.v1 -->\n\n' "$3" "${5:-0}"
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    echo "| high | the $4 gap | web | $2 |"
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: $3"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$1"
}
fxA="$TMP/A"; mkdir -p "$fxA"; mk_state "$fxA/RESEARCH-STATE.md" covered 0 root; mk_state "$fxA/RESEARCH-STATE-act.md" pending 1 act
fxB="$TMP/B"; mkdir -p "$fxB"; mk_state "$fxB/RESEARCH-STATE.md" pending 1 root; mk_state "$fxB/RESEARCH-STATE-act.md" covered 0 act

# Fixture C (RETRO-DUE scope): both files have work, only the FOCUS file is past the retro threshold (11 > 10).
fxC="$TMP/C"; mkdir -p "$fxC"; mk_state "$fxC/RESEARCH-STATE.md" pending 1 root; mk_state "$fxC/RESEARCH-STATE-act.md" pending 1 act 11

STOP_LINE="STOP | read-only-investigable exhausted (0)"

# nx SUT FIXTURE ARGS... -> the single --next verdict line (stdout only; stderr dropped)
nx() { local s="$1" f="$2"; shift 2; bash "$s" "$f" --next "$@" 2>/dev/null | head -1; }
want_next() { # LABEL GOT GAPNAME — GOT must be the NEXT line naming exactly that gap
  if [ "$2" = "NEXT | high | the $3 gap" ]; then ok "$1 -> NEXT the $3 gap"; else no "$1: want [NEXT | high | the $3 gap], got [$2]"; fi; }
want_stop() { # LABEL GOT — the picked file is exhausted: exactly the STOP verdict, nothing else
  if [ "$2" = "$STOP_LINE" ]; then ok "$1 -> $STOP_LINE"; else no "$1: want [$STOP_LINE], got [$2]"; fi; }

# 0. fixture guard: both files are really picked by their flag (else every case below is vacuous)
[ "$(bash "$SUT" "$fxA" --root 2>/dev/null | sed -n 's/^  pending backlog : //p')" = "high=0 medium=0 low=0" ] \
  && ok "0a fixture A: --root report sees the exhausted root" || no "0a fixture A root is not exhausted"
[ "$(bash "$SUT" "$fxB" --focus act 2>/dev/null | sed -n 's/^  pending backlog : //p')" = "high=0 medium=0 low=0" ] \
  && ok "0b fixture B: --focus act report sees the exhausted focus" || no "0b fixture B focus is not exhausted"

# 1. no flag: the aggregate is unchanged — first active file wins, whichever file it is
want_next "1a no flag, root exhausted" "$(nx "$SUT" "$fxA")" act
want_next "1b no flag, focus exhausted" "$(nx "$SUT" "$fxB")" root
# 2. --root: scoped to the root file
want_stop "2a --root, root exhausted (focus has work)" "$(nx "$SUT" "$fxA" --root)"
want_next "2b --root, root has work" "$(nx "$SUT" "$fxB" --root)" root
# 3. --focus act: scoped to that focus (behaviour before #1837, pinned so a regression cannot slip through)
want_next "3a --focus act, focus has work" "$(nx "$SUT" "$fxA" --focus act)" act
want_stop "3b --focus act, focus exhausted (root has work)" "$(nx "$SUT" "$fxB" --focus act)"
# 4. --all: explicit corpus-wide form == the aggregate
want_next "4a --all, root exhausted" "$(nx "$SUT" "$fxA" --all)" act
want_next "4b --all, focus exhausted" "$(nx "$SUT" "$fxB" --all)" root

# 5. RETRO-DUE follows the same scope: the focus file is due, the root is not
case "$(nx "$SUT" "$fxC")" in "RETRO-DUE |"*) ok "5a no flag -> RETRO-DUE from the aggregate (focus file is due)" ;; *) no "5a no flag: want RETRO-DUE, got [$(nx "$SUT" "$fxC")]" ;; esac
want_next "5b --root ignores the focus file's retro debt" "$(nx "$SUT" "$fxC" --root)" root
case "$(nx "$SUT" "$fxC" --focus act)" in "RETRO-DUE |"*) ok "5c --focus act -> RETRO-DUE from the picked focus" ;; *) no "5c --focus act: want RETRO-DUE, got [$(nx "$SUT" "$fxC" --focus act)]" ;; esac

# 6. the picked root must survive the STALE-bypass loop (a multi-focus corpus whose only non-root file is a STOPPED
#    focus with a stale envelope reassigns the global $state to the sibling; --root must still report the ROOT).
fxD="$TMP/D"; mkdir -p "$fxD/z"; mk_state "$fxD/RESEARCH-STATE.md" pending 1 root; mk_state "$fxD/z/RESEARCH-STATE-x.md" pending 0 x
printf '| focus | status |\n|---|---|\n| x | stopped |\n' > "$fxD/z/FOCUSES.md"
want_next "6a --root with a stopped stale sibling in a subdir" "$(nx "$SUT" "$fxD" --root)" root
want_next "6b no flag (aggregate) with the same corpus" "$(nx "$SUT" "$fxD")" root
# 6d: an ACTIVE stale sibling is still a corpus-wide STALE even under --root (documented non-scoping)
fxE="$TMP/E"; mkdir -p "$fxE"; mk_state "$fxE/RESEARCH-STATE.md" pending 1 root; mk_state "$fxE/RESEARCH-STATE-act.md" pending 0 act
case "$(nx "$SUT" "$fxE" --root)" in "STALE |"*) ok "6d active stale sibling -> --root --next still prints STALE (gate is corpus-wide)" ;; *) no "6d: want STALE, got [$(nx "$SUT" "$fxE" --root)]" ;; esac

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the --next scope --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  # mutate NAME SEDEXPR -> sets MUT to the mutant SUT (or records a build failure)
  mutate() {
    local t; t="$(mk_tree "$1")"
    if mutant_sed "$TB/research-sdd-status.sh" "$t/research-sdd-status.sh" "$2" >/dev/null 2>&1; then MUT="$t/research-sdd-status.sh"; return 0; fi
    no "teeth $1: mutant could not be built (anchor absent / refused by lib/mutant.sh)"; return 1
  }
  # A: --root no longer scopes the aggregation -> case 2a (and only the --root branch) goes red
  if mutate A 's/^  \[ "\$root_flag" = 1 \] && _ns_scoped=1  # NEXT-ROOT-SCOPE$/  [ "$root_flag" = 1 ] \&\& _ns_scoped=0  # NEXT-ROOT-SCOPE/'; then
    case "$(nx "$MUT" "$fxA" --root)" in NEXT*) ok "teeth A: --root scoping dropped -> case 2a has teeth" ;; *) no "teeth A: mutant stayed scoped — THEATER" ;; esac; fi
  # B: --focus no longer scopes -> case 3b goes red
  if mutate B 's/^  \[ -n "\$focus_slug" \] && _ns_scoped=1  # NEXT-FOCUS-SCOPE$/  [ -n "$focus_slug" ] \&\& _ns_scoped=0  # NEXT-FOCUS-SCOPE/'; then
    case "$(nx "$MUT" "$fxB" --focus act)" in NEXT*) ok "teeth B: --focus scoping dropped -> case 3b has teeth" ;; *) no "teeth B: mutant stayed scoped — THEATER" ;; esac; fi
  # C: the scoped predicate is always true -> the no-flag aggregate is lost -> case 1a goes red
  if mutate C 's/^  _ns_scoped=0  # NEXT-SCOPE-DEFAULT$/  _ns_scoped=1  # NEXT-SCOPE-DEFAULT/'; then
    case "$(nx "$MUT" "$fxA")" in NEXT*) no "teeth C: mutant still aggregates — THEATER" ;; *) ok "teeth C: aggregate lost for the no-flag form -> case 1a has teeth" ;; esac; fi
  # D: --all behaves as --root (the mutant keeps exit 0: all_flag cleared, so the --all/--root exclusion never fires).
  #    Fixture A gives DIFFERENT verdicts for the two: real --all -> NEXT the act gap, --root -> STOP. The mutant must
  #    print exactly the --root verdict, so a crash or empty output cannot pass for a bite -> case 4a goes red.
  if mutate D 's/^    --all) all_flag=1; shift ;;$/    --all) all_flag=0; root_flag=1; shift ;;/'; then
    got="$(nx "$MUT" "$fxA" --all)"
    [ "$(nx "$SUT" "$fxA" --all)" != "$(nx "$SUT" "$fxA" --root)" ] || no "teeth D: fixture A gives --all and --root the same verdict - vacuous"
    if [ "$got" = "$STOP_LINE" ]; then ok "teeth D: --all scoped to the root -> exactly the --root verdict -> case 4a has teeth"
    else no "teeth D: want the --root verdict [$STOP_LINE], got [$got] - THEATER or crashed mutant"; fi; fi
  # E: the RETRO-DUE check ignores the scope and walks every state file -> case 5b goes red
  if mutate E 's/^  if \[ "\$_ns_scoped" = 1 \]; then$/  if false; then/'; then
    case "$(nx "$MUT" "$fxC" --root)" in "RETRO-DUE |"*) ok "teeth E: RETRO-DUE scope dropped -> case 5b has teeth" ;; *) no "teeth E: mutant stayed scoped — THEATER" ;; esac; fi
  # F: the scoped --next uses the clobbered global $state instead of the saved pick -> case 6a goes red. The mutant
  #    must exit 0 and print the SIBLING's verdict (not crash).
  if mutate F 's/^    _rd_states=("\$_ns_pick")  # NEXT-PICK-RD$/    _rd_states=("$state")  # NEXT-PICK-RD/'; then
    got="$(nx "$MUT" "$fxD" --root)"; bash "$MUT" "$fxD" --next --root >/dev/null 2>&1; rc=$?
    if [ "$rc" = 0 ] && [ "$got" = "NEXT | high | the x gap" ]; then ok "teeth F: saved pick unused -> sibling's verdict [$got] -> case 6a has teeth"
    else no "teeth F: want exit 0 + the sibling's verdict, got rc=$rc [$got] — THEATER or crashed mutant"; fi; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
