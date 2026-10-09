#!/usr/bin/env bash
# verify-cd-physical.test.sh — behavior + mutation-control suite for verify-cd-physical.sh
# (kit issue #1024 round 4, item 3: the systemic lint guard against the logical-cd-through-a-
# symlinked-toolbelt bug class; round 5 adds the §7 precision fixes and the default-scope change).
#
# Checks (functional, always run — kit issue #1024 round 5, general cleanup: this list is kept in
# sync with the test numbers actually used below; a numbering drift here once meant this comment
# no longer described the tests it claimed to):
#   1    script exists
#   2    script executable
#   3    a non-climbing dirname($0) derivation (no "..") is NOT flagged (harmless, over 70 real
#        toolbelt scripts use exactly this idiom)
#   4    a climbing derivation lacking -P IS flagged (HIT), exit 1
#   5    the identical climbing derivation WITH cd -P/pwd -P is NOT flagged, exit 0
#   5b   `cd -P` alone (bare `pwd`, no `-P` on it) is NOT flagged — `cd -P` alone is load-bearing
#   5c   word-boundary precision: `$KX` does not falsely match a tainted `K` (round 5, Opus #2)
#   5d   per-cd-invocation precision: `cd .. && cd -P .` IS flagged — the climbing `cd` has no
#        `-P` of its own, even though a later, non-climbing `cd -P` sits on the same line
#   5e   cheap shape: `dirname -- "$0"` is recognised as rooted (round 5, Opus #2)
#   5f   cheap shape: `dirname "${0}"` (braced form) is recognised as rooted
#   5g   cheap shape: a `local`/`export` prefix before the variable name is recognised
#   5h   the `;`-split cannot glob-expand a line holding a literal glob metacharacter (RDD
#        R4-unquoted-split-globs)
#   5h2  a bare `*` statement is never glob-expanded into a filename-shaped assignment (#1033)
#   5p   a `;` inside `$( )` does not hide a bare climb — first/middle/last statement (issue #1921)
#   5q   the -P'd `;` twin is clean and its climb counts as seen (no no-match)
#   5x/5y the shared RSDD-SELF-DIR idiom roots `_RSDD_SELF`: a non -P climb from it is flagged, the -P'd twin is clean (#1675)
#   5r   `;` inside quotes/backticks is data; a `;` after a `#` comment is not a statement
#   5s   nested `$( )`: the outer climbing cd is judged on its own -P, not an inner cd's
#   5u   a `..` reaching cd through a nested substitution is still flagged (#1921 review)
#   5v   open-quote / `$'a\'b'` / `${x//(/y}` / case-arm / case-in-`$( )` lines are UNCLASSIFIABLE (5v, 5v2)
#   5w   splitter guards: apostrophe in double quotes, `;` inside `${ }`, backslash-escaped `;`
#   5m   a later bare `cd ..` after a compliant `cd -P` climb is flagged (#1033)
#   5n   keyword-like identifiers (`exported_dir`, `localdir`) keep their whole name (#1033)
#   5i   climb_seen (formerly the misleadingly-named pattern_seen): an all-compliant file is NOT
#        reported as no-match — the construct was seen, it just happened to pass
#   5j   one-line function body `f(){ local K=...; }` is recognised (issue #1033 L1)
#   5k   keyword flags (`declare -r`, `local -r`) are recognised (issue #1033 L1)
#   5l   a tab after `cd` is recognised (issue #1033 L1)
#   6    a chained two-hop derivation (var A non-climbing, var B climbs via A) is flagged on the
#        SECOND line, proving taint propagates across lines/variables
#   7    a `cd`/`pwd` unrelated to $0/BASH_SOURCE (dirname of an arbitrary variable) is excluded
#   8    a `VAR1=...; VAR2=...` two-statement physical line (';'-separated) is split and taint
#        still propagates from VAR1 to VAR2 on the same line
#   9    the allow-marker `# LINT-CD-PHYSICAL-OK: <reason>` on the flagged line suppresses the HIT
#        (reported as ALLOWED) and the run still exits 0
#   10   the allow-marker on the line BEFORE the flagged line also works
#   11   an allow-marker with NO reason text still counts as a HIT (reason is required)
#   12   absent-input: no scan directory found → exit 2, typed message
#   13   empty-input: scan directory exists, no *.sh files → exit 2, typed message
#   14   no-match: files scanned, pattern never seen → exit 0, typed "no-match" message (not a
#        bare silent 0 — CLAUDE.md §7 anti-silent-zero)
#   15   real-corpus smoke test: a bare, no-argument `verify-cd-physical.sh` on the real kit
#        exits 0 (round 5, Opus finding 1 — no whole-file `grep -v` filter; the default scope now
#        excludes tests/ entirely, so there is nothing left for a filter to hide)
#   15b  an EXPLICIT tests/ directory argument is still scanned in full — default-scope exclusion
#        is a default, not a capability limit (round 5, Opus finding 1)
#   15c  fake kit tree: the default scope lints tests/ INFRASTRUCTURE (tests/lib/*.sh, tests/*.sh) and
#        still prunes *.test.sh (kit issue #1033 L2); 15c2 the fixed tree is clean
#
# --prove-teeth: a fixture script with a logical (non -P) climbing cd must make the lint FAIL;
# the identical fixture given -P must make it PASS — proving the checker's core distinction has
# teeth, not just its own self-tests.
#
# Usage: verify-cd-physical.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-cd-physical.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-cd-physical.test.sh =="

# ── 1. Script exists and is executable ───────────────────────────────────────
[ -f "$SUT" ] && ok "1 script exists" || no "1 script missing: $SUT"
[ -x "$SUT" ] && ok "2 script executable" || no "2 script not executable"

