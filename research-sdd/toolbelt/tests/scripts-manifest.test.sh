#!/usr/bin/env bash
# scripts-manifest.test.sh — suite for lib/scripts-manifest.sh (kit issue #1659): the ONE SCRIPTS-MANIFEST
# row parser shared by verify-block.sh and clean-check.sh. Pins: a row is valid only with a 64-hex sha cell,
# header/separator/placeholder rows list nothing, cells resolve against their own manifest's dir
# (`sources/...` is target-relative), list edges (first / middle / last / single row, last row without a
# trailing newline), and typed failures (absent manifest, manifest outside the target, missing args).
#
# Usage: scripts-manifest.test.sh                (run the suite)
#        scripts-manifest.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 = every assertion held · 1 = regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/scripts-manifest.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"
MUT="$(mktemp -d)"
trap 'rm -rf "$TMP" "$MUT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-66s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-66s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth" >&2; exit 2; }
mk_sed() { local l="$1" o="$2"; shift 2; mutant_chain "$l" "$SUT" "$o" "$@" || { fail=$((fail+1)); return 1; }; }
tooth() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

OUT=""; RC=0
# rows TARGET MANIFEST — run the parser from a fresh shell that sources the SUT
rows() { OUT="$("$BASH_BIN" -c '. "$1"; scripts_manifest_rows "$2" "$3"' _ "$SUT" "$1" "$2" 2>&1)"; RC=$?; }
has() { grep -qxF -- "$1" <<<"$OUT"; }

H1=$(printf '%064d' 0)
H2=$(printf 'AB%062d' 0)      # uppercase hex, must come back lowercase
H2L=$(printf 'ab%062d' 0)
HDR='| script | sha256 | run/step | block | executed-on | remote-sha256 | role |'
SEP='|---|---|---|---|---|---|---|'

T="$TMP/target"; D="$T/sources/probes/b1"; mkdir -p "$D"
M="$D/SCRIPTS-MANIFEST.md"

echo "== scripts-manifest.test.sh (SUT: $(basename "$SUT")) =="

# path resolution: bare / ./ / nested / sources-relative cells, each emitted as full path + dir/basename
printf '%s\n%s\n| `a.sh` | %s | x | B1 | h | - | EXECUTED |\n| ./b.sh | %s | x | B1 | h | - | EXECUTED |\n| `sub/c.sh` | %s | x | B1 | h | - | RECIPE |\n| sources/probes/b9/d.sh | %s | x | B9 | h | - | RECIPE |\n' \
  "$HDR" "$SEP" "$H1" "$H1" "$H1" "$H1" > "$M"
rows "$T" "$M"
{ [ "$RC" = 0 ] && has "sources/probes/b1/a.sh	$H1" && has "sources/probes/b1/b.sh	$H1" && has "sources/probes/b1/sub/c.sh	$H1" && has "sources/probes/b1/c.sh	$H1"; } \
  && ok "bare, ./, nested cells resolve against the manifest's own dir (+ dir/basename)" || no "path resolution" "(rc=$RC $OUT)"
{ has "sources/probes/b9/d.sh	$H1" && has "sources/probes/b1/d.sh	$H1"; } \
  && ok "a sources/ cell is target-relative; its basename also lists under the manifest dir" || no "sources/ cell" "(rc=$RC $OUT)"
if grep -q 'sha256' <<<"$OUT" || grep -q 'script' <<<"$OUT"; then no "header / separator rows must list nothing" "($OUT)"; else ok "header and separator rows list nothing"; fi
[ "$(grep -c . <<<"$OUT")" = 8 ] && ok "4 valid rows -> exactly 8 output lines" || no "line count" "($(grep -c . <<<"$OUT") lines: $OUT)"

# the sha cell: uppercase lowered; non-hex, short and long cells reject the row
printf '| `up.sh` | %s | x |\n| `nothex.sh` | %s | x |\n| `short.sh` | %s | x |\n| `long.sh` | %s0 | x |\n| `todo.sh` | TODO | x |\n| `dash.sh` | - | x |\n' \
  "$H2" "$(printf 'zz%062d' 0)" "${H1:0:63}" "$H1" > "$M"
rows "$T" "$M"
has "sources/probes/b1/up.sh	$H2L" && ok "an uppercase digest is returned lowercase" || no "lowercase" "($OUT)"
if grep -qE 'nothex|short|long|todo|dash' <<<"$OUT"; then no "rows with a non-64-hex sha cell must list nothing" "($OUT)"; else ok "non-hex / 63-hex / 65-hex / TODO / - sha cells list nothing"; fi

