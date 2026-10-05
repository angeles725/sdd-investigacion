#!/usr/bin/env bash
# mutant-syntax-export-lint.test.sh — no suite may EXPORT MUTANT_SYNTAX (kit issue #1814).
#
# WHY. tests/lib/mutant.sh reads MUTANT_SYNTAX from the environment on every call and refuses a
# syntax-broken mutant only while it is `bash` (the default). A suite that does
# `export MUTANT_SYNTAX=none` for its python/markdown mutants keeps that value for every LATER bash
# mutant in the same process, so a broken bash mutant is built without the `bash -n` refusal, goes red
# for the wrong reason and still counts as a bite (the vacuous-tooth class CLAUDE.md §4 forbids).
# The rule: scope it per call (`MUTANT_SYNTAX=none mutant_chain ...`), never export it.
#
# SCOPE / DEVIATION. #1814 asks for a report-only `--require-teeth` line in run-all.sh; run-all.sh was
# owned by another writer in this work unit, so the same detection lives here as a normal suite that
# the default gate already runs. Suites that still export it for a WHOLE-FILE single kind of mutant
# (every mutant python or markdown, no bash mutant after the export) are listed in WAIVED below as
# visible debt: a waiver for a suite that no longer exports is STALE and fails, so the list can only
# shrink. Remove an entry in the same change that scopes that suite's calls.
#
# Detected forms, per STATEMENT (a line is split on ; & |; a `#` starts a comment only at line start or after
# whitespace, so `${#a[@]}` does not cut the line):
#   export [-opts] [NAME...] MUTANT_SYNTAX[=v], quoted or not (`export -n` / `export -p` are skipped: they
#   un-export / only print) · MUTANT_SYNTAX=v; export MUTANT_SYNTAX · declare|typeset|local with an -x
#   option cluster (also split as `-g -x`) and MUTANT_SYNTAX among the names.
# Scanned: tests/*.test.sh, tests/lib/*.sh and ../../install/tests/*.test.sh (this suite excluded).
# Not detected (stated, not claimed): `set -a` followed by an assignment; `env`/`eval`/`printf -v`
# indirection; a `#` that follows whitespace inside a quoted string; a name built from variables.
#
# Env seams: LINT_SCAN_DIR (default: this directory) · LINT_WAIVE=0 (ignore WAIVED, used by the planted-
# export controls).
# Usage: mutant-syntax-export-lint.test.sh [--prove-teeth]   Exit: 0 held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="${BASH_SOURCE[0]##*/}"
SCAN_DIR="${LINT_SCAN_DIR:-$HERE}"

# SENTINEL-EXPORT-RE: the detector; the teeth neuter this one line.
LINT_RE="(^|[^[:alnum:]_])export[[:space:]]+([^;]*[[:space:]\"'])?MUTANT_SYNTAX([^[:alnum:]_]|\$)"
LINT_RE_DECL="(^|[^[:alnum:]_])(declare|typeset|local)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*x[a-zA-Z]*[[:space:]]+([^;[:space:]]+[[:space:]]+)*[\"']?MUTANT_SYNTAX([^[:alnum:]_]|\$)"

