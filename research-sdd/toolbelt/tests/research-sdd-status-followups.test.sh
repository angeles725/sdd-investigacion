#!/usr/bin/env bash
# research-sdd-status-followups.test.sh — two report-shape follow-ups on research-sdd-status.sh.
#
#   kit #1544  `--next` STALE names WHICH file/check failed (first verify-state FAIL), not only "reconcile first".
#   kit #1150  item 1: the `Stop hook` line carries `(checked: <abs path>)` so the same target reached through
#              two different directories no longer reads as two unexplained answers (wired vs absent-settings).
# Most cases moved to the Go tests of `rsdd status show` (stale-*, ff-*, o-hook-* scenarios); this suite keeps the hook-wiring
# resolution through corpus/ (5d) and the LC_ALL=C sort of lib/state-files.sh (9), with the tooth that guards 9.
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

mkdir -p "$TMP/two/corpus"; mk "$TMP/two/corpus/RESEARCH-STATE.md" good
mkdir -p "$TMP/two/.claude"; printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}' > "$TMP/two/.claude/settings.json"
b="$(run "$SUT" "$TMP/two/corpus" | grep 'Stop hook')"
case "$b" in *": absent-settings (checked: $TMP/two/corpus)") ok "5d the same target through corpus/ reads absent-settings and names that path (the #1150 confusion, now explained)" ;; *) no "5d corpus: [$b]" ;; esac

two="$TMP/twobad"; mkdir -p "$two"; mk "$two/RESEARCH-STATE-aaa.md" bad; mk "$two/RESEARCH-STATE-mmm.md" good; mk "$two/RESEARCH-STATE-zzz.md" bad

# 9: list_state_files sorts under LC_ALL=C whatever the caller's locale (a PATH stub records the sort's locale)
mkdir -p "$TMP/sortstub"; printf '#!/usr/bin/env bash\necho "${LC_ALL:-unset}" >> "%s"\nexec /usr/bin/sort "$@"\n' "$TMP/sortlog" > "$TMP/sortstub/sort"; chmod +x "$TMP/sortstub/sort"
: > "$TMP/sortlog"
( export LC_ALL=en_US.UTF-8; PATH="$TMP/sortstub:$PATH"; . "$HERE/../lib/state-files.sh"; list_state_files "$two" >/dev/null ) 2>/dev/null
[ "$(cat "$TMP/sortlog" 2>/dev/null)" = "C" ] && ok "9 list_state_files sorts under LC_ALL=C (first-in-order is locale-independent)" || no "9 sort locale: [$(cat "$TMP/sortlog" 2>/dev/null)]"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_or_count mutant_chain_or_count || exit 2
  tt() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  mk() { mutant_chain_or_count fail "$@" || return 1; }
  # each mutant lives in its OWN copy of the kit tree (the SUT resolves lib/ and verify-state.sh from its own dir)
  mt() { printf '%s' "$TMP/mt/$1"; }
  mkdir -p "$TMP/mt/G"; cp -r "$HERE/../lib" "$TMP/mt/G/lib"; cp "$HERE"/../*.sh "$TMP/mt/G/"; rm -f "$TMP/mt/G/research-sdd-status.sh"
  # G: list_state_files sorts in the caller's locale again (lib mutant) -> the recorded sort locale is no longer C
  mk FU-G-LOCALE "$HERE/../lib/state-files.sh" "$(mt G)/lib/state-files.sh" 's/| LC_ALL=C sort/| sort/' \
    && tt FU-G-LOCALE 0 0 "$(mt G)/lib/state-files.sh" --orig "$HERE/../lib/state-files.sh" --good-has '^C$' --bad-lacks '^C$' \
         -- bash -c ': > "$2"; export LC_ALL=en_US.UTF-8; PATH="$3:$PATH"; . "$1"; list_state_files "$4" >/dev/null; cat "$2"' _ @SUT@ "$TMP/sortlog" "$TMP/sortstub" "$two"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