# list edges: valid row FIRST, MIDDLE, LAST (no trailing newline) and SINGLE
printf '| `first.sh` | %s | x |\n| garbage |\n| `mid.sh` | %s | x |\nprose line\n| `last.sh` | %s | x |' "$H1" "$H1" "$H1" > "$M"
rows "$T" "$M"
{ has "sources/probes/b1/first.sh	$H1" && has "sources/probes/b1/mid.sh	$H1" && has "sources/probes/b1/last.sh	$H1"; } \
  && ok "first, middle and last (unterminated) rows are all parsed" || no "list edges" "($OUT)"
printf '| `only.sh` | %s | x |' "$H1" > "$M"
rows "$T" "$M"
{ [ "$RC" = 0 ] && has "sources/probes/b1/only.sh	$H1" && [ "$(grep -c . <<<"$OUT")" = 2 ]; } && ok "a single-row manifest without a trailing newline is parsed" || no "single row" "(rc=$RC $OUT)"

# trailing-slash target and `//` in the manifest path resolve like the canonical form (find under "$t/" yields `t//...`)
printf '| `only.sh` | %s | x |\n' "$H1" > "$M"
rows "$T//" "${D}//SCRIPTS-MANIFEST.md"
{ [ "$RC" = 0 ] && has "sources/probes/b1/only.sh	$H1"; } && ok "trailing-slash target + // manifest path resolve to the canonical rows" || no "slash normalisation" "(rc=$RC $OUT)"

# absent / empty / no-match stay distinct from failure
printf 'just prose, no table\n' > "$M"
rows "$T" "$M"
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok "no valid row -> rc 0 and empty output (not an error)" || no "no-match" "(rc=$RC $OUT)"
rows "$T" "$D/ABSENT.md"
{ [ "$RC" = 2 ] && grep -q 'cannot read manifest' <<<"$OUT"; } && ok "an absent manifest is rc 2 with a typed message, never an empty list" || no "absent manifest" "(rc=$RC $OUT)"
printf '| `x.sh` | %s | x |\n' "$H1" > "$TMP/outside.md"
rows "$T" "$TMP/outside.md"
{ [ "$RC" = 2 ] && grep -q 'not under target' <<<"$OUT"; } && ok "a manifest outside the target is rc 2" || no "outside target" "(rc=$RC $OUT)"
OUT="$("$BASH_BIN" -c '. "$1"; scripts_manifest_rows "$2"' _ "$SUT" "$T" 2>&1)"; RC=$?
{ [ "$RC" = 2 ] && grep -q 'fewer than 2 arguments' <<<"$OUT"; } && ok "a missing argument is rc 2" || no "missing arg" "(rc=$RC $OUT)"

# kit #1676: sourcing the helper ALWAYS defines the real parser — an inherited `export -f scripts_manifest_rows`
# (a stale or hostile function in the caller's environment) must never win over the file being sourced.
printf '| `only.sh` | %s | x |\n' "$H1" > "$M"
OUT="$("$BASH_BIN" -c 'scripts_manifest_rows() { echo INHERITED-FAKE; }; export -f scripts_manifest_rows; exec bash -c ". \"\$1\"; scripts_manifest_rows \"\$2\" \"\$3\"" _ "$@"' _ "$SUT" "$T" "$M" 2>&1)"; RC=$?
{ [ "$RC" = 0 ] && has "sources/probes/b1/only.sh	$H1" && ! has "INHERITED-FAKE"; } \
  && ok "an inherited exported scripts_manifest_rows never shadows the sourced parser" || no "inherited function shadows the parser" "(rc=$RC $OUT)"
