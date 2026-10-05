#!/usr/bin/env bash
# state-files.test.sh — unit harness for lib/state-files.sh (kit issue #1818).
#
# list_state_files (enumeration) and resolve_state_file (pick ONE state file: root beats focus,
# shallowest first, typed absent / ambiguous / usage states).
#
# Usage: state-files.test.sh                (run the suite)
#        state-files.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 = all assertions held · 1 = regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="${STATE_FILES_LIB:-$HERE/../lib/state-files.sh}"
[ -f "$HELPER" ] || { echo "FATAL: helper under test not found: $HELPER" >&2; exit 2; }
# shellcheck source=../lib/state-files.sh
. "$HELPER"
declare -F list_state_files >/dev/null 2>&1 || { echo "FATAL: list_state_files not defined" >&2; exit 2; }
declare -F resolve_state_file >/dev/null 2>&1 || { echo "FATAL: resolve_state_file not defined" >&2; exit 2; }

pass=0; fail=0
ok() { printf '  PASS  %-62s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-62s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/state-files-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mk() { # <name> <relative file>...  -> fixture dir $ROOT/<name>
  local n="$1" f; shift
  mkdir -p "$ROOT/$n"
  for f in "$@"; do mkdir -p "$ROOT/$n/$(dirname "$f")"; : >"$ROOT/$n/$f"; done
}

# check <label> <fixture> <want-rc> <want-path-relative-or-empty> [resolve args after the dir...]
check() {
  local label="$1" fx="$2" wrc="$3" wpath="$4" out rc want=""; shift 4
  out="$(resolve_state_file "$ROOT/$fx" "$@" 2>/dev/null)"; rc=$?
  [ -n "$wpath" ] && want="$ROOT/$fx/$wpath"
  if [ "$rc" = "$wrc" ] && [ "$out" = "$want" ]; then ok "$label"; else no "$label" "rc=$rc want=$wrc out='$out' want='$want'"; fi
}

