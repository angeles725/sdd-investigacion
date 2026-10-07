#!/usr/bin/env bash
# reconcile-issues-dismissed.test.sh — kit issue #1944, reconcile side: a row a PARTIAL marker resolves as DISMISSED
# is resolved like a shipped row (never `untracked`, never an open row of the cross-retro identity pass), and an
# OPEN issue for it is still reported — as `orphaned`, with the marker named as the reason, report only.
# First / middle / last / single positions. Every tooth asserts the failure TEXT it must produce.
#
# Usage: reconcile-issues-dismissed.test.sh                (run the suite)
#        reconcile-issues-dismissed.test.sh --prove-teeth  (run suite + mutation teeth)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../reconcile-issues.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
for _l in retro-status retro-grammar target-paths; do
  [ -f "$HERE/../lib/$_l.sh" ] || { echo "FATAL: helper lib/$_l.sh not found" >&2; exit 2; }
done
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-72s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-72s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
MUT=()
[ "${1:-}" = "--prove-teeth" ] && { . "$HERE/lib/mutant.sh"; }

mkbox() {
  local box="$ROOT/$1" l
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/target-foo/retros" "$box/bin"
  cp "$SUT" "$box/research-sdd/toolbelt/reconcile-issues.sh"
  for l in retro-status retro-grammar target-paths; do cp "$HERE/../lib/$l.sh" "$box/research-sdd/toolbelt/lib/$l.sh"; done
  printf '#!%s\nprintf "%%s\\n" "$1" >> "%s/bin/sleep.log"\n' "$BASH_BIN" "$box" > "$box/bin/sleep"; chmod +x "$box/bin/sleep"
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | target-foo | `%s` |\n' "$box/rh/target-foo" > "$box/research-sdd/TARGETS.md"
  printf '#!/usr/bin/env bash\ncase " $* " in *" auth status "*) exit 0 ;; *" issue list "*) echo "[]"; exit 0 ;; esac\nexit 0\n' > "$box/bin/gh"; chmod +x "$box/bin/gh"
  if [ "${#MUT[@]}" -gt 0 ]; then
    mutant_chain "mut-$1" "$SUT" "$box/research-sdd/toolbelt/reconcile-issues.sh" "${MUT[@]}" >"$ROOT/mutant.log" 2>&1 || { touch "$ROOT/unbuildable"; return 1; }
  fi
  printf '%s' "$box"
}
# mkretro <box> <marker-body> <rows>
mkretro() {
  local f="$1/rh/target-foo/retros/r.md" i
  { printf '<!-- review-status: %s -->\n# retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n' "$2"
    for i in $(seq 1 "$3"); do printf '| %s | Delta number %s with a long enough title | `x.sh` | B%s | feature | LOW |\n' "$i" "$i" "$i"; done; } > "$f"
  printf '%s' "$f"
}
# run <box> <retro> [issue-id...]: the cache lists these ids as OPEN issues of the retro.
run() {
  local box="$1" r="$2" id; shift 2
  : > "$box/cache.txt"; for id in "$@"; do printf 'Source retro: target-foo/retros/r.md · %s\n' "$id" >> "$box/cache.txt"; done
  OUT="$(PATH="$box/bin:$PATH" "$BASH_BIN" "$box/research-sdd/toolbelt/reconcile-issues.sh" --issues-cache "$box/cache.txt" "$r" 2>&1)"; RC=$?
}
untracked_ids() { grep -oE '^untracked: row [0-9]+' <<<"$OUT" | sed 's/.* //' | tr '\n' ' '; }
MSG=""
req()    { [ -z "$MSG" ] || return 0; grep -qE -- "$1" <<<"$OUT" || MSG="MISSING: $1"; }
forbid() { [ -z "$MSG" ] || return 0; ! grep -qE -- "$1" <<<"$OUT" || MSG="UNEXPECTED: $1"; }
uids()   { [ -z "$MSG" ] || return 0; [ "$(untracked_ids)" = "$1" ] || MSG="UNTRACKED IDS: [$(untracked_ids)] != [$1]"; }
verdict() { [ "$RC" = 0 ] || MSG="${MSG:-RC $RC}"; [ -z "$MSG" ] && return 0; echo "$MSG | out=[${OUT:0:300}]"; return 1; }

c_first() {
  local b r; b="$(mkbox "first$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 2, 3; DISMISSED: 1' 4)"; run "$b" "$r"; MSG=""
  uids '4 '; verdict
}
c_middle() {
  local b r; b="$(mkbox "mid$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 1, 4; DISMISSED: 2; DEFERRED: 3' 4)"; run "$b" "$r"; MSG=""
  uids '3 '; verdict
}
c_last() {
  local b r; b="$(mkbox "last$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 1, 2; DISMISSED: 4' 4)"; run "$b" "$r"; MSG=""
  uids '3 '; verdict
}
c_all_resolved() {
  local b r; b="$(mkbox "all$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 2; DISMISSED: 1' 2)"; run "$b" "$r"; MSG=""
  uids ''; forbid '^tracked: row'; req '^no-match'; verdict
}
c_open_issue_reported() {   # an OPEN issue for the dismissed row 2 is still reported (report only), with the marker as the reason
  local b r; b="$(mkbox "orph$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · shipped: 1, 4; DISMISSED: 2' 4)"; run "$b" "$r" 2; MSG=""
  req '^orphaned: issue for row 2 .*dismissed.*propose closing'; uids '3 '; verdict
}

c_malformed() {   # a DISMISSED: list with no usable id: rows not shipped are reported loudly, never listed untracked
  local b r; b="$(mkbox "mal$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: ; DEFERRED: 3' 3)"; run "$b" "$r"; MSG=""
  uids ''; req '^unclassifiable: row 2 of r.md cannot be told shipped, dismissed or open'; req '^unclassifiable: row 3 of r.md'; forbid 'row 1 of r.md'; verdict
}

CHECKS="c_first c_middle c_last c_all_resolved c_open_issue_reported c_malformed"
for c in $CHECKS; do
  if why="$($c good)"; then ok "$c" "()"; else no "$c" "$why"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant must turn its check RED with the expected failure text --"
  tooth() {
    local chk="$1" label="$2" want="$3" why
    shift 3
    MUT=("$@"); rm -f "$ROOT/unbuildable"
    if why="$($chk "mut-$label" 2>&1)"; then no "teeth $label: $chk must fail against the mutant" "check is THEATER"
    elif [ -e "$ROOT/unbuildable" ]; then no "teeth $label: mutant unbuildable" "$(cat "$ROOT/mutant.log")"
    elif ! grep -qF -- "$want" <<<"$why"; then no "teeth $label: $chk failed for the WRONG reason" "wanted [$want] got [${why:0:200}]"
    else ok "teeth $label: mutant breaks $chk with [$want]" "()"; fi
    MUT=()
  }
  tooth c_middle dismissed-open 'UNTRACKED IDS: [2 3 ] != [3 ]' '/RECONCILE_ISSUES_DISMISSED_OPEN/s/= dismissed/= never/'
  tooth c_open_issue_reported orphan-reason-off 'MISSING: ^orphaned: issue for row 2 .*dismissed' '/RECONCILE_ISSUES_DISMISSED_ORPHAN/s/= dismissed/= never-dismissed/'
  tooth c_malformed malformed-silent 'UNTRACKED IDS: [2 3 ] != []' '/RECONCILE_ISSUES_MALFORMED_STATE/s/= malformed/= never-malformed/'
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