# mkbox <name> : an empty scan-target directory under $TMP
mkbox() { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# ── 3. Non-climbing derivation is NOT flagged ────────────────────────────────
box3="$(mkbox case-safe)"
cat > "$box3/safe.sh" <<'EOF'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "$HERE"
EOF
OUT3="$(bash "$SUT" "$box3" 2>&1)"; RC3=$?
if [ "$RC3" -eq 0 ] && ! <<<"$OUT3" grep -q 'HIT'; then
  ok "3 non-climbing dirname(\$0) derivation is NOT flagged (harmless, exit 0)"
else
  no "3 non-climbing derivation was wrongly flagged (rc=$RC3 out=[$OUT3])"
fi

# ── 4. Climbing derivation lacking -P IS flagged ─────────────────────────────
box4="$(mkbox case-climb-bad)"
cat > "$box4/bad.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"
echo "$KIT"
EOF
OUT4="$(bash "$SUT" "$box4" 2>&1)"; RC4=$?
if [ "$RC4" -eq 1 ] && <<<"$OUT4" grep -q 'HIT.*bad\.sh:2'; then
  ok "4 climbing derivation lacking -P IS flagged (HIT, exit 1)"
else
  no "4 climbing derivation should have been flagged (rc=$RC4 out=[$OUT4])"
fi

# ── 5. Identical climbing derivation WITH -P is NOT flagged ─────────────────
box5="$(mkbox case-climb-fixed)"
cat > "$box5/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
echo "$KIT"
EOF
OUT5="$(bash "$SUT" "$box5" 2>&1)"; RC5=$?
if [ "$RC5" -eq 0 ] && ! <<<"$OUT5" grep -q 'HIT'; then
  ok "5 climbing derivation WITH -P is NOT flagged (exit 0)"
else
  no "5 -P'd climbing derivation was wrongly flagged (rc=$RC5 out=[$OUT5])"
fi

# ── 5b. `cd -P` alone (no `pwd -P`) is NOT flagged — verified empirically that `cd -P` alone is
#        load-bearing; a following bare `pwd` is redundant, not required. Kit issue #976/#984
#        (PR #1029)'s own fix to stage-retro.sh's KIT_REPO line uses exactly this shape.
box5b="$(mkbox case-climb-cdp-only)"
cat > "$box5b/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd -P "$(dirname "$0")/.." && pwd)"
echo "$KIT"
EOF
OUT5B="$(bash "$SUT" "$box5b" 2>&1)"; RC5B=$?
if [ "$RC5B" -eq 0 ] && ! <<<"$OUT5B" grep -q 'HIT'; then
  ok "5b climbing derivation with cd -P alone (bare pwd) is NOT flagged (exit 0)"
else
  no "5b cd-P-only climbing derivation was wrongly flagged (rc=$RC5B out=[$OUT5B])"
fi

# ── 5c. Word-boundary precision (kit issue #1024 round 5, Opus finding 2, §7): a plain substring
#        check would let `$KX` count as a reference to a tainted `K` — `$KX` is a genuinely
#        unrelated path here and must not be flagged.
box5c="$(mkbox case-word-boundary)"
cat > "$box5c/fixed.sh" <<'EOF'
#!/usr/bin/env bash
K="$(cd "$(dirname "$0")" && pwd)"
KX="/unrelated/path"
OTHER="$(cd "$KX/.." && pwd)"
EOF
OUT5C="$(bash "$SUT" "$box5c" 2>&1)"; RC5C=$?
if [ "$RC5C" -eq 0 ] && ! <<<"$OUT5C" grep -q 'HIT'; then
  ok "5c word-boundary: \$KX does not falsely match a tainted K"
else
  no "5c word-boundary: \$KX was wrongly treated as a reference to tainted K (rc=$RC5C out=[$OUT5C])"
fi

# ── 5d. Per-cd-invocation -P precision (kit issue #1024 round 5, Opus finding 2, §7): "does -P
#        appear ANYWHERE on the line" let `cd .. && cd -P .` slip through — the second,
#        non-climbing `cd -P` "covered" the first, climbing `cd ..`, which has none of its own.
box5d="$(mkbox case-climb-precision)"
cat > "$box5d/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")" && cd .. && cd -P . && pwd)"
EOF
OUT5D="$(bash "$SUT" "$box5d" 2>&1)"; RC5D=$?
if [ "$RC5D" -eq 1 ] && <<<"$OUT5D" grep -q 'HIT.*fixed\.sh:2'; then
  ok "5d per-cd precision: 'cd .. && cd -P .' IS flagged — the climbing cd has no -P of its own"
else
  no "5d per-cd precision: 'cd .. && cd -P .' was wrongly left unflagged (rc=$RC5D out=[$OUT5D])"
fi

# ── 5e. Cheap shape: `dirname -- "$0"` is recognised as rooted (kit issue #1024 round 5, Opus
#        finding 2) — the literal `--` token used to make this invisible to the rooted check.
box5e="$(mkbox case-dirname-dashdash)"
cat > "$box5e/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname -- "$0")/.." && pwd)"
EOF
OUT5E="$(bash "$SUT" "$box5e" 2>&1)"; RC5E=$?
if [ "$RC5E" -eq 1 ] && <<<"$OUT5E" grep -q 'HIT.*fixed\.sh:2'; then
  ok "5e cheap shape: 'dirname -- \"\$0\"' is recognised as a rooted, climbing derivation"
else
  no "5e cheap shape: 'dirname -- \"\$0\"' was not recognised (rc=$RC5E out=[$OUT5E])"
fi

# ── 5f. Cheap shape: `dirname "${0}"` (braced form) is recognised as rooted.
box5f="$(mkbox case-dirname-braced)"
cat > "$box5f/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "${0}")/.." && pwd)"
EOF
OUT5F="$(bash "$SUT" "$box5f" 2>&1)"; RC5F=$?
if [ "$RC5F" -eq 1 ] && <<<"$OUT5F" grep -q 'HIT.*fixed\.sh:2'; then
  ok "5f cheap shape: 'dirname \"\${0}\"' (braced) is recognised as a rooted, climbing derivation"
else
  no "5f cheap shape: 'dirname \"\${0}\"' was not recognised (rc=$RC5F out=[$OUT5F])"
fi

# ── 5g. Cheap shape: a `local`/`export` prefix before the variable name is recognised.
box5g="$(mkbox case-local-export)"
cat > "$box5g/fixed.sh" <<'EOF'
#!/usr/bin/env bash
local KIT="$(cd "$(dirname "$0")/.." && pwd)"
export KIT2="$(cd "$KIT/.." && pwd)"
EOF
OUT5G="$(bash "$SUT" "$box5g" 2>&1)"; RC5G=$?
if [ "$RC5G" -eq 1 ] && <<<"$OUT5G" grep -q 'HIT.*fixed\.sh:2' && <<<"$OUT5G" grep -q 'HIT.*fixed\.sh:3'; then
  ok "5g cheap shape: 'local' and 'export' prefixes before the variable name are both recognised"
else
  no "5g cheap shape: 'local KIT=...' / 'export KIT2=...' was not recognised (rc=$RC5G out=[$OUT5G])"
fi

# ── 5h. Unquoted split cannot glob (kit issue #1024 round 5, Opus finding 2, RDD
#        R4-unquoted-split-globs): a line containing a literal glob metacharacter must not make
#        the checker crash, hang, or silently expand against real filesystem entries. Build the
#        fixture directory FIRST so a glob-vulnerable split would have something to expand into.
box5h="$(mkbox case-unquoted-split-globs)"
touch "$box5h/somefile.txt" "$box5h/anotherfile.txt"
cat > "$box5h/fixed.sh" <<'EOF'
#!/usr/bin/env bash
# a semicolon-separated line whose second statement's comment-adjacent text holds glob chars
here="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$here/.." && pwd)" # matches *.txt or [ab]*
EOF
OUT5H="$(bash "$SUT" "$box5h" 2>&1)"; RC5H=$?
if [ "$RC5H" -eq 1 ] && <<<"$OUT5H" grep -q 'HIT.*fixed\.sh:3' \
   && ! <<<"$OUT5H" grep -qi 'somefile\|anotherfile'; then
  ok "5h unquoted-split-globs: a glob-metachar-bearing line is handled correctly, no glob expansion leaked"
