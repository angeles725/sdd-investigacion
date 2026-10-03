#!/usr/bin/env bash
# Test suite for n4-type-catalog.sh / n4_type_catalog.py (n4-type-catalog.v1), kit issue #1283.
# TDD: written before the implementation; RED executed against a stub SUT first.
#
# Usage: n4-type-catalog.test.sh [--prove-teeth]
#
# Fixtures are small SYNTHETIC Java sources under tests/fixtures/n4-type-catalog/ (read-only inputs):
#   doc/pkg/   javadoc-style source (Flags.A | Flags.B), plus a type with an unknown flag token and a
#              type with no Slotomatic declarations
#   cfr/pkg/   the SAME BFoo as decompiler output (numeric flags, `BFoo.newProperty((int)9, (BValue)...)`)
# Anything the suite writes goes to a temp root, never into the tree (kit issue #1156, CLAUDE.md §8).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../n4-type-catalog.sh"
PY="$HERE/../n4_type_catalog.py"
FX="$HERE/fixtures/n4-type-catalog"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
echo "== n4-type-catalog.test.sh =="

# run CMD... → sets OUT (stdout) ERR (stderr) RC
run() {
  OUT="$("$@" 2>"$ROOT/err")"; RC=$?
  ERR="$(cat "$ROOT/err")"
}
# has / lacks LABEL STRING PATTERN (grep -E)
has()   { if grep -qE -- "$3" <<<"$2"; then ok "$1"; else no "$1 :: /$3/ not in [$2]"; fi; }
lacks() { if grep -qE -- "$3" <<<"$2"; then no "$1 :: /$3/ unexpectedly in [$2]"; else ok "$1"; fi; }
rc_is() { if [ "$RC" = "$2" ]; then ok "$1"; else no "$1 :: rc=$RC want $2 (err: $ERR)"; fi; }

# --- T1 build over doc fixtures: counts, exit 0 -------------------------------------------------------
run "$SUT" build "$FX/doc" --out "$ROOT/doc.json"
rc_is "T1 build doc exits 0" 0
has "T1 summary counts (2 types, 4 properties, 2 actions, 1 topic)" "$OUT" 'types: 2 +properties: 4 +actions: 2 +topics: 1'
has "T1 summary names the files it scanned (anti-silent-zero)" "$OUT" 'java-files: 3'
[ -s "$ROOT/doc.json" ] && ok "T1 catalog written" || no "T1 catalog not written"

# --- T2 flag decoding ---------------------------------------------------------------------------------
run "$SUT" show "$ROOT/doc.json" demo.pkg.BFoo
rc_is "T2 show exits 0" 0
has "T2 extends line" "$OUT" 'demo\.pkg\.BFoo +extends BComponent'
has "T2 in8 flags 9 letters rs" "$OUT" 'in8 +flags=9 +rs '
has "T2 out flags 0" "$OUT" 'out +flags=0 '
has "T2 set action flags 256 letter o" "$OUT" 'action +set +flags=256 +o '
has "T2 ping action flags 16 letter a" "$OUT" 'action +ping +flags=16 +a '
has "T2 ev topic flags 8 letter s" "$OUT" 'topic +ev +flags=8 +s '

# --- T3 argument splitting: commas / parens inside string literals ------------------------------------
has "T3 default keeps the string literal with comma and paren" "$OUT" 'default=new BStatusNumeric\(new BDouble\(1\.5, "a,b\)"\), BStatus\.nullStatus\) facets=null'
has "T3 facets arg split off at top level" "$OUT" 'out +flags=0 +[^ ]* +default=BBoolean\.FALSE facets=BFacets\.make\("k", "v"\)'
has "T3 unbalanced paren inside a string literal does not break the split" "$OUT" 'label +flags=4 +h +default=new BString\("open \( paren"\) facets=BFacets\.NULL'
# 2-arg newAction(flags, facets): no parameter default
has "T3 2-arg action has empty default and the facets" "$OUT" 'ping +flags=16 +a +default= facets=BFacets\.NULL'

