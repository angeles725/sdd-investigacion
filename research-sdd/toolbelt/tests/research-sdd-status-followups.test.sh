#!/usr/bin/env bash
# research-sdd-status-followups.test.sh — two report-shape follow-ups on research-sdd-status.sh.
#
#   kit #1544  `--next` STALE names WHICH file/check failed (first verify-state FAIL), not only "reconcile first".
#   kit #1150  item 1: the `Stop hook` line carries `(checked: <abs path>)` so the same target reached through
#              two different directories no longer reads as two unexplained answers (wired vs absent-settings).
#
# Usage: research-sdd-status-followups.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-status.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-followups.test.sh =="

ENV_OK='<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n'
# declares investigable_open=0 while one pending gap exists -> verify-state CHECK B FAIL
ENV_BAD='<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n'
# mk FILE good|bad
mk() {
  { echo "# S — Research State"; echo
    if [ "$2" = good ]; then printf '%b\n' "$ENV_OK"; else printf '%b\n' "$ENV_BAD"; fi
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    echo "| high | the gap | web | pending |"
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: 1"
  } > "$1"
}
run() { local s="$1"; shift; bash "$s" "$@" 2>/dev/null; }

single="$TMP/single"; mkdir -p "$single"; mk "$single/RESEARCH-STATE.md" bad
multi="$TMP/multi"; mkdir -p "$multi"; mk "$multi/RESEARCH-STATE-good.md" good; mk "$multi/RESEARCH-STATE-broken.md" bad
clean="$TMP/clean"; mkdir -p "$clean"; mk "$clean/RESEARCH-STATE.md" good

echo "-- #1544: STALE names the first failing file + check --"
got="$(run "$SUT" "$single" --next)"
case "$got" in "STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh $single"*) ok "1a STALE keeps its pre-existing prefix byte-for-byte" ;; *) no "1a prefix changed: [$got]" ;; esac
case "$got" in *"[first failure: RESEARCH-STATE.md: envelope investigable_open=0 != 1 "*) ok "1b single-focus STALE names the file and the failing check" ;; *) no "1b no pointer: [$got]" ;; esac
[ "$(grep -c '' <<<"$got")" = 1 ] && ok "1c STALE stays ONE line" || no "1c STALE line count: [$got]"

got="$(run "$SUT" "$multi" --next --all)"
case "$got" in *"[failing focus: broken]"*"first failure: RESEARCH-STATE-broken.md: envelope investigable_open=0"*) ok "2a multi-focus STALE: failing focus AND its first failing check" ;; *) no "2a multi: [$got]" ;; esac
case "$got" in *"RESEARCH-STATE-good.md"*) no "2b multi STALE wrongly names the clean file: [$got]" ;; *) ok "2b multi STALE does not name the clean file" ;; esac
got="$(run "$SUT" "$multi" --next --focus broken)"
case "$got" in *"first failure: RESEARCH-STATE-broken.md: "*) ok "3 --focus broken STALE names its own file" ;; *) no "3 --focus: [$got]" ;; esac

got="$(run "$SUT" "$clean" --next)"
case "$got" in NEXT\ *) ok "4 a consistent corpus is untouched (NEXT, no pointer)" ;; *) no "4 clean corpus: [$got]" ;; esac

echo "-- #1150 item 1: Stop hook line names the checked path --"
rep="$(run "$SUT" "$clean")"
want="  Stop hook       : absent-settings (checked: $clean)"
grep -qxF "$want" <<<"$rep" && ok "5a Stop hook line carries (checked: <abs target>)" || no "5a Stop hook line: [$(grep 'Stop hook' <<<"$rep")] want [$want]"
rel="$(cd "$clean" && bash "$SUT" . 2>/dev/null | grep 'Stop hook')"
[ "$rel" = "$want" ] && ok "5b a relative target is printed as its absolute path" || no "5b relative target: [$rel]"
mkdir -p "$TMP/two/corpus"; mk "$TMP/two/corpus/RESEARCH-STATE.md" good
mkdir -p "$TMP/two/.claude"; printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}' > "$TMP/two/.claude/settings.json"
a="$(run "$SUT" "$TMP/two" | grep 'Stop hook')"; b="$(run "$SUT" "$TMP/two/corpus" | grep 'Stop hook')"
case "$a" in *": wired (checked: $TMP/two)") ok "5c root of the target reads wired and names itself" ;; *) no "5c root: [$a]" ;; esac
case "$b" in *": absent-settings (checked: $TMP/two/corpus)") ok "5d the same target through corpus/ reads absent-settings and names that path (the #1150 confusion, now explained)" ;; *) no "5d corpus: [$b]" ;; esac

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  tt() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  mk() { mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  CRASH='syntax error|unbound variable|command not found'
  # each mutant lives in its OWN copy of the kit tree (the SUT resolves lib/ and verify-state.sh from its own dir)
  mt() { printf '%s' "$TMP/mt/$1"; }
  for _m in A B C D; do mkdir -p "$TMP/mt/$_m"; cp -r "$HERE/../lib" "$TMP/mt/$_m/lib"; cp "$HERE"/../*.sh "$TMP/mt/$_m/"; rm -f "$TMP/mt/$_m/research-sdd-status.sh"; done
  # A: the first-failure pointer is never appended -> the single-focus STALE loses it (still a STALE line, no crash)
  mk FU-A-POINTER "$SUT" "$(mt A)/research-sdd-status.sh" 's/^    \[ -n "\$_sl_ff" \] && _sl_line=.*$/    :/' \
    && tt FU-A-POINTER 0 0 "$(mt A)/research-sdd-status.sh" --good-has 'first failure: RESEARCH-STATE.md: ' \
         --bad-has '^STALE \| ' --bad-lacks "first failure|$CRASH" -- bash @SUT@ "$single" --next
  # B: the multi-focus branch forgets WHICH focus failed first -> the pointer comes from the wrong scope
  mk FU-B-FIRST "$SUT" "$(mt B)/research-sdd-status.sh" 's/\[ -n "\$_sl_first" \] || _sl_first="\$_sl_b"; //' \
    && tt FU-B-FIRST 0 0 "$(mt B)/research-sdd-status.sh" --good-has 'first failure: RESEARCH-STATE-broken.md' \
         --bad-has '^STALE \| ' --bad-lacks "first failure|$CRASH" -- bash @SUT@ "$multi" --next --all
  # C: the checked suffix is dropped from the Stop hook line -> 5a reads no path; header stays (not a crash)
  mk FU-C-CHECKED "$SUT" "$(mt C)/research-sdd-status.sh" 's/ (checked: \${_chk_abs:-\$target})//' \
    && tt FU-C-CHECKED 0 0 "$(mt C)/research-sdd-status.sh" --good-has '\(checked: ' \
         --bad-has '== research-sdd-status:' --bad-lacks "\(checked: |$CRASH" -- bash @SUT@ "$clean"
  # D: the relative target is printed as given (no cd/pwd) -> 5b must go red
  mk FU-D-ABS "$SUT" "$(mt D)/research-sdd-status.sh" 's/^_chk_abs="\$(cd "\$target" 2>\/dev\/null \&\& pwd)"/_chk_abs=""/' \
    && tt FU-D-ABS 0 0 "$(mt D)/research-sdd-status.sh" --good-has '\(checked: /' \
         --bad-has '\(checked: \.\)' --bad-lacks "$CRASH" -- bash -c 'cd "$1" && bash "$2" .' _ "$clean" @SUT@
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