else
  no "5h unquoted-split-globs: glob metacharacters affected the result (rc=$RC5H out=[$OUT5H])"
fi

# ── 5h2. Discriminating glob test (issue #1033 follow-up): 5h's fixture holds its glob characters in a
#        stripped comment, so a glob-expanding split would pass it too. Here a statement that is a bare
#        `*` runs with the box as cwd, where a FILE is named like a flaggable assignment. A glob-expanding
#        split turns the `*` into that filename and reports a bogus HIT; `read -ra` must not.
box5h2="$(mkbox case-glob-discriminating)"
: > "$box5h2/"'K="$(cd "$(dirname "$0")" && cd .. && pwd)"'
printf '%s\n' '#!/usr/bin/env bash' ': cd pwd;*' > "$box5h2/fixed.sh"
OUT5H2="$(cd "$box5h2" && bash "$SUT" "$box5h2" 2>&1)"; RC5H2=$?
if [ "$RC5H2" -eq 0 ] && ! <<<"$OUT5H2" grep -q 'HIT'; then
  ok "5h2 a bare '*' statement is never glob-expanded into a filename-shaped assignment (no bogus HIT)"
else
  no "5h2 glob expansion leaked a filename into the statement scan (rc=$RC5H2 out=[$OUT5H2])"
fi

# ── 5m. A LATER non-compliant climb after a compliant one on the same line is still flagged
#        (issue #1033 follow-up: the per-segment loop used to stop at the FIRST climbing segment).
box5m="$(mkbox case-second-climb)"
cat > "$box5m/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd -P "$(dirname "$0")/.." && cd .. && pwd)"
OK2="$(cd -P "$(dirname "$0")/.." && cd -P .. && pwd)"
EOF
OUT5M="$(bash "$SUT" "$box5m" 2>&1)"; RC5M=$?
if [ "$RC5M" -eq 1 ] && <<<"$OUT5M" grep -q 'HIT.*fixed\.sh:2' && ! <<<"$OUT5M" grep -q 'HIT.*fixed\.sh:3'; then
  ok "5m a later bare 'cd ..' after a compliant 'cd -P' climb is flagged; an all -P'd chain is not"
else
  no "5m later non-compliant climb missed or compliant chain flagged (rc=$RC5M out=[$OUT5M])"
fi

# ── 5n. Keyword prefix must not steal identifier characters (#1033 follow-up R3-prefix-regex-steals-
#        identifier): `exported_dir=` / `localdir=` start with a keyword but are plain names, so the
#        tracked name stays whole and a chained unsafe climb through them is still flagged.
box5n="$(mkbox case-keyword-like-identifier)"
cat > "$box5n/fixed.sh" <<'EOF'
#!/usr/bin/env bash
exported_dir="$(cd "$(dirname "$0")" && pwd)"
K="$(cd "$exported_dir/.." && pwd)"
localdir="$(cd "$(dirname "$0")" && pwd)"
K2="$(cd "$localdir/.." && pwd)"
EOF
OUT5N="$(bash "$SUT" "$box5n" 2>&1)"; RC5N=$?
if [ "$RC5N" -eq 1 ] && <<<"$OUT5N" grep -q 'HIT.*fixed\.sh:3' && <<<"$OUT5N" grep -q 'HIT.*fixed\.sh:5'; then
  ok "5n keyword-like identifiers (exported_dir, localdir) keep their whole name — chained climbs flagged"
else
  no "5n keyword-like identifier was truncated by the prefix group (rc=$RC5N out=[$OUT5N])"
fi

# ── 5o. Segments also split on `||` and `|` (#1033 review): `cd -P .. || cd ..` lands on the bare
#        climb whenever the -P'd one fails, so the bare `cd ..` must be flagged; the all -P'd twin is not.
box5o="$(mkbox case-or-pipe-segments)"
cat > "$box5o/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd -P "$(dirname "$0")/.." || cd .. && pwd)"
K2="$(cd -P "$(dirname "$0")/.." || cd -P .. && pwd)"
K3="$(cd -P "$(dirname "$0")/.." | cd .. && pwd)"
EOF
OUT5O="$(bash "$SUT" "$box5o" 2>&1)"; RC5O=$?
if [ "$RC5O" -eq 1 ] && <<<"$OUT5O" grep -q 'HIT.*fixed\.sh:2' && ! <<<"$OUT5O" grep -q 'HIT.*fixed\.sh:3' \
   && <<<"$OUT5O" grep -q 'HIT.*fixed\.sh:4'; then
  ok "5o '||' and '|' split segments: a bare climb after '||' / '|' is flagged; the all -P'd '||' chain is not"
else
  no "5o '||'/'|' segment split wrong (rc=$RC5O out=[$OUT5O])"
fi

# ── 5p. A `;` INSIDE `$( )` must not split the statement before the cd/pwd derivation is seen
#        (issue #1921). Edges: the `;`-form statement FIRST, MIDDLE and LAST on its line.
box5p="$(mkbox case-semicolon-in-subst)"
cat > "$box5p/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.."; pwd)"; echo first
A=1; KIT2="$(cd "$(dirname "$0")/.."; pwd)"; B=2
A=1; KIT3="$(cd "$(dirname "$0")/.."; pwd)"
EOF
OUT5P="$(bash "$SUT" "$box5p" 2>&1)"; RC5P=$?
if [ "$RC5P" -eq 1 ] && <<<"$OUT5P" grep -q 'HIT.*fixed\.sh:2' && <<<"$OUT5P" grep -q 'HIT.*fixed\.sh:3' \
   && <<<"$OUT5P" grep -q 'HIT.*fixed\.sh:4'; then
  ok "5p a ';' inside \$( ) does not hide a bare climbing cd (first, middle and last statement on the line)"
else
  no "5p ';'-inside-\$( ) climbing derivation was missed (rc=$RC5P out=[$OUT5P])"
fi

# ── 5q. The -P'd `;` twin is clean AND counts as a seen climb (not reported as no-match).
box5q="$(mkbox case-semicolon-in-subst-fixed)"
cat > "$box5q/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd -P "$(dirname "$0")/.."; pwd -P)"
EOF
OUT5Q="$(bash "$SUT" "$box5q" 2>&1)"; RC5Q=$?
if [ "$RC5Q" -eq 0 ] && ! <<<"$OUT5Q" grep -q 'no-match\|^HIT'; then
  ok "5q the -P'd ';'-inside-\$( ) form is clean and its climb counts as seen (no no-match)"
else
  no "5q -P'd ';' form wrongly flagged or reported no-match (rc=$RC5Q out=[$OUT5Q])"
fi

