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
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into the sandbox toolbelt
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
[ -f "$HERE/../lib/rsdd-exec.sh" ] || { echo "FATAL: helper lib/rsdd-exec.sh not found" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# The shim runs the Go command: the caller's RSDD_BIN, else one build into the temp dir (degraded, never a pass,
# without go). The behaviour these cases pin lives in internal/retro/reconcile (differential vs the frozen script).
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$ROOT/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  RSDD_BIN="$ROOT/rsdd"
fi
export RSDD_BIN
pass=0; fail=0
ok() { printf '  PASS  %-72s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-72s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
MUT=()
[ "${1:-}" = "--prove-teeth" ] && { . "$HERE/lib/mutant.sh"; }

mkbox() {
  local box="$ROOT/$1"
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/target-foo/retros" "$box/bin"
  cp "$SUT" "$box/research-sdd/toolbelt/reconcile-issues.sh"
  rsdd_stage_libs "$box/research-sdd/toolbelt"
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

c_malformed_orphan() {   # an OPEN issue for a row under a malformed DISMISSED list: reported, "cannot tell", NO close proposal
  local b r; b="$(mkbox "mo$1")" || return 1; r="$(mkretro "$b" 'applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: ; DEFERRED: 3' 3)"; run "$b" "$r" 2; MSG=""
  req '^orphaned: issue for row 2 is no longer open in r.md — marker DISMISSED list malformed; cannot tell'; forbid 'propose closing'; verdict
}

CHECKS="c_first c_middle c_last c_all_resolved c_open_issue_reported c_malformed c_malformed_orphan"
for c in $CHECKS; do
  if why="$($c good)"; then ok "$c" "()"; else no "$c" "$why"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: reconcile-issues.sh is an rsdd_exec shim; the marker mutation controls moved to Go --"
  # The bash-body controls (RECONCILE_ISSUES_DISMISSED_OPEN / DISMISSED_ORPHAN / MALFORMED_STATE / MALFORMED_ORPHAN)
  # mutated a bash body that is gone. The rule each pinned is now pinned in internal/retro/reconcile (differential
  # against the frozen script, goldens replayed under nodiff); a typed SKIP names the Go case that holds it.
  printf '  SKIP  teeth dismissed-open (c_middle)                 -> marker/partial-dismissed-list, marker/dismissed-wins-over-partial\n'
  printf '  SKIP  teeth orphan-reason-off (c_open_issue_reported) -> marker/partial-shipped-list-orphaned-reason, matrix/*\n'
  printf '  SKIP  teeth malformed-silent (c_malformed)            -> marker/partial-dismissed-malformed\n'
  printf '  SKIP  teeth malformed-orphan-off (c_malformed_orphan) -> marker/partial-dismissed-malformed, core/orphaned-*\n'
  # What the shim still owns: handing the arguments to the Go command. A shim that drops "$@" must turn the cases
  # red (the command, --toolbelt and self-dir teeth live in reconcile-issues.test.sh).
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
  tooth c_open_issue_reported shim-drops-args 'MISSING: ^orphaned: issue for row 2 ' 's/ "\$@"$//'
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
