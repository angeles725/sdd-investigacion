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

echo "-- #1544 round 2: typed unavailable, root fallback, first-in-sort-order, locale, CDPATH, truncation --"
# mkkit NAME -> a private copy of the kit tree (the SUT resolves lib/ and verify-state.sh from its own dir)
mkkit() { local k="$TMP/kit/$1"; rm -rf "$k"; mkdir -p "$k"; cp -r "$HERE/../lib" "$k/lib"; cp "$HERE"/../*.sh "$k/"; printf '%s' "$k"; }
# stub_vs KIT BODY RC: replace verify-state.sh with a stub that prints BODY (printf format) and exits RC
stub_vs() { printf '#!/usr/bin/env bash\nprintf %s\nexit %s\n' "'$2'" "$3" > "$1/verify-state.sh"; chmod +x "$1/verify-state.sh"; }

k6a="$(mkkit 6a)"; rm -f "$k6a/verify-state.sh"
got="$(run "$k6a/research-sdd-status.sh" "$single" --next)"
case "$got" in "STALE | "*"[first failure: unavailable — verify-state printed no FAIL line (rc=127)]") ok "6a verify-state helper missing -> typed 'unavailable (rc=127)', not an omitted pointer" ;; *) no "6a missing helper: [$got]" ;; esac
k6b="$(mkkit 6b)"; stub_vs "$k6b" '== verify-state: X.md (target: t) ==\n== exit 1 ==\n' 1
got="$(run "$k6b/research-sdd-status.sh" "$single" --next)"
case "$got" in "STALE | "*"[first failure: unavailable — verify-state printed no FAIL line (rc=1)]") ok "6b verify-state exits 1 with no FAIL line -> typed 'unavailable (rc=1)'" ;; *) no "6b no FAIL line: [$got]" ;; esac

rootfb="$TMP/rootfb"; mkdir -p "$rootfb"; mk "$rootfb/RESEARCH-STATE.md" bad; mk "$rootfb/RESEARCH-STATE-good.md" good
got="$(run "$SUT" "$rootfb" --next)"
case "$got" in "STALE | "*"first failure: RESEARCH-STATE.md: envelope investigable_open=0"*) ok "7 stale ROOT next to a clean focus -> corpus-wide fallback names the root file" ;; *) no "7 root fallback: [$got]" ;; esac

two="$TMP/twobad"; mkdir -p "$two"; mk "$two/RESEARCH-STATE-aaa.md" bad; mk "$two/RESEARCH-STATE-mmm.md" good; mk "$two/RESEARCH-STATE-zzz.md" bad
got="$(run "$SUT" "$two" --next --all)"
case "$got" in *"[failing focus: aaa,zzz]"*"first failure: RESEARCH-STATE-aaa.md: "*) ok "8 two failing focuses: pointer names the FIRST in sort order (aaa), not the last" ;; *) no "8 two failing: [$got]" ;; esac

# 9: list_state_files sorts under LC_ALL=C whatever the caller's locale (a PATH stub records the sort's locale)
mkdir -p "$TMP/sortstub"; printf '#!/usr/bin/env bash\necho "${LC_ALL:-unset}" >> "%s"\nexec /usr/bin/sort "$@"\n' "$TMP/sortlog" > "$TMP/sortstub/sort"; chmod +x "$TMP/sortstub/sort"
: > "$TMP/sortlog"
( export LC_ALL=en_US.UTF-8; PATH="$TMP/sortstub:$PATH"; . "$HERE/../lib/state-files.sh"; list_state_files "$two" >/dev/null ) 2>/dev/null
[ "$(cat "$TMP/sortlog" 2>/dev/null)" = "C" ] && ok "9 list_state_files sorts under LC_ALL=C (first-in-order is locale-independent)" || no "9 sort locale: [$(cat "$TMP/sortlog" 2>/dev/null)]"

# 10: an exported CDPATH must not leak into the checked path (cd would print the CDPATH hit and resolve elsewhere)
mkdir -p "$TMP/decoy/clean"
got="$(cd "$TMP" && CDPATH="$TMP/decoy" bash "$SUT" clean 2>/dev/null | grep 'Stop hook')"
[ "$got" = "  Stop hook       : absent-settings (checked: $TMP/clean)" ] && ok "10 CDPATH set + relative target -> (checked:) is the real directory, one line" || no "10 CDPATH: [$got]"

# 11: truncation never splits a multibyte character; 12: a multi-line FAIL ending in ':' carries its value line
k11="$(mkkit 11)"; long="$(printf 'a%.0s' $(seq 1 156))éééééééééé"
stub_vs "$k11" "== verify-state: RESEARCH-STATE.md (target: t) ==\\n   FAIL   $long\\n== exit 1 ==\\n" 1
got="$(LC_ALL=C run "$k11/research-sdd-status.sh" "$single" --next)"
if printf '%s' "$got" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && case "$got" in *"first failure: RESEARCH-STATE.md: aaaa"*"..."\]) true ;; *) false ;; esac; then ok "11 a >160-byte FAIL is truncated on a character boundary (valid UTF-8, ellipsis kept)"; else no "11 truncation: [$got]"; fi
k12="$(mkkit 12)"; stub_vs "$k12" '== verify-state: RESEARCH-STATE.md (target: t) ==\n   FAIL   backlog NOT FULLY PARSEABLE — unknown priority value(s) found:\n          unknown priority value [SES2] — valid: high\n== exit 1 ==\n' 1
got="$(run "$k12/research-sdd-status.sh" "$single" --next)"
case "$got" in *"found: unknown priority value [SES2]"*) ok "12 a FAIL ending in ':' includes its value line" ;; *) no "12 found-value: [$got]" ;; esac

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  tt() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  mk() { mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  CRASH='syntax error|unbound variable|command not found'
  # each mutant lives in its OWN copy of the kit tree (the SUT resolves lib/ and verify-state.sh from its own dir)
  mt() { printf '%s' "$TMP/mt/$1"; }
  for _m in A B C D E F G H I J; do mkdir -p "$TMP/mt/$_m"; cp -r "$HERE/../lib" "$TMP/mt/$_m/lib"; cp "$HERE"/../*.sh "$TMP/mt/$_m/"; rm -f "$TMP/mt/$_m/research-sdd-status.sh"; done
  # A: the first-failure pointer is never appended -> the single-focus STALE loses it (still a STALE line, no crash)
  mk FU-A-POINTER "$SUT" "$(mt A)/research-sdd-status.sh" 's/^    \[ -n "\$_sl_ff" \] && _sl_line=.*$/    :/' \
    && tt FU-A-POINTER 0 0 "$(mt A)/research-sdd-status.sh" --good-has 'first failure: RESEARCH-STATE.md: ' \
         --bad-has '^STALE \| ' --bad-lacks "first failure|$CRASH" -- bash @SUT@ "$single" --next
  # B: the multi-focus branch forgets WHICH focus failed first -> the pointer comes from the wrong scope
  mk FU-B-FIRST "$SUT" "$(mt B)/research-sdd-status.sh" 's/\[ -n "\$_sl_first" \] || _sl_first="\$_sl_b"; /_sl_first="\$_sl_b"; /' \
    && tt FU-B-FIRST 0 0 "$(mt B)/research-sdd-status.sh" --good-has 'first failure: RESEARCH-STATE-aaa.md' \
         --bad-has '^STALE \| ' --bad-lacks "first failure: RESEARCH-STATE-aaa.md|$CRASH" -- bash @SUT@ "$two" --next --all
  # C: the checked suffix is dropped from the Stop hook line -> 5a reads no path; header stays (not a crash)
  mk FU-C-CHECKED "$SUT" "$(mt C)/research-sdd-status.sh" 's/ (checked: \${_chk_abs:-\$target})//' \
    && tt FU-C-CHECKED 0 0 "$(mt C)/research-sdd-status.sh" --good-has '\(checked: ' \
         --bad-has '== research-sdd-status:' --bad-lacks "\(checked: |$CRASH" -- bash @SUT@ "$clean"
  # D: the relative target is printed as given (no cd/pwd) -> 5b must go red
  mk FU-D-ABS "$SUT" "$(mt D)/research-sdd-status.sh" 's/^_chk_abs="\$(CDPATH="" cd -- "\$target" 2>\/dev\/null \&\& pwd)"/_chk_abs=""/' \
    && tt FU-D-ABS 0 0 "$(mt D)/research-sdd-status.sh" --good-has '\(checked: /' \
         --bad-has '\(checked: \.\)' --bad-lacks "$CRASH" -- bash -c 'cd "$1" && bash "$2" .' _ "$clean" @SUT@
  # E (round 2, §7): the typed `unavailable` pointer is dropped -> with verify-state absent the pointer vanishes
  rm -f "$(mt E)/verify-state.sh"
  mk FU-E-UNAVAIL "$SUT" "$(mt E)/research-sdd-status.sh" "s/printf 'unavailable — verify-state printed no FAIL line (rc=%s)' \"\\\$_ff_rc\"/printf ''/" \
    && tt FU-E-UNAVAIL 0 0 "$(mt E)/research-sdd-status.sh" --orig "$k6a/research-sdd-status.sh" --good-has 'first failure: unavailable' \
         --bad-has '^STALE \| ' --bad-lacks "first failure|$CRASH" -- bash @SUT@ "$single" --next
  # F: the corpus-wide fallback is dropped -> a stale ROOT beside a clean focus loses its pointer
  mk FU-F-ROOTFB "$SUT" "$(mt F)/research-sdd-status.sh" 's/else _sl_ff="\$(_first_failure "\$target")"; fi  # STALE-ROOT-FALLBACK/else _sl_ff=""; fi/' \
    && tt FU-F-ROOTFB 0 0 "$(mt F)/research-sdd-status.sh" --good-has 'first failure: RESEARCH-STATE.md' \
         --bad-has '^STALE \| ' --bad-lacks "first failure|$CRASH" -- bash @SUT@ "$rootfb" --next
  # G: list_state_files sorts in the caller's locale again (lib mutant) -> the recorded sort locale is no longer C
  mk FU-G-LOCALE "$HERE/../lib/state-files.sh" "$(mt G)/lib/state-files.sh" 's/| LC_ALL=C sort/| sort/' \
    && tt FU-G-LOCALE 0 0 "$(mt G)/lib/state-files.sh" --orig "$HERE/../lib/state-files.sh" --good-has '^C$' --bad-lacks '^C$' \
         -- bash -c ': > "$2"; export LC_ALL=en_US.UTF-8; PATH="$3:$PATH"; . "$1"; list_state_files "$4" >/dev/null; cat "$2"' _ @SUT@ "$TMP/sortlog" "$TMP/sortstub" "$two"
  # H: truncation backs off no continuation bytes -> a multibyte char is split (the good line ends `a...]`)
  mk FU-H-MBYTE "$SUT" "$(mt H)/research-sdd-status.sh" 's/while (n>0 \&\& substr(c,n+1,1) ~ \/\[\\200-\\277\]\/) n--; //' \
    && { cp "$k11/verify-state.sh" "$(mt H)/verify-state.sh"
         tt FU-H-MBYTE 0 0 "$(mt H)/research-sdd-status.sh" --orig "$k11/research-sdd-status.sh" --good-has 'a\.\.\.\]$' \
           --bad-has '^STALE \| ' --bad-lacks "a\.\.\.\]$|$CRASH" -- env LC_ALL=C bash @SUT@ "$single" --next; }
  # I: the value line after a FAIL ending in ':' is dropped
  mk FU-I-FOUND "$SUT" "$(mt I)/research-sdd-status.sh" 's/if (c ~ \/:\$\/) { pend=1; next } //' \
    && { cp "$k12/verify-state.sh" "$(mt I)/verify-state.sh"
         tt FU-I-FOUND 0 0 "$(mt I)/research-sdd-status.sh" --orig "$k12/research-sdd-status.sh" --good-has 'SES2' \
           --bad-has '^STALE \| ' --bad-lacks "SES2|$CRASH" -- bash @SUT@ "$single" --next; }
  # J: CDPATH leaks into the checked path (plain cd) -> the decoy directory is reported
  mk FU-J-CDPATH "$SUT" "$(mt J)/research-sdd-status.sh" 's/CDPATH="" cd -- /cd -- /' \
    && tt FU-J-CDPATH 0 0 "$(mt J)/research-sdd-status.sh" --good-lacks 'decoy' --bad-has 'decoy' --bad-lacks "$CRASH" \
         -- bash -c 'cd "$1" && CDPATH="$3" bash "$2" clean 2>/dev/null | grep "Stop hook"' _ "$TMP" @SUT@ "$TMP/decoy"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