# ── 5x/5y. The shared RSDD-SELF-DIR idiom (kit #1675) roots a variable: a non -P climb from $_RSDD_SELF is
#        flagged, and the -P'd twin is clean AND counts as a seen climb. (Before #1675's review the idiom's
#        `_RSDD_SELF=` line was never tainted, so every `cd ... "$_RSDD_SELF/.."` climb was invisible.)
box5x="$(mkbox case-rsdd-self-bare)"
cat > "$box5x/fixed.sh" <<'EOF'
#!/usr/bin/env bash
_rsdd_s="${BASH_SOURCE[0]}"
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"
KIT="$(cd -- "$_RSDD_SELF/.." && pwd)"
EOF
OUT5X="$(bash "$SUT" "$box5x" 2>&1)"; RC5X=$?
if [ "$RC5X" -eq 1 ] && <<<"$OUT5X" grep -q 'HIT .*fixed\.sh:4'; then
  ok "5x a non -P climb from \$_RSDD_SELF (the shared idiom) is flagged"
else
  no "5x a bare climb from \$_RSDD_SELF was missed (rc=$RC5X out=[$OUT5X])"
fi
box5y="$(mkbox case-rsdd-self-fixed)"
cat > "$box5y/fixed.sh" <<'EOF'
#!/usr/bin/env bash
_rsdd_s="${BASH_SOURCE[0]}"
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"
KIT="$(cd -P -- "$_RSDD_SELF/.." && pwd -P)"
EOF
OUT5Y="$(bash "$SUT" "$box5y" 2>&1)"; RC5Y=$?
if [ "$RC5Y" -eq 0 ] && ! <<<"$OUT5Y" grep -q 'no-match\|^HIT'; then
  ok "5y the -P'd climb from \$_RSDD_SELF is clean and counts as a seen climb (no no-match)"
else
  no "5y -P'd climb from \$_RSDD_SELF wrongly flagged or reported no-match (rc=$RC5Y out=[$OUT5Y])"
fi

# ── 5r. A `;` inside double quotes, single quotes or backticks is data, not a separator; the splitter
#        must respect nesting: a quoted `;` does not hide a bare climb, and a `;` in a trailing comment
#        is not a statement boundary (it used to yield a false HIT from commented-out text).
box5r="$(mkbox case-quoted-semicolons)"
cat > "$box5r/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/;x/.." && pwd)"
KIT2="$(cd "$(dirname "$0")"/'a;b'/.. && pwd)"
KIT3="$(cd "`dirname "$0"`/.."; pwd)"
X=1 # old; K4="$(cd "$(dirname "$0")/.." && pwd)"
EOF
OUT5R="$(bash "$SUT" "$box5r" 2>&1)"; RC5R=$?
if [ "$RC5R" -eq 1 ] && <<<"$OUT5R" grep -q 'HIT.*fixed\.sh:2' && <<<"$OUT5R" grep -q 'HIT.*fixed\.sh:3' \
   && <<<"$OUT5R" grep -q 'HIT.*fixed\.sh:4' && ! <<<"$OUT5R" grep -q 'HIT.*fixed\.sh:5'; then
  ok "5r quoted/backtick ';' do not hide a bare climb; a ';' after a '#' comment is not a statement"
else
  no "5r quote/backtick/comment handling wrong (rc=$RC5R out=[$OUT5R])"
fi

# ── 5s. Nested substitutions: the OUTER climbing cd is judged on its own text, not on an inner cd's
#        `-P`. A bare outer climb around an inner `cd -P` is a HIT; a `cd -P` outer climb around a
#        bare, non-climbing inner `cd` is clean.
box5s="$(mkbox case-nested-subst)"
cat > "$box5s/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(cd -P "$(dirname "$0")"; pwd)/.."; pwd)"
KIT2="$(cd -P "$(cd "$(dirname "$0")"; pwd)/.."; pwd)"
EOF
OUT5S="$(bash "$SUT" "$box5s" 2>&1)"; RC5S=$?
if [ "$RC5S" -eq 1 ] && <<<"$OUT5S" grep -q 'HIT.*fixed\.sh:2' && ! <<<"$OUT5S" grep -q 'HIT.*fixed\.sh:3'; then
  ok "5s nested \$( ): the outer climbing cd is judged on its own -P, not an inner cd's"
else
  no "5s nested substitution mis-attributed -P (rc=$RC5S out=[$OUT5S])"
fi

# ── 5u. A `..` that reaches `cd` through a NESTED substitution is still the cd's climb (#1921 review):
#        masking the nested body must not hide it. The -P'd twin is clean.
box5u="$(mkbox case-nested-dotdot)"
cat > "$box5u/fixed.sh" <<'EOF'
#!/usr/bin/env bash
K="$(cd "$(echo "$(dirname "$0")/..")" && pwd)"
K2="$(cd -P "$(echo "$(dirname "$0")/..")" && pwd)"
EOF
OUT5U="$(bash "$SUT" "$box5u" 2>&1)"; RC5U=$?
if [ "$RC5U" -eq 1 ] && <<<"$OUT5U" grep -q 'HIT.*fixed\.sh:2' && ! <<<"$OUT5U" grep -q 'HIT.*fixed\.sh:3'; then
  ok "5u a '..' reaching cd through a nested substitution is flagged; the -P'd twin is not"
else
  no "5u nested-substitution '..' mishandled (rc=$RC5U out=[$OUT5U])"
fi

# ── 5v. Quote/substitution context left open (or a `)` that closes nothing) is a TYPED state, never a
#        silent pass (#1921 review): reported as UNCLASSIFIABLE, counted in the summary, exit unchanged.
box5v="$(mkbox case-unclassifiable)"
cat > "$box5v/fixed.sh" <<'EOF'
#!/usr/bin/env bash
echo it's cd pwd
x=$'a\'b'; cd pwd
v=${x//(/y}; cd pwd
a) K="$(cd "$(dirname "$0")/.." && pwd)" ;;
K3="$(cd -P "$(dirname "$0")/.." && pwd)"
EOF
OUT5V="$(bash "$SUT" "$box5v" 2>&1)"; RC5V=$?
if [ "$RC5V" -eq 0 ] && <<<"$OUT5V" grep -q 'UNCLASSIFIABLE .*fixed\.sh:2 ' && <<<"$OUT5V" grep -q 'UNCLASSIFIABLE .*fixed\.sh:3 ' \
   && <<<"$OUT5V" grep -q 'UNCLASSIFIABLE .*fixed\.sh:4 ' && <<<"$OUT5V" grep -q 'UNCLASSIFIABLE .*fixed\.sh:5 ' \
   && ! <<<"$OUT5V" grep -q 'UNCLASSIFIABLE .*fixed\.sh:6 ' && <<<"$OUT5V" grep -q 'unclassifiable=4$'; then
  ok "5v open-quote / \$'..\\'..' / \${x//(/y} / case-arm lines are UNCLASSIFIABLE (counted, exit unchanged); a balanced line is not"
else
  no "5v unclassifiable handling wrong (rc=$RC5V out=[$OUT5V])"
