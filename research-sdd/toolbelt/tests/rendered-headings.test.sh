#!/usr/bin/env bash
# rendered-headings.test.sh — exactly-once heading assertions on the RENDERED profiles and the
# installed SKILL, plus a forbidden-leak list (kit issue #1713; evidence B33 cand. 20, B34 §34.6).
#
# profile-invariants.test.sh proves doctrine tokens and presence/absence of specific phrases; it
# never counted headings, so a section duplicated by a bad slot substitution, or a retired/internal
# string leaking into a rendered prompt, could pass every existing check.
#
# This suite renders every profile (claude + each profiles/*.slots.md) with the REAL render-profile.sh
# into a temp dir (never the live tree or $HOME) and, per rendered SKILL.md / PROMPT-LOOP.md /
# METHODOLOGY.md, asserts:
#   H1  every heading listed in fixtures/rendered-headings/required-<FILE>.txt appears EXACTLY once
#       (0 = missing, >1 = duplicated; both fail)
#   H2  no level 1-2 heading appears more than once, listed or not
#   H3  every kind=heading entry of fixtures/rendered-headings/forbidden.txt is absent
#   H4  every kind=string entry of forbidden.txt is absent (case-insensitive, fixed string)
#   H0  the rendered file yields at least one heading (anti-silent-zero: a parser that saw nothing
#       must not read as "no duplicates")
# Headings are level 1-2 lines outside ``` / ~~~ code fences (a fenced `## x` example is not a
# heading and must neither satisfy nor violate a check).
#
# Typed exit 2 = the suite could not run (render failed, fixture list missing/empty, python3 absent):
# could-not-run is never a pass.
#
# --prove-teeth: mutants are built from the real rendered SKILL.md by lib/mutant.sh into a sibling
# temp dir: duplicated first / last heading, deleted first / last heading, injected forbidden
# heading, injected forbidden string; each must make the REAL check go red. A fenced duplicate
# heading must stay green (the fence rule has a tooth too).
#
# Usage: rendered-headings.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 could not run.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout (kit issue #1024 round 5)
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout (kit issue #1024 round 5)
KIT="$(cd "$TOOLBELT/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout (kit issue #1024 round 5)
RENDERER="$TOOLBELT/render-profile.sh"
PROFILES_DIR="$KIT/profiles"
FIX="$HERE/fixtures/rendered-headings"
FORBIDDEN="$FIX/forbidden.txt"

die() { printf 'FATAL (exit 2, could not run): %s\n' "$1" >&2; exit 2; }

[ -x "$RENDERER" ] || die "render-profile.sh missing or not executable: $RENDERER"
[ -d "$PROFILES_DIR" ] || die "profiles directory not found: $PROFILES_DIR"
command -v python3 >/dev/null || die "python3 required"
[ -s "$FORBIDDEN" ] || die "forbidden list missing or empty: $FORBIDDEN"
grep -qvE '^[[:space:]]*(#|$)' "$FORBIDDEN" || die "forbidden list has no entries (anti-silent-zero): $FORBIDDEN"
for f in SKILL PROMPT-LOOP METHODOLOGY; do
  [ -s "$FIX/required-$f.txt" ] || die "required-heading list missing or empty: $FIX/required-$f.txt"
done
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_built || die "lib/mutant.sh bootstrap failed (see the mutant_bootstrap FATAL line above)"

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

PROVE_TEETH=0
[ "${1:-}" = "--prove-teeth" ] && PROVE_TEETH=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== rendered-headings.test.sh =="

# list_headings FILE — level 1-2 headings outside code fences, one per line, trailing space trimmed.
list_headings() {
  python3 - "$1" <<'PYEOF'
import re, sys
# CommonMark fence rule: an opening fence is 3+ backticks or tildes (an info string is allowed);
# it closes only on the SAME char, at least as long, with nothing but whitespace after it.
fence = None  # (char, length) while inside a fence
for line in open(sys.argv[1], encoding='utf-8').read().split('\n'):
    m = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
    if m:
        marker, rest = m.group(1), m.group(2)
        if fence is None:
            fence = (marker[0], len(marker))
        elif marker[0] == fence[0] and len(marker) >= fence[1] and rest.strip() == '':
            fence = None
        continue
    if fence is not None:
        continue
    # CommonMark ATX level 1-2: 0-3 leading spaces (4+ is code), hashes, then a space/tab or end of
    # line (a bare '#' / '##' is a heading, '###' is not). Normalised to '<hashes> <text>': whitespace
    # after the hashes collapsed, optional closing '#' sequence and trailing whitespace stripped.
    h = re.match(r'^ {0,3}(#{1,2})(?=[ \t]|$)(.*)$', line)
    if h:
        text = re.sub(r'(^|[ \t]+)#+[ \t]*$', '', h.group(2)).strip(' \t')
        print(h.group(1) + (' ' + text if text else ''))
PYEOF
}

# check_file FILE REQLIST — prints one line per violation; returns 0 clean, 1 violations, 2 could not look.
check_file() {
  local file="$1" req="$2" heads line n bad=0 kind text reason
  [ -r "$file" ] || { echo "cannot read $file"; return 2; }
  [ -s "$req" ] || { echo "required list empty/missing: $req"; return 2; }
  heads="$(list_headings "$file")" || { echo "heading extraction failed on $file"; return 2; }
  if [ -z "$heads" ]; then echo "H0: zero headings found in $file (anti-silent-zero)"; return 1; fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    n="$(grep -cxF -- "$line" <<<"$heads")"
    if [ "$n" -ne 1 ]; then echo "H1: '$line' appears $n times (want exactly 1)"; bad=1; fi
  done <"$req"
  while IFS= read -r line; do
    echo "H2: duplicated heading '$line'"; bad=1
  done < <(sort <<<"$heads" | uniq -d)
  while IFS='|' read -r kind text reason || [ -n "$kind" ]; do
    case "$kind" in ''|'#'*) continue ;; esac
    [ -n "$text" ] || { echo "malformed forbidden entry (empty text): $kind"; return 2; }
    case "$kind" in
      heading) grep -qxF -- "$text" <<<"$heads" && { echo "H3: forbidden heading '$text' present ($reason)"; bad=1; } ;;
      string)  grep -qiF -- "$text" "$file" && { echo "H4: forbidden string '$text' present ($reason)"; bad=1; } ;;
      *) echo "malformed forbidden entry (unknown kind '$kind')"; return 2 ;;
    esac
  done <"$FORBIDDEN"
  [ "$bad" -eq 0 ]
}