# --- T4 decompiler equivalence: javadoc source vs CFR output yield equal flags ------------------------
run "$SUT" build "$FX/cfr" --out "$ROOT/cfr.json"
rc_is "T4 build cfr exits 0" 0
EQ="$(python3 - "$ROOT/doc.json" "$ROOT/cfr.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))["demo.pkg.BFoo"]
b = json.load(open(sys.argv[2]))["demo.pkg.BFoo"]
n = eq = 0
for kind in ("properties", "actions", "topics"):
    bm = {s["name"]: s for s in b[kind]}
    for s in a[kind]:
        n += 1
        if s["name"] in bm and bm[s["name"]]["flags"] == s["flags"] and bm[s["name"]]["flagLetters"] == s["flagLetters"]:
            eq += 1
print("%d/%d" % (eq, n))
PY
)"
if [ "$EQ" = "6/6" ]; then ok "T4 flag equality doc vs cfr ($EQ)"; else no "T4 flag equality doc vs cfr: $EQ (want 6/6)"; fi
run "$SUT" show "$FX/cfr" BFoo
has "T4 show accepts a source dir and a bare class name" "$OUT" 'in8 +flags=9 +rs '

# --- T5 unknown flag token is surfaced, not dropped ---------------------------------------------------
run "$SUT" build "$FX/doc" --out "$ROOT/doc2.json"
has "T5 summary counts unknown flag tokens" "$OUT" 'unknown-flag-tokens: 1'
has "T5 stderr warns naming the token" "$ERR" 'unknown flag token.*Flags\.BOGUS_FLAG'
UF="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["demo.pkg.BUnknown"]["properties"][0].get("unknownFlags"))' "$ROOT/doc2.json")"
[ "$UF" = "['Flags.BOGUS_FLAG']" ] && ok "T5 slot record carries unknownFlags" || no "T5 unknownFlags=[$UF]"

# --- T6 absent / empty / no-match are distinct states -------------------------------------------------
run "$SUT" build "$ROOT/does-not-exist" --out "$ROOT/x.json"
rc_is "T6a absent root exits 2" 2
has "T6a names the absent root" "$ERR" 'not a directory.*does-not-exist'
[ ! -e "$ROOT/x.json" ] && ok "T6a no catalog written" || no "T6a catalog written for absent root"
mkdir -p "$ROOT/empty"
run "$SUT" build "$ROOT/empty" --out "$ROOT/e.json"
rc_is "T6b directory with no .java files exits 1" 1
has "T6b says no .java files" "$ERR" 'no \.java files'
mkdir -p "$ROOT/nomatch"; cp "$FX/doc/pkg/BPlain.java" "$ROOT/nomatch/"
run "$SUT" build "$ROOT/nomatch" --out "$ROOT/n.json"
rc_is "T6c java files without declarations exits 1" 1
has "T6c says no declarations (and how many files it looked at)" "$ERR" 'no slot declarations.*1 \.java'

# --- T7 show: unknown type, stdout JSON, determinism -------------------------------------------------
run "$SUT" show "$ROOT/doc.json" NoSuchType
rc_is "T7a show of an unknown type exits 1" 1
has "T7a names the type" "$ERR" 'no such type: NoSuchType'
run "$SUT" build "$FX/doc"
rc_is "T7b build without --out exits 0" 0
if python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$OUT" 2>/dev/null; then ok "T7b stdout is pure JSON"; else no "T7b stdout is not pure JSON"; fi
"$SUT" build "$FX/doc" --out "$ROOT/d1.json" >/dev/null 2>&1; "$SUT" build "$FX/doc" --out "$ROOT/d2.json" >/dev/null 2>&1
cmp -s "$ROOT/d1.json" "$ROOT/d2.json" && ok "T7c two builds are byte-identical" || no "T7c builds differ"

# --- T8 CLI misuse and runtime-dependency probe ------------------------------------------------------
run "$SUT"
rc_is "T8a no subcommand exits 2" 2
mkdir -p "$ROOT/nopath"
OUT="$(PATH="$ROOT/nopath" "$BASH" "$SUT" build "$FX/doc" 2>"$ROOT/err")"; RC=$?; ERR="$(cat "$ROOT/err")"
rc_is "T8b python3 absent exits 2" 2
has "T8b typed degraded state" "$ERR" 'degraded.*python3'