# Suites that still export it (single-kind mutants for the whole file). Debt, not a pass.
WAIVED="
bog-nav
capa
corroborate-firmware
corroborate-ghidra
corroborate-ifc
detonate-exec
floss
kaitai
model-tiers-doc
niagara-security-audit
profile-invariants
px-render
qnx6-read
remote-powershell-doc
rendered-headings
skill-invariants
station-modules
template-heading-literal
templates
trace-exec
unblob
wall-protocol-doctrine
"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# lint_files FILE... -> prints "<suite>:<line>: <text>" per exporting statement; rc 2 = nothing scanned
# (never a silent zero, CLAUDE.md §7). This suite and its mutants (*export-lint*) are skipped: they quote the forms.
lint_files() {
  local f n=0 name
  for f in "$@"; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *export-lint*) continue ;; esac
    n=$((n+1)); name="${f##*/}"; name="${name%.test.sh}"; name="${name%.sh}"
    awk -v re="$LINT_RE" -v dre="$LINT_RE_DECL" -v name="$name" '
      { code=$0
        if (match(code, /(^|[ \t])#/)) code=substr(code, 1, RSTART-1)
        k=split(code, st, /[;&|]/)
        for (i=1; i<=k; i++) {
          if ((st[i] ~ re && st[i] !~ /export[ \t]+-[a-zA-Z]*[np]/) || st[i] ~ dre) { printf "%s:%d: %s\n", name, FNR, $0; break }
        }
      }
    ' "$f"
  done
  [ "$n" -gt 0 ] || return 2
}
# lint_dir DIR: DIR/*.test.sh + DIR/lib/*.sh; the default scan also covers the install suites.
lint_dir() {
  local d="$1"
  [ -d "$d" ] || return 2
  if [ "$d" = "$HERE" ] && [ -z "${LINT_SCAN_DIR:-}" ]; then
    lint_files "$d"/*.test.sh "$d"/lib/*.sh "$d"/../../install/tests/*.test.sh
  else
    lint_files "$d"/*.test.sh "$d"/lib/*.sh
  fi
}
# SENTINEL-WAIVE-MATCH: the waiver lookup; the teeth flip its result.
is_waived() { case $'\n'"$WAIVE_LIST" in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

echo "== mutant-syntax-export-lint.test.sh =="

# ---- 1. the real suites: no un-waived export, no stale waiver
if [ "${LINT_WAIVE:-1}" = 0 ]; then WAIVE_LIST=""; else WAIVE_LIST="$WAIVED"; fi
hits="$(lint_dir "$SCAN_DIR")"; lrc=$?
if [ "$lrc" -ne 0 ]; then
  no "1 scan: no suite found under $SCAN_DIR (absent/empty input, rc=$lrc)"
else
  bad_hits=""; seen=" "
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    s="${line%%:*}"; seen="$seen$s "
    is_waived "$s" || bad_hits="$bad_hits$line"$'\n'
  done <<<"$hits"
  if [ -z "$bad_hits" ]; then
    ok "1 no suite exports MUTANT_SYNTAX outside the waiver list"
  else
    no "1 exported MUTANT_SYNTAX (scope it per call: MUTANT_SYNTAX=none mutant_chain ...):"
    printf '%s' "$bad_hits" | sed 's/^/        /'
  fi
  stale=""
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [[ "$seen" == *" $w "* ]] || stale="$stale $w"
  done <<<"$WAIVE_LIST"
  if [ -z "$stale" ]; then ok "2 every waiver still matches an exporting suite (none stale)"
  else no "2 stale waiver(s) -- the suite no longer exports; delete the entry:$stale"; fi
fi

# ---- 3. the detector itself, on planted files (red/green on both sides, all forms)
PLANT="$(mktemp -d)"; trap 'rm -rf "$PLANT"' EXIT
mkp() { printf '%s\n' "$2" > "$PLANT/$1.test.sh"; }
mkp clean       'MUTANT_SYNTAX=none mutant_chain a b c d'
mkp comment     '# do not export MUTANT_SYNTAX=none here'
mkp trailing    'x=1  # export MUTANT_SYNTAX=none'
mkp plain       '  export MUTANT_SYNTAX=none   # python mutant'
mkp bare        'export MUTANT_SYNTAX'
mkp semi        'MUTANT_SYNTAX=none; export MUTANT_SYNTAX'
mkp chained     'n=0; export MUTANT_SYNTAX=none'
mkp declx       'declare -x MUTANT_SYNTAX=none'
mkp other       'export MUTANT_SYNTAX_EXTRA=1'
mkp unexport    'export -n MUTANT_SYNTAX'
mkp declr       'declare -r MUTANT_SYNTAX=none'
mkp typex       'typeset -x MUTANT_SYNTAX=none'
mkp declrx      'declare -rx MUTANT_SYNTAX=none'
mkp unexport2   'export -n X; export MUTANT_SYNTAX=none'
mkp lenhash     'n=${#a[@]}; export MUTANT_SYNTAX=none'
mkp quoted      'export "MUTANT_SYNTAX=none"'
mkp declnames   'declare -x FOO MUTANT_SYNTAX'
mkp declgx      'declare -g -x MUTANT_SYNTAX'
mkp localx      'local -x MUTANT_SYNTAX=none'
mkp useval      'export FOO="$MUTANT_SYNTAX"'
mkp exportp     'export -p MUTANT_SYNTAX'
mkp commentws   'x=1 # export MUTANT_SYNTAX=none'
mkp_hits="$(lint_dir "$PLANT")"
for s in plain bare semi chained declx typex declrx unexport2 lenhash quoted declnames declgx localx; do
  if grep -q "^$s:1:" <<<"$mkp_hits"; then ok "3 detector flags the '$s' export form"
  else no "3 detector missed the '$s' export form (hits=[$mkp_hits])"; fi
done
for s in clean comment trailing other unexport declr useval exportp commentws; do
  if grep -q "^$s:" <<<"$mkp_hits"; then no "3 detector false-positive on '$s' (hits=[$mkp_hits])"
  else ok "3 detector ignores '$s' (scoped call / comment / other variable)"; fi
done

# ---- 4. absent / empty input is a typed failure, not a clean zero
lint_dir "$PLANT/does-not-exist" >/dev/null 2>&1; r_abs=$?
EMPTYD="$(mktemp -d)"; lint_dir "$EMPTYD" >/dev/null 2>&1; r_emp=$?; rmdir "$EMPTYD"
if [ "$r_abs" -eq 2 ] && [ "$r_emp" -eq 2 ]; then ok "4 absent and empty scan dirs both return rc 2 (never a silent zero)"
else no "4 expected rc 2 for absent/empty dirs (absent=$r_abs empty=$r_emp)"; fi

# ---- 5. end to end: the real suite run against a planted export, waivers off, must fail
if [ -n "${LINT_NESTED:-}" ]; then :   # the inner run of check 5 must not recurse
elif LINT_NESTED=1 LINT_SCAN_DIR="$PLANT" LINT_WAIVE=0 bash "$HERE/$SELF" >/dev/null 2>&1; r_plant=$?; [ "$r_plant" -eq 1 ]; then ok "5 suite exits 1 on a directory containing an export (waivers off)"
else no "5 expected exit 1 on a planted export, got rc=${r_plant:-?}"; fi

# ==========================================================================
# TEETH (--prove-teeth only): neuter the detector; the planted-export controls must go red
# ==========================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null || { echo "FATAL: lib/mutant.sh did not define mutant_chain" >&2; exit 2; }
  MT="$(mktemp -d)"; mutant_cleanup_register "$MT"
  echo "-- teeth: detector regex that never matches must make the planted-export controls fail --"
  if mutant_chain "teeth: never-match" "$HERE/$SELF" "$MT/export-lint.MUT.test.sh" \
       "/SENTINEL-EXPORT-RE/{n;s/^LINT_RE=.*/LINT_RE='(^\$)NEVER(\$)'/}"; then
    mout="$(cd "$MT" && LINT_SCAN_DIR="$PLANT" LINT_WAIVE=0 bash "$MT/export-lint.MUT.test.sh" 2>&1)"; mrc=$?
    if [ "$mrc" -ne 0 ] && grep -q "^  FAIL  3 detector missed the 'plain'" <<<"$mout"; then
      ok "teeth never-match detector: planted-export controls (3, 5) go red"
    else
      no "teeth never-match detector: mutant stayed green (THEATER) rc=$mrc"
    fi
  else
    no "teeth never-match: could not build mutant (sentinel/regex line not found, or refused by lib/mutant.sh)"
  fi
  echo "-- teeth: a waiver list that silently covers everything must be caught by the stale-waiver check --"
  if mutant_chain "teeth: waive-all" "$HERE/$SELF" "$MT/export-lint.MUT2.test.sh" \
       's/^bog-nav$/bog-nav\nnot-a-suite-at-all/'; then
    mout2="$(cd "$MT" && LINT_SCAN_DIR="$HERE" bash "$MT/export-lint.MUT2.test.sh" 2>&1)"; mrc2=$?
    if [ "$mrc2" -ne 0 ] && grep -q '^  FAIL  2 stale waiver' <<<"$mout2"; then
      ok "teeth stale-waiver: a waiver naming a non-exporting suite fails check 2"
    else
      no "teeth stale-waiver: mutant stayed green (THEATER) rc=$mrc2"
    fi
  else
    no "teeth stale-waiver: could not build mutant (waiver entry not found, or refused by lib/mutant.sh)"
  fi
  echo "-- teeth: a waiver lookup that waives everything must let a planted un-waived export through (check 1 red) --"
  orig_out="$(LINT_NESTED=1 LINT_SCAN_DIR="$PLANT" LINT_WAIVE=0 bash "$HERE/$SELF" 2>&1)"
  if mutant_chain "teeth: waive-everything" "$HERE/$SELF" "$MT/export-lint.MUT3.test.sh" \
       '/^is_waived()/s/return 1; }/return 0; }/'; then
    mout3="$(cd "$MT" && LINT_NESTED=1 LINT_SCAN_DIR="$PLANT" LINT_WAIVE=0 bash "$MT/export-lint.MUT3.test.sh" 2>&1)"
    if grep -q '^  FAIL  1 exported' <<<"$orig_out" && ! grep -q '^  FAIL  1 exported' <<<"$mout3"; then
      ok "teeth waive-everything: the original flags the planted export, the mutant waves it through -> check 1 pins is_waived"
    else
      no "teeth waive-everything: check 1 does not depend on the waiver lookup (THEATER)"
    fi
  else
    no "teeth waive-everything: could not build mutant (is_waived sentinel not found, or refused by lib/mutant.sh)"
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$pass" -gt 0 ] || { echo "FATAL: zero tests executed" >&2; exit 2; }
[ "$fail" -eq 0 ] || exit 1