# re-sourcing is harmless: the second definition is identical, the result unchanged
OUT="$("$BASH_BIN" -c '. "$1"; . "$1"; scripts_manifest_rows "$2" "$3"' _ "$SUT" "$T" "$M" 2>&1)"; RC=$?
{ [ "$RC" = 0 ] && has "sources/probes/b1/only.sh	$H1" && [ "$(grep -c . <<<"$OUT")" = 2 ]; } && ok "sourcing the helper twice leaves the parser intact" || no "double source" "(rc=$RC $OUT)"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  # mt LABEL SED-EXPR GOOD-RC BAD-RC [tooth flags...] -- ARGV...   (@SUT@ is substituted)
  mt() {
    local label="$1" expr="$2" grc="$3" brc="$4"; shift 4
    local m; m="$MUT/m-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').sh"
    mk_sed "$label" "$m" "$expr" && tooth "teeth: $label" "$grc" "$brc" "$m" "$@"
  }
  CRASH="$(mutant_crash_re bash py)" || exit 2
  TAB=$'\t'
  # COUNT: prints `n=<occurrences of LINE in the parser output>` then the raw output (so a crash is visible)
  COUNT=("$BASH_BIN" -c '. "$1"; o="$(scripts_manifest_rows "$2" "$3" 2>&1)"; printf "n=%s\n%s\n" "$(printf "%s\n" "$o" | grep -cxF -- "$4")" "$o"' _ @SUT@)
  RAW=("$BASH_BIN" -c '. "$1"; scripts_manifest_rows "$2" "$3"' _ @SUT@)
  # lt LABEL EXPR LINE GOOD-N BAD-N: LINE occurs GOOD-N times in the original output, BAD-N times in the mutant's
  lt() { mt "$1" "$2" 0 0 --good-has "^n=$4\$" --bad-has "^n=$5\$" --bad-lacks "$CRASH" -- "${COUNT[@]}" "$T" "$M" "$3"; }

  printf '| `sub/c.sh` | %s | x |\n| ./b.sh | %s | x |\n| sources/probes/b9/d.sh | %s | x |\n| `up.sh` | %s | x |\n| `short.sh` | %s | x |\n| `nothex.sh` | %s | x |\n' \
    "$H1" "$H1" "$H1" "$H2" "${H1:0:63}" "$(printf 'zz%062d' 0)" > "$M"
  lt "dir-relative resolution dropped" 's|full = (a ~ /^sources\\//) ? a : md "/" a|full = a|' "sources/probes/b1/sub/c.sh${TAB}$H1" 1 0
  lt "sources/ cell no longer target-relative" 's|full = (a ~ /^sources\\//) ? a : md "/" a|full = md "/" a|' "sources/probes/b9/d.sh${TAB}$H1" 1 0
  lt "leading ./ no longer dropped" 's|sub(/^\\.\\//, "", a)|a = a|' "sources/probes/b1/b.sh${TAB}$H1" 2 1
  lt "dir/basename line dropped" '/print md "\/" parts\[n\]/d' "sources/probes/b1/d.sh${TAB}$H1" 1 0
  lt "digest no longer lowercased" 's/tolower(b)/b/g' "sources/probes/b1/up.sh${TAB}$H2L" 2 0
  mt "sha length check removed" '/# SM-ROW$/s/ \&\& length(b) == 64//' 0 0 \
    --good-has '^n=0$' --bad-has '^n=2$' --bad-lacks "$CRASH" -- "${COUNT[@]}" "$T" "$M" "sources/probes/b1/short.sh${TAB}${H1:0:63}"
  mt "sha hex check removed" '/# SM-ROW$/s/ \&\& b ~ \/^\[0-9a-fA-F\]+\$\///' 0 0 \
    --good-has '^n=0$' --bad-has '^n=2$' --bad-lacks "$CRASH" -- "${COUNT[@]}" "$T" "$M" "sources/probes/b1/nothex.sh${TAB}zz$(printf '%062d' 0)"
  mt "unreadable-manifest guard removed" '/cannot read manifest/d' 2 2 \
    --good-has 'cannot read manifest' --bad-lacks 'cannot read manifest' -- "${RAW[@]}" "$T" "$D/ABSENT.md"
  mt "outside-target guard removed" '/not under target/d' 2 0 \
    --good-has 'not under target' --bad-lacks "$CRASH" -- "${RAW[@]}" "$T" "$TMP/outside.md"
  mt "// in the manifest path no longer collapsed" '/# SM-SLASH-MF$/s/.*/    :/' 0 0 \
    --good-has "sources/probes/b1/b.sh${TAB}$H1" --bad-lacks "sources/probes/b1/b.sh${TAB}$H1|$CRASH" -- "${RAW[@]}" "$T" "${D}//SCRIPTS-MANIFEST.md"
  mt "argument guard removed" '/fewer than 2 arguments/d' 2 2 \
    --good-has 'fewer than 2 arguments' --bad-lacks 'fewer than 2 arguments' -- "$BASH_BIN" -c '. "$1"; scripts_manifest_rows "$2"' _ @SUT@ "$T"
  # kit #1676: the old `declare -F` guard, put back (wrapped around the definition), lets an inherited function win
  printf '| `only.sh` | %s | x |\n' "$H1" > "$M"
  if mk_sed "inherited-function guard restored" "$MUT/m-guard.sh" \
      's/^scripts_manifest_rows() {$/if ! declare -F scripts_manifest_rows >\/dev\/null 2>\&1; then scripts_manifest_rows() {/' '$ a fi'; then
    tooth "teeth: inherited-function guard restored" 0 0 "$MUT/m-guard.sh" --good-has "only.sh${TAB}$H1" --good-lacks 'INHERITED-FAKE' \
      --bad-has 'INHERITED-FAKE' -- "$BASH_BIN" -c 'scripts_manifest_rows() { echo INHERITED-FAKE; }; export -f scripts_manifest_rows; exec bash -c ". \"\$1\"; scripts_manifest_rows \"\$2\" \"\$3\"" _ "$@"' _ @SUT@ "$T" "$M"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