# --- the tool never writes into the fixture tree -------------------------------------------------------
if [ -z "$(find "$FX" -newer "$ROOT/err" -type f 2>/dev/null)" ]; then ok "T9 fixtures untouched"; else no "T9 fixture tree modified"; fi

# ======================== MUTATION CONTROLS — --prove-teeth ==========================================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant of n4_type_catalog.py must flip a specific verdict --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MUT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$MUT"' EXIT
  MUTANT_SYNTAX=none
  export MUTANT_SYNTAX
  # mp LABEL EXPR GOOD_PATTERN ARGV... : sed-mutate the .py, then require the original to match
  # GOOD_PATTERN and the mutant to LACK it (same rc 0 on both: only the verdict text flips).
  mp() {
    local label="$1" expr="$2" pat="$3" rc="${MP_RC:-0}"; shift 3
    mutant_chain "$label" "$PY" "$MUT/m_$$.py" "$expr" ${MP_EXPR2:+"$MP_EXPR2"} || { fail=$((fail+1)); return 1; }
    if mutant_tooth "$label" "$rc" "$rc" "$MUT/m_$$.py" --orig "$PY" --good-has "$pat" --bad-lacks "$pat" -- python3 @SUT@ "$@"; then
      pass=$((pass+1))
    else
      fail=$((fail+1))
    fi
    rm -f "$MUT/m_$$.py"
  }
  # mx LABEL EXPR GOOD_RC BAD_RC ARGV... : exit-code teeth
  mx() {
    local label="$1" expr="$2" grc="$3" brc="$4"; shift 4
    mutant_chain "$label" "$PY" "$MUT/m_$$.py" "$expr" || { fail=$((fail+1)); return 1; }
    if mutant_tooth "$label" "$grc" "$brc" "$MUT/m_$$.py" --orig "$PY" -- python3 @SUT@ "$@"; then
      pass=$((pass+1))
    else
      fail=$((fail+1))
    fi
    rm -f "$MUT/m_$$.py"
  }
  mp "M1 READONLY bit moved: in8 must stay flags=9" 's/"READONLY": (0x00000001, "r")/"READONLY": (0x00000002, "r")/' 'in8 +flags=9 +rs ' show "$FX/doc" BFoo
  mp "M2 comma split ignores nesting: default must keep its string literal" 's/elif c == "," and depth == 0:/elif c == ",":/' 'default=new BStatusNumeric\(new BDouble\(1\.5, "a,b\)"\)' show "$FX/doc" BFoo
  mp "M3 string literals not tracked in _split_args" '0,/elif c in "\\"'"'"'":/s//elif False:/' 'label +flags=4 +h +default=new BString\("open \( paren"\) facets=BFacets\.NULL' show "$FX/doc" BFoo
  mp "M4a (BValue) cast not stripped from slot arguments" 's/\^\\((?:int|BValue/^\\((?:int/' 'out +flags=0 +[^ ]* +default=BBoolean\.FALSE facets=BFacets\.make' show "$FX/cfr" BFoo
  MP_EXPR2='s/\^\\((?:int|BValue/^\\((?:BValue/' mp "M4b (int) cast not stripped from flags (both strip sites)" 's/\^\\(\\s\*int\\s\*\\)\\s\*/^ZZZ/' 'in8 +flags=9 +rs ' show "$FX/cfr" BFoo
  mp "M5 2-arg action branch disabled: ping keeps empty default" '0,/if len(args) == 2:     # newAction/s//if len(args) == 99:     # newAction/' 'ping +flags=16 +a +default= facets=BFacets\.NULL' show "$FX/doc" BFoo
  mp "M6 unknown flag tokens dropped silently" 's/unknown\.append(tok)/pass/' 'unknown-flag-tokens: 1' build "$FX/doc"
  mx "M7 absent-root guard removed (exit 2 -> not 2)" 's/if not os\.path\.isdir(root):/if False:/' 2 1 build "$ROOT/does-not-exist"
  MP_RC=1 mp "M8 zero-.java guard removed: message must name the empty input" 's/if files_seen == 0:/if False:/' 'no \.java files' build "$ROOT/empty"
  mx "M9 zero-declaration guard removed (exit 1 -> 0)" 's/if not cat:/if False:/' 1 0 build "$ROOT/nomatch"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
