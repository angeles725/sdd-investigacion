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

# --- T9 the tool never writes into the fixture tree (content hash before/after, not mtimes) ------------
tree_hash() { (cd "$FX" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }
H0="$(tree_hash)"
"$SUT" build "$FX/doc" "$FX/cfr" --out "$ROOT/h.json" >/dev/null 2>&1; "$SUT" show "$FX/doc" BFoo >/dev/null 2>&1
H1="$(tree_hash)"
N_FILES="$(find "$FX" -type f | wc -l)"
if [ "$N_FILES" -ge 4 ] && [ -n "$H0" ] && [ "$H0" = "$H1" ]; then ok "T9 fixtures untouched ($N_FILES files, hash stable)"; else no "T9 fixture tree modified or empty ($N_FILES files)"; fi

# --- T10 duplicates across roots: first wins, counted --------------------------------------------------
run "$SUT" build "$FX/doc" "$FX/cfr" --out "$ROOT/dup.json"
rc_is "T10 two roots exit 0" 0
has "T10 duplicate type counted" "$OUT" 'types: 2 .*duplicates: 1 '

# --- T11 unreadable inputs are counted and warned, never skipped quietly ------------------------------
mkdir -p "$ROOT/unr/sub" "$ROOT/unr/locked"
cp "$FX/doc/pkg/BFoo.java" "$ROOT/unr/"
ln -s "$ROOT/unr/nowhere" "$ROOT/unr/sub/Dead.java"
run "$SUT" build "$ROOT/unr" --out "$ROOT/unr.json"
rc_is "T11a dangling .java symlink: build still exits 0" 0
has "T11a counted as unreadable" "$OUT" 'unreadable: 1 '
has "T11a warned" "$ERR" 'not a regular file.*Dead\.java'
mkfifo "$ROOT/unr/sub/Pipe.java"
run timeout 10 "$SUT" build "$ROOT/unr" --out "$ROOT/unr2.json"
rc_is "T11b FIFO named *.java does not block the walk" 0
has "T11b FIFO counted as unreadable" "$OUT" 'unreadable: 2 '
rm -f "$ROOT/unr/sub/Pipe.java"
chmod 000 "$ROOT/unr/locked"
if [ "$(id -u)" != 0 ] && ! ls "$ROOT/unr/locked" >/dev/null 2>&1; then
  run "$SUT" build "$ROOT/unr" --out "$ROOT/unr3.json"
  has "T11c unreadable directory counted" "$OUT" 'unreadable: 2 '
  has "T11c unreadable directory warned" "$ERR" 'cannot read directory.*locked'
else
  echo "  SKIP  T11c unreadable directory (running as root or chmod ineffective)"
fi
chmod 755 "$ROOT/unr/locked"

# --- T12 declarations that cannot be parsed or have no class are surfaced -------------------------------
mkdir -p "$ROOT/drop"
cat > "$ROOT/drop/BD.java" <<'JAVA'
package demo.drop;
public class BD extends BObject
{
  public static final Property q = makeIt();
  public static final Property ok = newProperty(0, BString.DEFAULT, null);
}
JAVA
cat > "$ROOT/drop/NoClass.java" <<'JAVA'
package demo.drop;
public static final Property z = newProperty(0, BString.DEFAULT, null);
JAVA
run "$SUT" build "$ROOT/drop" --out "$ROOT/drop.json"
rc_is "T12 build exits 0 (BD is catalogued)" 0
has "T12a unparseable declaration counted" "$OUT" 'dropped-declarations: 1 '
has "T12a warned naming the slot" "$ERR" "unparseable slot declaration 'q' dropped"
has "T12b file with slots but no class counted" "$OUT" 'no-class-files: 1( |$)'
has "T12b warned naming the file" "$ERR" 'no class declaration.*NoClass\.java'
has "T12 the parseable slot is kept" "$OUT" 'types: 1 +properties: 1 '

# --- T13 --out failure is a typed exit 2 and leaves no partial file ------------------------------------
run "$SUT" build "$FX/doc" --out "$ROOT/no-such-dir/c.json"
rc_is "T13a unwritable --out exits 2" 2
has "T13a names the path" "$ERR" 'cannot write.*no-such-dir'
LEFT="$(find "$ROOT" -name '*.tmp.*' | wc -l)"
[ "$LEFT" = 0 ] && ok "T13b no temp file left behind" || no "T13b $LEFT temp file(s) left behind"
"$SUT" build "$FX/doc" --out "$ROOT/atomic.json" >/dev/null 2>&1
LEFT="$(find "$ROOT" -maxdepth 1 -name 'atomic.json.tmp.*' | wc -l)"
[ "$LEFT" = 0 ] && [ -s "$ROOT/atomic.json" ] && ok "T13c success leaves only the final file" || no "T13c temp left ($LEFT) or catalog missing"

# --- T14 a root whose .java files are ALL unreadable is degraded (exit 2), never a no-match (exit 1) ----
mkdir -p "$ROOT/allunr/sub"
ln -s "$ROOT/allunr/nowhere" "$ROOT/allunr/sub/Dead.java"
run "$SUT" build "$ROOT/allunr" --out "$ROOT/allunr.json"
rc_is "T14a only unreadable .java files exits 2" 2
has "T14a typed degraded message names the counts" "$ERR" 'degraded.*1 unreadable.*0 .*readable'
[ ! -e "$ROOT/allunr.json" ] && ok "T14a no catalog written" || no "T14a catalog written for an unreadable root"
run "$SUT" show "$ROOT/allunr" BFoo
rc_is "T14b show over an all-unreadable dir exits 2" 2
mkdir -p "$ROOT/lockroot/inner"
chmod 000 "$ROOT/lockroot"
if [ "$(id -u)" != 0 ] && ! ls "$ROOT/lockroot" >/dev/null 2>&1; then
  run "$SUT" build "$ROOT/lockroot" --out "$ROOT/lockroot.json"
  rc_is "T14c unreadable root directory exits 2 (not 'no .java files')" 2
else
  echo "  SKIP  T14c unreadable root (running as root or chmod ineffective)"
fi
chmod 755 "$ROOT/lockroot"

# --- T15 show on a malformed catalog is a typed exit 2, never a traceback --------------------------------
printf '[]' > "$ROOT/m-list.json"
printf '{"a.B": 5}' > "$ROOT/m-scalar.json"
printf '{"a.B": {"extends": "X"}}' > "$ROOT/m-nokeys.json"
printf '{"a.B": {"extends": "X", "properties": [{"name": "p"}], "actions": [], "topics": []}}' > "$ROOT/m-noflags.json"
printf '{"a.B": {"extends": "X", "properties": [5], "actions": [], "topics": []}}' > "$ROOT/m-badslot.json"
printf '{not json' > "$ROOT/m-syntax.json"
for m in list scalar nokeys noflags badslot syntax; do
  run "$SUT" show "$ROOT/m-$m.json" B
  rc_is "T15 malformed catalog ($m) exits 2" 2
  has "T15 ($m) typed message" "$ERR" 'cannot load catalog'
  lacks "T15 ($m) no traceback" "$ERR" 'Traceback'
done

# --- T16 numeric flag forms: hex, multi-token numeric, mixed with a named flag ------------------------------
mkdir -p "$ROOT/num"
cat > "$ROOT/num/BNum.java" <<'JAVA'
package demo.num;
public class BNum extends BComponent
{
  public static final Property hex = newProperty(0x10, BString.DEFAULT, null);
  public static final Property multi = newProperty((int)1024 | 8, BString.DEFAULT, null);
  public static final Property mixed = newProperty(Flags.READONLY | 0x10 | (int)256, BString.DEFAULT, null);
}
JAVA
run "$SUT" show "$ROOT/num" BNum
rc_is "T16 show numeric forms exits 0" 0
has "T16 hex 0x10 decodes to 16 letter a" "$OUT" 'hex +flags=16 +a '
has "T16 multi-token numeric (int)1024 | 8 decodes to 1032" "$OUT" 'multi +flags=1032 +sf '
has "T16 named | hex | cast decodes to 273" "$OUT" 'mixed +flags=273 +rao '

# --- T17 unknown tokens of a dropped duplicate are not counted or warned -----------------------------------
cp -r "$FX/doc" "$ROOT/dupdoc"
run "$SUT" build "$FX/doc" "$ROOT/dupdoc" --out "$ROOT/dupdoc.json"
has "T17 duplicate tree adds no unknown-flag-tokens" "$OUT" 'unknown-flag-tokens: 1 '
n_warn="$(grep -c 'unknown flag token' <<<"$ERR")"
[ "$n_warn" = 1 ] && ok "T17 the token is warned once, not per duplicate" || no "T17 warned $n_warn times"

# --- T18 show: empty catalog is distinct from an unknown type; hits are sorted -----------------------------
run "$SUT" show "$ROOT/empty" BFoo
rc_is "T18a show over a dir with no types exits 1" 1
has "T18a says the catalog is empty, not 'no such type'" "$ERR" 'no types catalogued'
# walk order (dir a, b, c) is zz, mm, aa: the natural order is the REVERSE of sorted, so only the sort can fix it
mkdir -p "$ROOT/two/a" "$ROOT/two/b" "$ROOT/two/c"
sed 's/package demo.pkg;/package zz.pkg;/' "$FX/doc/pkg/BFoo.java" > "$ROOT/two/a/BFoo.java"
sed 's/package demo.pkg;/package aa.pkg;/' "$FX/doc/pkg/BFoo.java" > "$ROOT/two/c/BFoo.java"
sed 's/package demo.pkg;/package mm.pkg;/' "$FX/doc/pkg/BFoo.java" > "$ROOT/two/b/BFoo.java"
run "$SUT" show "$ROOT/two" BFoo
SEQ="$(grep -oE '^[a-z.]+BFoo' <<<"$OUT" | paste -sd, -)"
[ "$SEQ" = "aa.pkg.BFoo,mm.pkg.BFoo,zz.pkg.BFoo" ] && ok "T18b ambiguous suffix hits print in sorted order" || no "T18b hit sequence [$SEQ]"

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
    # shellcheck disable=SC2086 # MX_PREFIX is a deliberate word-split command prefix (e.g. "timeout 5")
    if mutant_tooth "$label" "$grc" "$brc" "$MUT/m_$$.py" --orig "$PY" -- ${MX_PREFIX:-} python3 @SUT@ "$@"; then
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
  mp "M5 2-arg action branch disabled: ping keeps empty default" 's/if len(args) == 2:/if len(args) == 99:/' 'ping +flags=16 +a +default= facets=BFacets\.NULL' show "$FX/doc" BFoo
  mp "M6 unknown flag tokens dropped silently" 's/unknown\.append(tok)/pass/' 'unknown-flag-tokens: 1' build "$FX/doc"
  FIFO_DIR="$ROOT/fifodir"; mkdir -p "$FIFO_DIR"; cp "$FX/doc/pkg/BFoo.java" "$FIFO_DIR/"; mkfifo "$FIFO_DIR/Pipe.java"
  MP_RC=2 mp "M7 absent-root guard removed: the typed 'not a directory' message must survive" 's/if not os\.path\.isdir(root):/if False:/' 'not a directory.*does-not-exist' build "$ROOT/does-not-exist"
  mp "M10 duplicate counter removed" 's/st\["duplicates"\] += 1/pass/' 'duplicates: 1 ' build "$FX/doc" "$FX/cfr"
  mp "M11 unparseable-declaration counter removed" 's/st\["dropped_declarations"\] += 1/pass/' 'dropped-declarations: 1 ' build "$ROOT/drop"
  mp "M12 no-class guard removed" 's/if has_slots and not t\["class"\]:/if False:/' 'no-class-files: 1( |$)' build "$ROOT/drop"
  mkdir -p "$ROOT/lk/locked"; cp "$FX/doc/pkg/BFoo.java" "$ROOT/lk/"; chmod 000 "$ROOT/lk/locked"
  if [ "$(id -u)" != 0 ] && ! ls "$ROOT/lk/locked" >/dev/null 2>&1; then
    mp "M13 walk onerror counter removed" '0,/        st\["unreadable"\] += 1/s//        pass/' 'unreadable: 1( |$)' build "$ROOT/lk"
  else
    echo "  SKIP  M13 (running as root or chmod ineffective)"
  fi
  chmod 755 "$ROOT/lk/locked"
  mx "M14 --out write error swallowed (exit 2 -> 0)" 's/cannot write %s: %s" % (args\.out, e), file=sys.stderr)/&\n            return 0/' 2 0 build "$FX/doc" --out "$ROOT/no-such-dir/c.json"
  MX_PREFIX="timeout 5" mx "M15 non-regular-file guard removed: FIFO blocks (rc 124)" 's/if not os\.path\.isfile(path):/if False:/' 0 124 build "$FIFO_DIR" --out "$ROOT/fifo.json"
  MP_RC=1 mp "M8 zero-.java guard removed: message must name the empty input" 's/if files_seen == 0:/if False:/' 'no \.java files' build "$ROOT/empty"
  mx "M9 zero-declaration guard removed (exit 1 -> 0)" 's/if not cat:/if False:/' 1 0 build "$ROOT/nomatch"
  # the #1511 round-2 fixes
  mx "M16 degraded guard removed: all-unreadable root reads as no-match (exit 2 -> 1)" 's/if degraded:/if False:/' 2 1 build "$ROOT/allunr"
  mx "M17 catalog shape validation removed: malformed catalog tracebacks (exit 2 -> 1)" 's/^    _validate_catalog(cat)$/    pass/' 2 1 show "$ROOT/m-nokeys.json" B
  mp "M18 unknown tokens counted for a dropped duplicate" 's/^\( *\)continue    # a dropped duplicate.*/\1pass/' 'unknown-flag-tokens: 1 ' build "$FX/doc" "$ROOT/dupdoc"
  mp "M19 hex literal branch removed" 's/\^0\[xX\]\[0-9a-fA-F\]+\$/^NOPE$/' 'hex +flags=16 +a ' show "$ROOT/num" BNum
  mp "M20 only the first |-separated numeric token decoded" 's/for part in expr\.split("|"):/for part in expr.split("|")[:1]:/' 'multi +flags=1032 ' show "$ROOT/num" BNum
  # M21 asserts the FULL printed sequence of hits (fixture walk order is zz,mm,aa; sorted is aa,mm,zz), so only the sort fixes it
  mutant_chain "M21" "$PY" "$MUT/m21.py" 's/hits = sorted(\(.*\))$/hits = list(\1)/' || fail=$((fail+1))
  if mutant_tooth "M21 show hits not sorted (full sequence must be aa,mm,zz)" 0 0 "$MUT/m21.py" --orig "$PY" --good-has '^aa\.pkg\.BFoo,mm\.pkg\.BFoo,zz\.pkg\.BFoo$' --bad-lacks '^aa\.pkg\.BFoo,mm\.pkg\.BFoo,zz\.pkg\.BFoo$' -- bash -c 'python3 "$1" show "$2" BFoo | grep -oE "^[a-z.]+BFoo" | paste -sd, -' _ @SUT@ "$ROOT/two"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  rm -f "$MUT/m21.py"
  MP_RC=1 mp "M22 empty-catalog message folded into 'no such type'" 's/^    if not cat:$/    if False:/' 'no types catalogued' show "$ROOT/empty" BFoo
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