run_suite() {
echo "== state-files.test.sh (SUT: lib/$(basename "$HELPER")) =="

mk root-only RESEARCH-STATE.md
check "1 root only" root-only 0 RESEARCH-STATE.md

mk focus-only RESEARCH-STATE-auth.md
check "2 single focus only" focus-only 0 RESEARCH-STATE-auth.md

mk both RESEARCH-STATE-auth.md RESEARCH-STATE.md
check "3 flat root + focus: ROOT wins (lexical sort would pick the focus)" both 0 RESEARCH-STATE.md

mk both-many RESEARCH-STATE-aaa.md RESEARCH-STATE-mmm.md RESEARCH-STATE.md RESEARCH-STATE-zzz.md
check "3b root + 3 focuses (focus before/after the root alphabetically)" both-many 0 RESEARCH-STATE.md

mk multi-noroot RESEARCH-STATE-zeta.md RESEARCH-STATE-alpha.md
check "4 flat multi-focus without root: first path, deterministic" multi-noroot 0 RESEARCH-STATE-alpha.md

mk nested corpus/RESEARCH-STATE-arch.md corpus/RESEARCH-STATE.md
check "5 nested corpus/: root beats focus" nested 0 corpus/RESEARCH-STATE.md

mk shallow-focus-deep-root RESEARCH-STATE-top.md corpus/RESEARCH-STATE.md
check "6 shallowest wins: top-level focus beats a deeper root" shallow-focus-deep-root 0 RESEARCH-STATE-top.md

mk deep-limit a/b/c/RESEARCH-STATE.md
check "7 beyond maxdepth 3 is absent" deep-limit 1 ""

mk empty-dir keep.txt
check "8 absent: no state files -> rc 1, no output" empty-dir 1 ""

mk templ RESEARCH-STATE.template.md
check "9 *.template.md alone is absent" templ 1 ""

mk templ2 RESEARCH-STATE.template.md RESEARCH-STATE-x.md
check "9b template never wins over a real file" templ2 0 RESEARCH-STATE-x.md

mk gitdir .git/RESEARCH-STATE.md
check "10 .git content excluded" gitdir 1 ""

check "11 --focus selects the focus file even when a root exists" both 0 RESEARCH-STATE-auth.md --focus auth
check "11b --focus unknown slug -> absent" both 1 "" --focus nope
mk fcs RESEARCH-STATE-ab.md RESEARCH-STATE-abc.md
check "11d --focus ab does not match abc (exact name)" fcs 0 RESEARCH-STATE-ab.md --focus ab

# usage states
resolve_state_file "$ROOT/root-only" --focus "" >/dev/null 2>&1; [ $? = 3 ] && ok "12 empty --focus slug -> rc 3" || no "12 empty --focus slug -> rc 3"
resolve_state_file "$ROOT/does-not-exist" >/dev/null 2>&1; [ $? = 3 ] && ok "12b missing dir -> rc 3 (not absent)" || no "12b missing dir -> rc 3 (not absent)"
resolve_state_file >/dev/null 2>&1; [ $? = 3 ] && ok "12c no args -> rc 3" || no "12c no args -> rc 3"
resolve_state_file "$ROOT/root-only" --bogus >/dev/null 2>&1; [ $? = 3 ] && ok "12d unknown arg -> rc 3" || no "12d unknown arg -> rc 3"
# ambiguity: equal rank in DIFFERENT directories (split layout) — rc 2 is typed, stdout carries the
# C-locale-first pick (callers that accept a split layout use it; others refuse on rc 2)
mk amb2 a/RESEARCH-STATE.md b/RESEARCH-STATE.md
check "13 two roots, different dirs -> rc 2 + first pick on stdout" amb2 2 a/RESEARCH-STATE.md

# list edges: the odd directory in LAST, FIRST and MIDDLE position of the equal-rank set
mk amb-last a/RESEARCH-STATE-x.md a/RESEARCH-STATE-y.md b/RESEARCH-STATE-z.md
check "14 ambiguity: odd dir LAST in the ranked set" amb-last 2 a/RESEARCH-STATE-x.md
mk amb-first a/RESEARCH-STATE-a.md b/RESEARCH-STATE-b.md b/RESEARCH-STATE-c.md
check "14b ambiguity: odd dir FIRST" amb-first 2 a/RESEARCH-STATE-a.md
mk amb-mid a/RESEARCH-STATE-a.md b/RESEARCH-STATE-b.md c/RESEARCH-STATE-c.md
check "14c ambiguity: three dirs" amb-mid 2 a/RESEARCH-STATE-a.md
mk amb-single a/RESEARCH-STATE-a.md
check "14d single candidate in a subdir: no ambiguity" amb-single 0 a/RESEARCH-STATE-a.md

# a lower-ranked competitor in another directory is NOT ambiguity (rank decides)
mk rank-wins RESEARCH-STATE.md sub/RESEARCH-STATE.md sub/RESEARCH-STATE-q.md
check "15 shallower root beats a deeper pair in another dir" rank-wins 0 RESEARCH-STATE.md
mk rank-focus a/RESEARCH-STATE.md b/RESEARCH-STATE-x.md
check "15b same-depth root in one dir beats focus in another (no ambiguity)" rank-focus 0 a/RESEARCH-STATE.md

# focus ambiguity: same slug in two same-depth dirs
mk fo-amb a/RESEARCH-STATE-k.md b/RESEARCH-STATE-k.md
check "16 --focus slug present in two dirs at one depth -> rc 2 + first pick" fo-amb 2 a/RESEARCH-STATE-k.md --focus k

# -H follows a symlinked target dir (verify-state.sh semantics); without -H find does not descend
mkdir -p "$ROOT/real" && : >"$ROOT/real/RESEARCH-STATE.md" && ln -s "$ROOT/real" "$ROOT/link"
out="$(resolve_state_file -H "$ROOT/link" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "$ROOT/link/RESEARCH-STATE.md" ] && ok "17 -H resolves through a symlinked dir" || no "17 -H resolves through a symlinked dir" "rc=$rc out='$out'"
resolve_state_file "$ROOT/link" >/dev/null 2>&1; [ $? = 1 ] && ok "17b without -H a symlinked dir is not traversed (rc 1)" || no "17b without -H a symlinked dir is not traversed"
out="$(resolve_state_file -H "$ROOT/link" --focus x 2>/dev/null)"; [ "$?" = 1 ] && ok "17c -H with --focus absent -> rc 1" || no "17c -H with --focus absent"

# trailing slash on <dir>
out="$(resolve_state_file "$ROOT/both/" 2>/dev/null)"
[ "${out##*/}" = "RESEARCH-STATE.md" ] && ok "18 trailing-slash dir still ranks the root first" || no "18 trailing-slash dir" "out='$out'"

# list_state_files still enumerates (regression guard for the pre-existing function)
n="$(list_state_files "$ROOT/both-many" | wc -l | tr -d ' ')"
[ "$n" = 4 ] && ok "19 list_state_files unchanged: 4 files" || no "19 list_state_files unchanged" "n=$n"
}