fi
box5v2="$(mkbox case-unclassifiable-casesub)"
cat > "$box5v2/fixed.sh" <<'EOF'
#!/usr/bin/env bash
K=$(case $x in a) cd "$(dirname "$0")/.." ;; esac; pwd)
EOF
OUT5V2="$(bash "$SUT" "$box5v2" 2>&1)"
if <<<"$OUT5V2" grep -q 'UNCLASSIFIABLE .*fixed\.sh:2 '; then
  ok "5v2 a \$(case ... a) ...;; esac) substitution is UNCLASSIFIABLE"
else
  no "5v2 case inside \$( ) not typed unclassifiable (out=[$OUT5V2])"
fi

# ── 5w. Splitter guards (#1921 review): an apostrophe inside double quotes is data; a `;` inside `${ }`
#        is data; a backslash-escaped `;` is data. Each fixture still ends in a bare climb -> HIT.
box5w="$(mkbox case-splitter-guards)"
cat > "$box5w/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/it's/.." && pwd)"
KIT2="$(cd ${x//;/ }"$(dirname "$0")/.." && pwd)"
KIT3="$(cd "$(dirname "$0")"/a\;b/.. && pwd)"
EOF
OUT5W="$(bash "$SUT" "$box5w" 2>&1)"; RC5W=$?
if [ "$RC5W" -eq 1 ] && <<<"$OUT5W" grep -q 'HIT.*fixed\.sh:2' && <<<"$OUT5W" grep -q 'HIT.*fixed\.sh:3' \
   && <<<"$OUT5W" grep -q 'HIT.*fixed\.sh:4'; then
  ok "5w apostrophe in double quotes, ';' inside \${ } and a backslash-escaped ';' do not hide a bare climb"
else
  no "5w splitter guard case missed (rc=$RC5W out=[$OUT5W])"
fi

# ── 5i. climb_seen (formerly the misleadingly-named pattern_seen, kit issue #1024 round 5,
#        general cleanup): a file where EVERY climbing derivation is correctly -P'd must NOT be
#        reported as "no-match" — the construct WAS seen, it just happened to be compliant.
box5i="$(mkbox case-climb-seen-compliant)"
cat > "$box5i/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
echo "$KIT"
EOF
OUT5I="$(bash "$SUT" "$box5i" 2>&1)"; RC5I=$?
if [ "$RC5I" -eq 0 ] && ! <<<"$OUT5I" grep -qi 'no-match'; then
  ok "5i climb_seen: an all-compliant file is NOT reported as no-match (the pattern was seen)"
else
  no "5i climb_seen: an all-compliant file was wrongly reported as no-match (rc=$RC5I out=[$OUT5I])"
fi

# ── 5j. One-line function body (issue #1033 L1): `f(){ local K=...; }` — the leading `f(){ ` and the
#        trailing `; }` used to hide the derivation from the assignment regex.
box5j="$(mkbox case-oneline-function)"
cat > "$box5j/fixed.sh" <<'EOF'
#!/usr/bin/env bash
f(){ local K="$(cd "$(dirname "$0")/.." && pwd)"; }
g() { local K2="$(cd -P "$(dirname "$0")/.." && pwd)"; }
EOF
OUT5J="$(bash "$SUT" "$box5j" 2>&1)"; RC5J=$?
if [ "$RC5J" -eq 1 ] && <<<"$OUT5J" grep -q 'HIT.*fixed\.sh:2' && ! <<<"$OUT5J" grep -q 'HIT.*fixed\.sh:3'; then
  ok "5j one-line function body: the logical climb is flagged, the -P'd twin is not"
else
  no "5j one-line function body was not recognised correctly (rc=$RC5J out=[$OUT5J])"
fi

# ── 5k. Keyword flags (issue #1033 L1): `declare -r A=...`, `local -r B=...`, `declare -rx C=...`.
box5k="$(mkbox case-keyword-flags)"
cat > "$box5k/fixed.sh" <<'EOF'
#!/usr/bin/env bash
declare -r A="$(cd "$(dirname "$0")/.." && pwd)"
local -r B="$(cd "$(dirname "$0")/.." && pwd)"
declare -rx C="$(cd -P "$(dirname "$0")/.." && pwd)"
EOF
OUT5K="$(bash "$SUT" "$box5k" 2>&1)"; RC5K=$?
if [ "$RC5K" -eq 1 ] && <<<"$OUT5K" grep -q 'HIT.*fixed\.sh:2' && <<<"$OUT5K" grep -q 'HIT.*fixed\.sh:3' \
   && ! <<<"$OUT5K" grep -q 'HIT.*fixed\.sh:4'; then
  ok "5k keyword flags (declare -r / local -r): flagged without -P, not flagged with -P"
else
  no "5k keyword flags were not recognised correctly (rc=$RC5K out=[$OUT5K])"
fi

# ── 5l. Tab after `cd` (issue #1033 L1): whitespace is not only a space.
box5l="$(mkbox case-tab-after-cd)"
printf '%s\n' '#!/usr/bin/env bash' \
  "KIT=\"\$(cd	\"\$(dirname \"\$0\")/..\" && pwd)\"" \
  "KIT2=\"\$(cd	-P \"\$(dirname \"\$0\")/..\" && pwd)\"" > "$box5l/fixed.sh"
OUT5L="$(bash "$SUT" "$box5l" 2>&1)"; RC5L=$?
if [ "$RC5L" -eq 1 ] && <<<"$OUT5L" grep -q 'HIT.*fixed\.sh:2' && ! <<<"$OUT5L" grep -q 'HIT.*fixed\.sh:3'; then
  ok "5l tab after cd: flagged without -P, not flagged with -P"
else
  no "5l tab after cd was not recognised correctly (rc=$RC5L out=[$OUT5L])"
fi

# ── 6. Chained two-hop derivation: taint propagates across lines ────────────
box6="$(mkbox case-chained)"
cat > "$box6/chained.sh" <<'EOF'
#!/usr/bin/env bash
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SELF_DIR/.." && pwd)"
echo "$KIT"
EOF
OUT6="$(bash "$SUT" "$box6" 2>&1)"; RC6=$?
if [ "$RC6" -eq 1 ] && <<<"$OUT6" grep -q 'HIT.*chained\.sh:3' \
   && ! <<<"$OUT6" grep -q 'chained\.sh:2'; then
  ok "6 chained derivation: line 3 (the climb) is flagged, line 2 (safe hop) is not"
else
  no "6 chained-derivation taint propagation failed (rc=$RC6 out=[$OUT6])"
fi

# ── 7. dirname of an unrelated variable is excluded ──────────────────────────
box7="$(mkbox case-unrelated)"
cat > "$box7/unrelated.sh" <<'EOF'
#!/usr/bin/env bash
retro="$1"
target_root="$(cd "$(dirname "$(dirname "$retro")")" && pwd)"
echo "$target_root"
EOF
OUT7="$(bash "$SUT" "$box7" 2>&1)"; RC7=$?
if [ "$RC7" -eq 0 ] && ! <<<"$OUT7" grep -q 'HIT'; then
  ok "7 dirname of an unrelated variable (not \$0/BASH_SOURCE) is excluded"
else
  no "7 unrelated dirname was wrongly flagged (rc=$RC7 out=[$OUT7])"