# ---- render every profile with the REAL renderer -------------------------------------------------
PROFILE_NAMES=(claude)
shopt -s nullglob
for f in "$PROFILES_DIR"/*.slots.md; do PROFILE_NAMES+=("$(basename "$f" .slots.md)"); done
shopt -u nullglob
[ "${#PROFILE_NAMES[@]}" -gt 1 ] || die "no custom profile found under $PROFILES_DIR (anti-silent-zero)"

declare -A OUTDIR
for name in "${PROFILE_NAMES[@]}"; do
  OUTDIR["$name"]="$TMP/render/$name"
  out="$("$RENDERER" "$name" "${OUTDIR[$name]}" 2>&1)" || die "render-profile.sh failed for profile '$name': $out"
done

rendered_path() {  # PROFILE FILE
  case "$2" in
    SKILL) printf '%s/skills/research-sdd/SKILL.md' "${OUTDIR[$1]}" ;;
    *)     printf '%s/%s.md' "${OUTDIR[$1]}" "$2" ;;
  esac
}

for name in "${PROFILE_NAMES[@]}"; do
  for f in SKILL PROMPT-LOOP METHODOLOGY; do
    path="$(rendered_path "$name" "$f")"
    out="$(check_file "$path" "$FIX/required-$f.txt")"; rc=$?
    case "$rc" in
      0) ok "$name/$f: every required heading exactly once, no duplicate, no forbidden heading/string" ;;
      1) no "$name/$f: $(tr '\n' ';' <<<"$out")" ;;
      *) die "check_file could not look at $path: $out" ;;
    esac
  done
done

# ---- teeth ----------------------------------------------------------------------------------------
if [ "$PROVE_TEETH" -eq 1 ]; then
  echo "-- teeth: mutated renders must go RED through the REAL check_file --"
  ORIG="$(rendered_path claude SKILL)"
  REQ="$FIX/required-SKILL.txt"
  FIRST="$(head -n1 "$REQ")"; LAST="$(tail -n1 "$REQ")"
  MUT="$TMP/mut"; mkdir -p "$MUT"
  [ "$FIRST" = "# Research-SDD launcher" ] && [ "$LAST" = "## Boundaries" ] \
    || no "teeth anchors: first/last required SKILL heading drifted ('$FIRST' / '$LAST'); update the mutants below"

  if check_file "$ORIG" "$REQ" >/dev/null 2>&1; then
    ok "teeth-good: the unmutated claude SKILL.md passes check_file"
  else
    no "teeth-good: the unmutated claude SKILL.md already fails check_file — no tooth would prove anything"
  fi

  # tooth LABEL WANT_RE EXPR — mutate ORIG with one sed EXPR; check_file must exit 1 and mention WANT_RE.
  tooth() {
    local label="$1" want="$2" expr="$3" out rc
    MUTANT_SYNTAX=none mutant_chain "$label" "$ORIG" "$MUT/$label.md" "$expr" || { fail=$((fail+1)); return 1; }
    out="$(check_file "$MUT/$label.md" "$REQ")"; rc=$?
    if [ "$rc" -eq 1 ] && grep -qE -- "$want" <<<"$out"; then
      ok "teeth-$label: check_file goes RED ($want)"
    else
      no "teeth-$label: rc=$rc out='$out' — expected rc=1 matching /$want/"
    fi
  }
  tooth dup-first-heading  "^H1: '# Research-SDD launcher' appears 2 times" 's/^# Research-SDD launcher$/&\n\n# Research-SDD launcher/'
  tooth dup-last-heading   "^H1: '## Boundaries' appears 2 times"           's/^## Boundaries$/&\n\n## Boundaries/'
  # '## Zz unlisted probe' is in NO required list, so only H2 can catch its duplication.
  MUTANT_SYNTAX=none mutant_chain "dup-unlisted" "$ORIG" "$MUT/dup-unlisted.md" 's/^## Arguments$/&\n\n## Zz unlisted probe\n\nx\n\n## Zz unlisted probe/' || fail=$((fail+1))
  out="$(check_file "$MUT/dup-unlisted.md" "$REQ")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q "^H2: duplicated heading '## Zz unlisted probe'" <<<"$out" && ! grep -q '^H1:' <<<"$out"; then
    ok "teeth-dup-unlisted: H2 (and only H2) catches a duplicate heading absent from the required list"
  else
    no "teeth-dup-unlisted: rc=$rc out='$out' — expected H2 for an unlisted heading and no H1"
  fi
  tooth missing-first      "^H1: '# Research-SDD launcher' appears 0 times" '/^# Research-SDD launcher$/d'
  tooth missing-last       "^H1: '## Boundaries' appears 0 times"           '/^## Boundaries$/d'
  tooth forbidden-heading  "^H3: forbidden heading '## OpenCode adapter'"   's/^## Arguments$/&\n\n## OpenCode adapter/'
  tooth forbidden-string   "^H4: forbidden string 'opencode'"               's/^## Arguments$/&\n\nsee the OpenCode docs/'
  tooth forbidden-string-last "^H4: forbidden string 'RSDD_KIT_DIR'"        '$a\
RSDD_KIT_DIR=/x'

  # Fence rule: a fenced '## Boundaries' is not a heading — appending one must stay GREEN, and
  # deleting the real one while a fenced copy remains must still go RED (H1 ... 0 times).
  if MUTANT_SYNTAX=none mutant_chain "fenced-dup" "$ORIG" "$MUT/fenced-dup.md" '$a\
\
```\
## Boundaries\
```'; then
    if check_file "$MUT/fenced-dup.md" "$REQ" >/dev/null 2>&1; then
      ok "teeth-fenced-dup: a fenced duplicate heading is ignored (stays green)"
    else
      no "teeth-fenced-dup: a heading inside a code fence was counted"
    fi
  else fail=$((fail+1)); fi
  if MUTANT_SYNTAX=none mutant_chain "fenced-only" "$ORIG" "$MUT/fenced-only.md" '/^## Boundaries$/c\
```\
## Boundaries\
```'; then
    out="$(check_file "$MUT/fenced-only.md" "$REQ")"; rc=$?
    if [ "$rc" -eq 1 ] && grep -q "^H1: '## Boundaries' appears 0 times" <<<"$out"; then
      ok "teeth-fenced-only: a fenced heading does not satisfy a required heading"
    else
      no "teeth-fenced-only: rc=$rc out='$out'"
    fi
  else fail=$((fail+1)); fi

  # Fence close rule: a "closing" fence with an info string, or a shorter one, does NOT close the block,
  # so the heading after it is still fenced (not counted); a proper longer close does close it.
  fence_green() {  # LABEL BODY — append BODY to the SKILL render; check_file must stay green (fence never closed early).
    MUTANT_SYNTAX=none mutant_chain "$1" "$ORIG" "$MUT/$1.md" "$2" || { fail=$((fail+1)); return 1; }
    if check_file "$MUT/$1.md" "$REQ" >/dev/null 2>&1; then ok "teeth-$1: fence not closed early (headings inside stay ignored)"
    else no "teeth-$1: a non-closing fence line closed the block and its headings were counted"; fi
  }
  fence_green fence-info-close '$a\
\
```\
```text\
## Zz unlisted probe\
## Zz unlisted probe\
```'
  fence_green fence-short-close '$a\
\
````\
```\
## Zz unlisted probe\
## Zz unlisted probe\
````'
  if MUTANT_SYNTAX=none mutant_chain "fence-long-close" "$ORIG" "$MUT/fence-long-close.md" '$a\
\
```\
x\
`````\
\
## Zz unlisted probe\
\
## Zz unlisted probe'; then
    out="$(check_file "$MUT/fence-long-close.md" "$REQ")"; rc=$?
    if [ "$rc" -eq 1 ] && grep -q "^H2: duplicated heading '## Zz unlisted probe'" <<<"$out"; then
      ok "teeth-fence-long-close: a longer same-char fence closes the block (later headings count)"
    else no "teeth-fence-long-close: rc=$rc out='$out'"; fi
  else fail=$((fail+1)); fi

  # CommonMark ATX variants: each must be normalised and counted; 4+ leading spaces is code, not a heading.
  tooth indented-dup        "^H1: '## Arguments' appears 2 times"          's/^## Arguments$/&\n\n  ## Arguments/'
  tooth tab-forbidden       "^H3: forbidden heading '## OpenCode adapter'" 's/^## Arguments$/&\n\n##\tOpenCode adapter/'
  tooth closing-hash-dup    "^H1: '## Boundaries' appears 2 times"         's/^## Boundaries$/&\n\n## Boundaries ##/'
  tooth multispace-dup      "^H1: '## Boundaries' appears 2 times"         's/^## Boundaries$/&\n\n##    Boundaries   /'
  tooth bare-hash-dup       "^H2: duplicated heading '#'"                  's/^## Arguments$/&\n\n#\n\nx\n\n#/'
  if MUTANT_SYNTAX=none mutant_chain "indent4-code" "$ORIG" "$MUT/indent4-code.md" 's/^## Boundaries$/&\n\n    ## Boundaries/'; then
    if check_file "$MUT/indent4-code.md" "$REQ" >/dev/null 2>&1; then
      ok "teeth-indent4-code: a 4-space-indented '## x' line is code, not a heading (stays green)"
    else no "teeth-indent4-code: a 4-space-indented line was counted as a heading"; fi
  else fail=$((fail+1)); fi

  # Anti-silent-zero: a render with no headings at all is a failure, never a clean zero.
  printf 'no headings here\n' >"$MUT/noheads.md"
  out="$(check_file "$MUT/noheads.md" "$REQ")"; rc=$?
  if [ "$rc" -eq 1 ] && grep -q '^H0:' <<<"$out"; then ok "teeth-zero-headings: H0 fires on a heading-less file"
  else no "teeth-zero-headings: rc=$rc out='$out'"; fi

  # Typed could-not-run: an unreadable input is rc 2, never 0.
  out="$(check_file "$MUT/does-not-exist.md" "$REQ")"; rc=$?
  if [ "$rc" -eq 2 ]; then ok "teeth-absent-input: check_file returns rc 2 for an absent file"
  else no "teeth-absent-input: rc=$rc (want 2)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