run_suite

# ---- MUTATION TEETH (--prove-teeth) -------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  typeset -f mutant_chain >/dev/null 2>&1 || { echo "FATAL: lib/mutant.sh did not define mutant_chain" >&2; exit 2; }
  echo ""
  echo "== mutation controls =="
  t_pass=0; t_fail=0
  tok() { printf '  TOOTH-PASS  %s\n' "$1"; t_pass=$((t_pass+1)); }
  tno() { printf '  TOOTH-FAIL  %s\n' "$1"; t_fail=$((t_fail+1)); }

  # Re-run this very suite against a mutated COPY of the helper; it must go red.
  tooth() { # <label> <sed-expr>
    local label="$1" expr="$2" mf out
    mf="$(mktemp "${TMPDIR:-/tmp}/state-files-mut.XXXXXX.sh")"
    if ! mutant_chain "$label" "$HELPER" "$mf" "$expr"; then
      tno "$label: mutant refused by lib/mutant.sh (TOOTH NOT BUILT)"; rm -f "$mf"; return
    fi
    out="$(STATE_FILES_LIB="$mf" bash "$HERE/state-files.test.sh" 2>&1)"
    if <<<"$out" grep -q '^  FAIL  '; then tok "$label: suite goes red"; else tno "$label: suite stayed GREEN (no teeth)"; fi
    rm -f "$mf"
  }
  tooth "TOOTH-1 lexical sort (root-beats-focus + depth dropped)" 's/-k1,1n -k2,2n -k3,3/-k3,3/'
  tooth "TOOTH-2 depth ignored (root-first only)" 's/-k1,1n -k2,2n -k3,3/-k2,2n -k3,3/'
  tooth "TOOTH-3 root preference ignored (depth then lexical)" 's/-k1,1n -k2,2n -k3,3/-k1,1n -k3,3/'
  tooth "TOOTH-4 ambiguity silenced" 's/if \[ "\$amb" = 1 \]; then printf/if [ "$amb" = 9 ]; then printf/'
  tooth "TOOTH-5 -H ignored" 's/follow="-H"; shift; fi/follow=""; shift; fi/'
  tooth "TOOTH-6 absent reported as ambiguous-style rc 3" 's/\[ -n "\$found" \] || return 1/[ -n "$found" ] || return 3/'
  tooth "TOOTH-7 --focus pattern widened to all state files" 's/pat="RESEARCH-STATE-\${slug}.md"/pat="RESEARCH-STATE*.md"/'
  tooth "TOOTH-8 template exclusion dropped (resolver only)" "s/-not -name '\*.template.md' -not -path/-not -path/"

  echo ""
  echo "  teeth passed: $t_pass  teeth failed: $t_fail"
  [ "$t_fail" -eq 0 ] || fail=$((fail+1))
fi

echo ""
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