fi

# ── 8. ';'-separated two-statement line: taint propagates on the same line ──
box8="$(mkbox case-semicolon)"
cat > "$box8/semi.sh" <<'EOF'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$here/.." && pwd)"
echo "$KIT"
EOF
OUT8="$(bash "$SUT" "$box8" 2>&1)"; RC8=$?
if [ "$RC8" -eq 1 ] && <<<"$OUT8" grep -q 'HIT.*semi\.sh:2'; then
  ok "8 ';'-separated statement on one physical line: taint propagates, climb flagged"
else
  no "8 ';'-separated statement taint propagation failed (rc=$RC8 out=[$OUT8])"
fi

# ── 9. Allow-marker on the flagged line suppresses the HIT ───────────────────
box9="$(mkbox case-allow-same-line)"
cat > "$box9/allowed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"  # LINT-CD-PHYSICAL-OK: fixture, deliberately harmless
echo "$KIT"
EOF
OUT9="$(bash "$SUT" "$box9" 2>&1)"; RC9=$?
if [ "$RC9" -eq 0 ] && <<<"$OUT9" grep -q 'ALLOWED.*allowed\.sh:2' \
   && ! <<<"$OUT9" grep -q 'HIT'; then
  ok "9 allow-marker on the flagged line suppresses the HIT (ALLOWED, exit 0)"
else
  no "9 same-line allow-marker did not suppress the HIT (rc=$RC9 out=[$OUT9])"
fi

# ── 10. Allow-marker on the line BEFORE the flagged line also works ─────────
box10="$(mkbox case-allow-prev-line)"
cat > "$box10/allowed2.sh" <<'EOF'
#!/usr/bin/env bash
# LINT-CD-PHYSICAL-OK: fixture, deliberately harmless (marker on the line before)
KIT="$(cd "$(dirname "$0")/.." && pwd)"
echo "$KIT"
EOF
OUT10="$(bash "$SUT" "$box10" 2>&1)"; RC10=$?
if [ "$RC10" -eq 0 ] && <<<"$OUT10" grep -q 'ALLOWED.*allowed2\.sh:3' \
   && ! <<<"$OUT10" grep -q 'HIT'; then
  ok "10 allow-marker on the PRECEDING line also suppresses the HIT"
else
  no "10 preceding-line allow-marker did not suppress the HIT (rc=$RC10 out=[$OUT10])"
fi

# ── 11. Allow-marker with no reason text still counts as a HIT ──────────────
box11="$(mkbox case-allow-empty-reason)"
cat > "$box11/emptyreason.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"  # LINT-CD-PHYSICAL-OK:
echo "$KIT"
EOF
OUT11="$(bash "$SUT" "$box11" 2>&1)"; RC11=$?
if [ "$RC11" -eq 1 ] && <<<"$OUT11" grep -q 'HIT.*emptyreason\.sh:2'; then
  ok "11 allow-marker with an empty reason still counts as a HIT (reason is required)"
else
  no "11 empty-reason allow-marker wrongly suppressed the HIT (rc=$RC11 out=[$OUT11])"
fi

# ── 12. absent-input: no scan directory found ────────────────────────────────
OUT12="$(bash "$SUT" "$TMP/does-not-exist-$$" 2>&1)"; RC12=$?
if [ "$RC12" -eq 2 ] && <<<"$OUT12" grep -qi 'absent-input'; then
  ok "12 absent-input: no scan directory found → exit 2, typed message"
else
  no "12 absent-input state not reported (rc=$RC12 out=[$OUT12])"
fi

# ── 13. empty-input: directory exists, no *.sh files ────────────────────────
box13="$(mkbox case-empty)"
printf 'not a shell script\n' > "$box13/readme.txt"
OUT13="$(bash "$SUT" "$box13" 2>&1)"; RC13=$?
if [ "$RC13" -eq 2 ] && <<<"$OUT13" grep -qi 'empty-input'; then
  ok "13 empty-input: directory exists, no *.sh files → exit 2, typed message"
else
  no "13 empty-input state not reported (rc=$RC13 out=[$OUT13])"
fi

# ── 14. no-match: files scanned, pattern never seen ──────────────────────────
box14="$(mkbox case-nomatch)"
cat > "$box14/plain.sh" <<'EOF'
#!/usr/bin/env bash
echo "hello world"
EOF
OUT14="$(bash "$SUT" "$box14" 2>&1)"; RC14=$?
if [ "$RC14" -eq 0 ] && <<<"$OUT14" grep -qi 'no-match'; then
  ok "14 no-match: files scanned, pattern never seen → exit 0, typed message"
else
  no "14 no-match state not reported (rc=$RC14 out=[$OUT14])"
fi

# ── 15. Real-corpus smoke test: bare `verify-cd-physical.sh` on the real kit ────
# kit issue #1024 round 5, Opus finding 1: no whole-file `grep -v` filter here any more — that
# filter hid real hits behind a name match, which is exactly the failure mode this suite exists
# to prevent elsewhere. The DEFAULT SCOPE now excludes tests/ entirely (see the SUT's own header
# comment), so this direct no-argument invocation never reaches this test file's own literal
# heredoc fixtures, or stage-retro.test.sh's (kit issue #976/#984, PR #1029 — not this PR's file),
# or any other *.test.sh's SUT-locating boilerplate — there is nothing left to filter. Assert the
# CHECKER'S OWN EXIT CODE directly (round 5, RDD R4/R3), not a derived "no HIT line" proxy.
OUT15="$(bash "$SUT" 2>&1)"; RC15=$?
if [ "$RC15" -eq 0 ]; then
  ok "15 real-corpus smoke test: bare 'verify-cd-physical.sh' on the real kit exits 0 (no filter, no args)"
else
  no "15 real-corpus smoke test: bare run found un-allow-marked hits (rc=$RC15) — out=[$OUT15]"
fi

# ── 15b. Default-scope exclusion is a DEFAULT, not a capability limit (kit issue #1024 round 5,
#         Opus finding 1): an EXPLICIT tests/ directory argument must still be scanned in full —
#         a real climbing violation placed directly under an explicitly-named tests/ dir must
#         still be caught.
box15b="$(mkbox case-explicit-tests-dir)"
mkdir -p "$box15b/tests"
cat > "$box15b/tests/some.test.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"
EOF
OUT15B="$(bash "$SUT" "$box15b/tests" 2>&1)"; RC15B=$?
if [ "$RC15B" -eq 1 ] && <<<"$OUT15B" grep -q 'HIT.*some\.test\.sh:2'; then
  ok "15b explicit tests/ directory argument is still scanned in full (default-scope exclusion is a default, not a limit)"
else
  no "15b explicit tests/ directory argument was not scanned (rc=$RC15B out=[$OUT15B])"
fi

# ── 15c. Default scope prunes only *.test.sh, so test INFRASTRUCTURE is linted (kit issue #1033 L2).
#         A fake kit tree: a COPY of the SUT inside a temp toolbelt/ (the default scope resolves from the
#         SUT's own physical location), a bad *.test.sh and a bad tests/lib/infra.sh and tests/runner.sh.
#         The bare default run must HIT the infrastructure scripts only — the *.test.sh stays pruned.
kit15c="$TMP/kit15c"; mkdir -p "$kit15c/toolbelt/tests/lib" "$kit15c/install"
cp "$SUT" "$kit15c/toolbelt/verify-cd-physical.sh"
printf '%s\n' '#!/usr/bin/env bash' 'KIT="$(cd "$(dirname "$0")/.." && pwd)"' > "$kit15c/toolbelt/tests/lib/infra.sh"
cp "$kit15c/toolbelt/tests/lib/infra.sh" "$kit15c/toolbelt/tests/runner.sh"
cp "$kit15c/toolbelt/tests/lib/infra.sh" "$kit15c/toolbelt/tests/some.test.sh"
OUT15C="$(bash "$kit15c/toolbelt/verify-cd-physical.sh" 2>&1)"; RC15C=$?
if [ "$RC15C" -eq 1 ] && <<<"$OUT15C" grep -q 'HIT.*tests/lib/infra\.sh:2' \
   && <<<"$OUT15C" grep -q 'HIT.*tests/runner\.sh:2' && ! <<<"$OUT15C" grep -q 'some\.test\.sh'; then
  ok "15c default scope lints tests/ infrastructure (lib/*.sh, runner.sh) and still prunes *.test.sh (#1033 L2)"
else
  no "15c default scope should HIT only the infrastructure scripts (rc=$RC15C out=[$OUT15C])"
fi
# 15c2: the same tree with the infrastructure fixed is clean, and its compliant climbs count as seen.
sed -i 's|cd "\$(dirname "\$0")/.." \&\& pwd|cd -P "$(dirname "$0")/.." \&\& pwd -P|' "$kit15c/toolbelt/tests/lib/infra.sh" "$kit15c/toolbelt/tests/runner.sh"
OUT15C2="$(bash "$kit15c/toolbelt/verify-cd-physical.sh" 2>&1)"; RC15C2=$?
if [ "$RC15C2" -eq 0 ] && <<<"$OUT15C2" grep -q 'scanned=3 files hit=0' && ! <<<"$OUT15C2" grep -q 'no-match'; then
  ok "15c2 fixing the infrastructure makes the fake kit tree clean (exit 0, climbs seen)"
else
  no "15c2 fixed infrastructure should be clean (rc=$RC15C2 out=[$OUT15C2])"
fi

# ── TEETH ─────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: a fixture with a logical (non -P) climbing cd must FAIL; -P must PASS --"
  boxT="$(mkbox teeth-fixture)"
  cat > "$boxT/mut.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"
echo "$KIT"
EOF
  # The -P'd fixture is a MUTANT of the logical one, built by lib/mutant.sh (kit #1299): it refuses an
  # empty, byte-identical, syntax-broken or live-tree mutant and a sed stage that matches nothing. The
  # pristine copy lives in its own directory (outside the scan box) so OUT is not under ORIG's tree.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mkdir -p "$TMP/teeth-orig"; cp "$boxT/mut.sh" "$TMP/teeth-orig/mut.sh"
  OUTT1="$(bash "$SUT" "$boxT" 2>&1)"; RCT1=$?
  if [ "$RCT1" -eq 1 ] && ! grep -qE 'syntax error|command not found|unbound variable' <<<"$OUTT1"; then
    ok "teeth: logical (non -P) fixture makes the lint FAIL — the core distinction has teeth"
  else
    no "teeth: logical (non -P) fixture did NOT fail the lint — check is THEATER (rc=$RCT1 out=[$OUTT1])"
  fi
  # A refused build is counted once and the tooth is skipped, so the un-mutated logical fixture is never judged as the -P one.
  if mutant_chain_or_count fail "teeth: -P fixture" "$TMP/teeth-orig/mut.sh" "$boxT/mut.sh" \
      's/cd "\$(dirname "\$0")\/\.\." \&\& pwd/cd -P "$(dirname "$0")\/.." \&\& pwd -P/'; then
    OUTT2="$(bash "$SUT" "$boxT" 2>&1)"; RCT2=$?
    if [ "$RCT2" -eq 0 ]; then
      ok "teeth: the SAME fixture with -P applied makes the lint PASS — confirms it was the -P that mattered"
    else
      no "teeth: -P'd fixture still fails the lint — check has no bite (rc=$RCT2 out=[$OUTT2])"
    fi
  fi

  # ── issue #1033 L1: each newly recognised form has its own mutant of the SUT that reverts exactly
  # that recognition; the real SUT must exit 1 with a HIT on the fixture and the mutant must exit 0
  # with no HIT (a crash is neither, and --bad-lacks refuses it as a bite).
  CRASH_RE="$(mutant_crash_re bash py cmd)" || exit 2
  mkdir -p "$TMP/l1-mut"
  tt() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  l1_tooth() { # <label> <fixture-box> <sed-expr>
    if mutant_chain_or_count fail "teeth L1: $1" "$SUT" "$TMP/l1-mut/$1.sh" "$3"; then
      tt "teeth L1: $1 recognition removed makes the fixture pass unflagged" 1 0 "$TMP/l1-mut/$1.sh" \
        --good-has 'HIT .*fixed\.sh:2' --bad-lacks "HIT|$CRASH_RE" -- bash @SUT@ "$2"
    fi
  }
  # #1033 follow-ups: each fixed behaviour gets a mutant that reverts exactly it.
  fu_tooth() { # <label> <fixture-box> <hit-line> <sed-expr> [<mutant-rc>]
    if mutant_chain_or_count fail "teeth FU: $1" "$SUT" "$TMP/l1-mut/$1.sh" "$4"; then
      tt "teeth FU: $1 reverted makes the fixture lose that HIT" 1 "${5:-0}" "$TMP/l1-mut/$1.sh" \
        --good-has "HIT .*fixed\.sh:$3" --bad-lacks "HIT .*fixed\.sh:$3|$CRASH_RE" -- bash @SUT@ "$2"
    fi
  }
  # line 2 (`local`) still hits in the mutant, so the exit code stays 1: the bite is the lost line-3 HIT.
  # #1675: the idiom recognition has a mutant that reverts exactly it (the `_RSDD_SELF=` line is no longer rooted).
  fu_tooth rsdd-self-taint "$box5x" 4 "$(cat <<'EOF'
s#\*'"\$_rsdd_s"'\*#*'@never@'*#
EOF
)"
  fu_tooth export-prefix "$box5g" 3 's/(local|export|/(local|/' 1
  fu_tooth second-climb "$box5m" 2 's/^          _climb_ok=1$/          _climb_ok=1; break/'
  fu_tooth or-pipe-split "$box5o" 2 "s#elif \[ \"\$c\" = '|' \]; then#elif [ \"\$c\" = '@' ]; then#"
  # #1921: each splitter property has a mutant that reverts exactly it.
  fu_tooth semicolon-in-subst "$box5p" 2 's#if \[ "\$c" = '"';'"' \] \&\& \[ -z "\$stack" \]; then#if [ "$c" = '"';'"' ]; then#'
  fu_tooth quote-context "$box5r" 2 's#if \[ "\$top" = d \]; then stack="\${stack%?}"; else stack+=d; fi#:#' 1
  fu_tooth nested-mask "$box5s" 2 's#_cdp_open '"'"'\$(…)'"'"' #_cdp_open '"'"'$(cd -P x)'"'"' #'
  if mutant_chain_or_count fail "teeth FU: comment-kept" "$SUT" "$TMP/l1-mut/comment-kept.sh" 's#break  \# comment: drop the rest#:#'; then
    tt "teeth FU: a kept comment makes the commented-out derivation a bogus HIT" 1 1 "$TMP/l1-mut/comment-kept.sh" \
      --good-lacks 'HIT .*fixed\.sh:5' --bad-has 'HIT .*fixed\.sh:5' -- bash @SUT@ "$box5r"
  fi
  # 5h2: the glob-expanding split (the pre-round-5 code) must bite when the box is the cwd.
  if mutant_chain_or_count fail "teeth FU: glob-split" "$SUT" "$TMP/l1-mut/glob-split.sh" 's#local -a _stmts=("\${_CDP_PARTS\[@\]}")#local -a _stmts=(${line//;/ })#'; then
    tt "teeth FU: glob-expanding split makes the filename-shaped file a bogus HIT" 0 1 "$TMP/l1-mut/glob-split.sh" \
      --bad-has 'HIT .*fixed\.sh:2' -- bash -c 'cd "$1" && bash "$2" "$1"' _ "$box5h2" @SUT@
  fi
  # #1921 review: one mutant per guard / typed state.
  fu_tooth raw-dotdot "$box5u" 2 's#\[\[ "\${_CDP_RAW\[\$_si\]}" == \*"\.\."\* \]\]#[[ "$seg" == *".."* ]]#'
  # The unguarded apostrophe opens a bogus single-quote context: the line stays a HIT but becomes UNCLASSIFIABLE.
  if mutant_chain_or_count fail "teeth FU: apostrophe-in-dq" "$SUT" "$TMP/l1-mut/apostrophe-in-dq.sh" 's# \&\& \[ "\$top" != d \]; then#; then#'; then
    tt "teeth FU: apostrophe-in-dq guard removed makes a balanced line UNCLASSIFIABLE" 1 1 "$TMP/l1-mut/apostrophe-in-dq.sh" \
      --good-lacks 'UNCLASSIFIABLE .*fixed\.sh:2 ' --bad-has 'UNCLASSIFIABLE .*fixed\.sh:2 ' -- bash @SUT@ "$box5w"
  fi
  fu_tooth brace-context "$box5w" 3 's#if \[ "\$top" != c \]; then#if true; then#' 1
  fu_tooth backslash-escape "$box5w" 4 's#if \[ "\$c" = '"'"'\\'"'"' \]; then#if false; then#' 1
  unc_tooth() { # <label> <fixture-box> <line> <sed-expr>
    if mutant_chain_or_count fail "teeth FU: $1" "$SUT" "$TMP/l1-mut/$1.sh" "$4"; then
      tt "teeth FU: $1 reverted loses the UNCLASSIFIABLE report for line $3" 0 0 "$TMP/l1-mut/$1.sh" \
        --good-has "UNCLASSIFIABLE .*fixed\\.sh:$3 " --bad-lacks "UNCLASSIFIABLE .*fixed\\.sh:$3 |$CRASH_RE" -- bash @SUT@ "$2"
    fi
  }
  unc_tooth open-context "$box5v" 2 's#\[ -n "\$stack" \] \&\& _CDP_OPEN=1#:#'
  unc_tooth stray-paren "$box5v" 5 's#\[ "\$c" = '"')'"' \] \&\& _CDP_OPEN=1#:#'
  # #1033 L2: the default scope must lint tests/ infrastructure. The mutant restores the old whole-directory
  # tests/ prune; the tooth copies whichever SUT it is handed into a fake kit tree (the default scope resolves
  # from the SUT's own location) holding a bad tests/lib/infra.sh, so only the real SUT HITs it.
  kitL2="$TMP/kit-l2"; mkdir -p "$kitL2/toolbelt/tests/lib"
  printf '%s\n' '#!/usr/bin/env bash' 'KIT="$(cd "$(dirname "$0")/.." && pwd)"' > "$kitL2/toolbelt/tests/lib/infra.sh"
  cp "$kitL2/toolbelt/tests/lib/infra.sh" "$kitL2/toolbelt/tests/bad.test.sh"
  if mutant_chain_or_count fail "teeth L2: whole-tests-dir prune" "$SUT" "$TMP/l1-mut/l2-prune.sh" \
      "s#find \"\$d\" -type f -name '\*.sh' -not .*-print 2>/dev/null#find \"\$d\" -type d -name tests -prune -o -type f -name '*.sh' -print 2>/dev/null#"; then
    tt "teeth L2: restoring the whole-tests/ prune hides the infrastructure HIT" 1 0 "$TMP/l1-mut/l2-prune.sh" \
      --good-has 'HIT .*tests/lib/infra\.sh:2' --bad-lacks "HIT|$CRASH_RE" \
      -- bash -c 'cp "$1" "$2/toolbelt/verify-cd-physical.sh" && bash "$2/toolbelt/verify-cd-physical.sh" 2>&1' _ @SUT@ "$kitL2"
  fi
  # ...and the converse: dropping the *.test.sh exclusion scans the suites' heredoc fixtures again.
  if mutant_chain_or_count fail "teeth L2: no *.test.sh exclusion" "$SUT" "$TMP/l1-mut/l2-all.sh" \
      "s#-not .( -path '\*/tests/\*' -name '\*.test.sh' .) ##"; then
    tt "teeth L2: dropping the *.test.sh exclusion makes the suite a bogus HIT" 1 1 "$TMP/l1-mut/l2-all.sh" \
      --good-lacks 'bad\.test\.sh' --bad-has 'HIT .*tests/bad\.test\.sh:2' \
      -- bash -c 'cp "$1" "$2/toolbelt/verify-cd-physical.sh" && bash "$2/toolbelt/verify-cd-physical.sh" 2>&1' _ @SUT@ "$kitL2"
  fi
  l1_tooth funchead "$box5j" 's|(\\{\[\[:space:\]\]\*)?|(ZZ)?|'
  l1_tooth kwflags "$box5k" 's|(\[\[:space:\]\]+-\[A-Za-z\]+)\*|(ZZ)*|'
  # BRE: `|` is a literal here (`\|` would be GNU alternation and match everywhere), so it is unescaped.
  l1_tooth tabcd "$box5l" 's#\[\[ "\$code" =~ cd\[\[:space:\]\] ||#[[ "$code" == *"cd "* ||#'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
