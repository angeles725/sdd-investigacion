#!/usr/bin/env bash
# sweep-tools.test.sh — red-first harness for sweep-tools.sh + lib/target-paths.sh.
# Covers: abs paths, $RESEARCH_HOME form, anti-silent-zero doctrine, T-row recording,
# PARTIAL WARN, fail-closed lib, and mutation proof via --prove-teeth.
# Exit: 0 = every assertion held · 1 = regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-tools.sh"
LIB="$HERE/../lib/target-paths.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkkit() {
  local kit="$ROOT/$1"
  mkdir -p "$kit/toolbelt/lib"
  cp "$SUT" "$kit/toolbelt/sweep-tools.sh"
  cp "$LIB" "$kit/toolbelt/lib/target-paths.sh"
  printf '%s' "$kit"
}

write_targets() {
  local kit="$1"; shift
  { printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
    local i=0 t
    for t in "$@"; do i=$((i+1)); printf '| %d | t%d | `%s` |\n' "$i" "$i" "$t"; done
  } > "$kit/TARGETS.md"
}

mktool() {
  local tgt="$1" name="$2"
  mkdir -p "$tgt/tools"
  printf '#!/usr/bin/env bash\n# tool %s\n' "$name" > "$tgt/tools/$name"
  [ "${3:-}" = "--exec" ] && chmod +x "$tgt/tools/$name" || true
}

mkretro_trow() {
  local tgt="$1" fname="$2" tool="$3"
  mkdir -p "$tgt/retros"
  { printf '<!-- review-status: applied 2026-01-01 -->\n# Retro\n\n'
    printf '## Tools built, adapted, or outgrown\n\n'
    printf '| # | CREATED | ADAPTED | OUTGREW | ORACLE | VERDICT |\n|---|---|---|---|---|---|\n'
    printf '| T1 | `tools/%s` · purpose | — | — | — | keep-local |\n' "$tool"
  } > "$tgt/retros/$fname"
}

run() { OUT="$("$BASH_BIN" "$1/toolbelt/sweep-tools.sh" 2>&1)"; RC=$?; }

echo "== sweep-tools.test.sh (SUT: $(basename "$SUT")) =="

# 1 — ABS PATH: one .py and one .sh → count 2, summary correct.
kit="$(mkkit c1-abs)"; tgt="$kit/targetA"
mktool "$tgt" "scan.py"; mktool "$tgt" "extract.sh"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'TARGET.*targetA' <<<"$OUT" \
   && grep -q 'tools: 2 found' <<<"$OUT" \
   && grep -q 'Summary:.*2 tool(s).*1 target' <<<"$OUT"; then
  ok "1 abs path + 2 tools → found, summary correct" "(exit $RC)"
else
  no "1 abs path + 2 tools → found, summary correct" "exit=$RC out=[$OUT]"
fi

# 2 — $RESEARCH_HOME form: TARGETS.md carries the env-var token; SUT must expand it.
kit="$(mkkit c2-rh)"; rh_base="$ROOT/rh-base"; tgt="$rh_base/targetB"
mktool "$tgt" "probe.sh"
write_targets "$kit" '$RESEARCH_HOME/targetB'
OUT="$(RESEARCH_HOME="$rh_base" "$BASH_BIN" "$kit/toolbelt/sweep-tools.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && grep -q 'TARGET.*targetB' <<<"$OUT" \
   && grep -q 'tools: 1 found' <<<"$OUT" \
   && grep -q 'Summary:.*1 tool' <<<"$OUT"; then
  ok "2 \$RESEARCH_HOME path form → expanded, tool found" "(exit $RC)"
else
  no "2 \$RESEARCH_HOME path form → expanded, tool found" "exit=$RC out=[$OUT]"
fi

# 3 — NO tools/ directory → distinct "no tools directory" (not "0 found").
kit="$(mkkit c3-nodir)"; tgt="$kit/targetA"
mkdir -p "$tgt"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'no tools directory' <<<"$OUT"; then
  ok "3 no tools/ directory → distinct 'no tools directory' message" "(exit $RC)"
else
  no "3 no tools/ directory → distinct 'no tools directory' message" "exit=$RC out=[$OUT]"
fi

# 4 — tools/ EXISTS but EMPTY → "exists but is empty", not "no tools directory".
kit="$(mkkit c4-empty)"; tgt="$kit/targetA"
mkdir -p "$tgt/tools"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'exists but is empty' <<<"$OUT" \
   && ! grep -q 'no tools directory' <<<"$OUT"; then
  ok "4 empty tools/ → 'exists but is empty', not 'no tools directory'" "(exit $RC)"
else
  no "4 empty tools/ → 'exists but is empty', not 'no tools directory'" "exit=$RC out=[$OUT]"
fi

# 5 — PREDICATE REJECTS. tools/ has a file that matches no extension and has no exec bit → must
#     report count of rejects, not silently zero. A bare 0-tool count that could mean predicate
#     rejection is a bug (anti-silent-zero).
kit="$(mkkit c5-reject)"; tgt="$kit/targetA"
mkdir -p "$tgt/tools"
printf 'data\n' > "$tgt/tools/data.csv"   # not .py/.sh/.mjs/.js/.ts/.ps1, not executable
mktool "$tgt" "real.py"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'tools: 1 found' <<<"$OUT" \
   && grep -qE '1 non-tool file' <<<"$OUT"; then
  ok "5 predicate reject → count shown separately (anti-silent-zero)" "(exit $RC)"
else
  no "5 predicate reject → count shown separately (anti-silent-zero)" "exit=$RC out=[$OUT]"
fi

# 6 — T-ROW RECORDING. One tool recorded in a retro T-row, one not → 1 recorded / 1 unrecorded.
kit="$(mkkit c6-recording)"; tgt="$kit/targetA"
mktool "$tgt" "recorded.py"
mktool "$tgt" "unrecorded.sh"
mkretro_trow "$tgt" "r1.md" "recorded.py"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'recorded (T-rows): 1' <<<"$OUT" \
   && grep -q 'unrecorded: 1' <<<"$OUT" \
   && grep -q 'Summary:.*2 tool(s).*1 recorded.*1 unrecorded' <<<"$OUT"; then
  ok "6 T-row recording → 1 recorded / 1 unrecorded" "(exit $RC)"
else
  no "6 T-row recording → 1 recorded / 1 unrecorded" "exit=$RC out=[$OUT]"
fi

# 7 — MISSING TARGETS.md → exit non-zero, error message, no summary.
kit="$(mkkit c7-notargets)"
run "$kit"
if [ "$RC" != 0 ] && grep -qi 'cannot find\|ERROR\|not found' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "7 missing TARGETS.md → error, no summary" "(exit $RC)"
else
  no "7 missing TARGETS.md → error, no summary" "exit=$RC out=[$OUT]"
fi

# 8 — ZERO RESOLVABLE PATHS. All paths are truncated '...' → zero usable paths → LOUD exit 1.
kit="$(mkkit c8-zeropaths)"
{ printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
  printf '| 1 | t1 | `/home/user/.../research` |\n'
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" != 0 ] && grep -qiE 'ERROR|no.*path|zero' <<<"$OUT"; then
  ok "8 zero resolvable paths → loud exit 1" "(exit $RC)"
else
  no "8 zero resolvable paths → loud exit 1" "exit=$RC out=[$OUT]"
fi

# 9 — TRUNCATED PATH → PARTIAL WARN. One real target + one truncated '...' path → WARN.
kit="$(mkkit c9-partial)"; tgt="$kit/targetA"
mktool "$tgt" "scan.sh"
{ printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
  printf '| 1 | t1 | `%s` |\n' "$tgt"
  printf '| 2 | t2 | `/home/user/.../truncated` |\n'
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN:.*1 target\(s\) skipped.*PARTIAL' <<<"$OUT" \
   && grep -q 'truncated' <<<"$OUT"; then
  ok "9 truncated path → PARTIAL WARN, real target still processed" "(exit $RC)"
else
  no "9 truncated path → PARTIAL WARN, real target still processed" "exit=$RC out=[$OUT]"
fi

# 10 — BROKEN LIB. target-paths.sh exists but defines no function → fail-closed abort.
kit="$(mkkit c10-brokenlib)"; tgt="$kit/targetA"
mktool "$tgt" "scan.py"
write_targets "$kit" "$tgt"
printf '#!/usr/bin/env bash\n# broken: no function defined\n' > "$kit/toolbelt/lib/target-paths.sh"
run "$kit"
if [ "$RC" != 0 ] && grep -q 'failed to define target_paths_all' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "10 broken lib → fail-closed abort, no summary" "(exit $RC)"
else
  no "10 broken lib → fail-closed abort, no summary" "exit=$RC out=[$OUT]"
fi

# 11 — NO RETRO TOOLS TABLE. Retros exist but none has T-rows → distinct "no retro has a tools table".
kit="$(mkkit c11-notable)"; tgt="$kit/targetA"
mktool "$tgt" "scan.py"
mkdir -p "$tgt/retros"
printf '<!-- review-status: applied 2026-01-01 -->\n# Retro\n\nNo tools table here.\n' \
  > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'no retro has a tools table' <<<"$OUT"; then
  ok "11 retros exist but no T-table → distinct message" "(exit $RC)"
else
  no "11 retros exist but no T-table → distinct message" "exit=$RC out=[$OUT]"
fi

# Teeth (mutation proof): only when --prove-teeth is passed.
if [ "${1:-}" = "--prove-teeth" ]; then
  # Tooth A: break extension matching → case-1 fixture (2 tools) must report 0, not 2.
  kit_m="$(mkkit teeth-a)"; tgt_m="$kit_m/targetA"
  mktool "$tgt_m" "scan.py"; mktool "$tgt_m" "extract.sh"
  write_targets "$kit_m" "$tgt_m"
  sed 's/\*\.py|\*\.sh|/NOMATCH|/' "$SUT" > "$kit_m/toolbelt/sweep-tools.sh"
  out_m="$("$BASH_BIN" "$kit_m/toolbelt/sweep-tools.sh" 2>&1)"
  if ! grep -q 'tools: 2 found' <<<"$out_m"; then
    ok "teeth A: extension-broken mutant misses tools → case 1 goes red" "()"
  else
    no "teeth A: mutant still found 2 tools — case 1 is THEATER" "out=[$out_m]"
  fi

  # Tooth B: Form-1-only mutant lib (no $RESEARCH_HOME expansion) → case-2 must fail.
  kit_b="$(mkkit teeth-b)"; tgt_b="$ROOT/rh-base/targetB"
  mktool "$tgt_b" "probe.sh" 2>/dev/null || true
  write_targets "$kit_b" '$RESEARCH_HOME/targetB'
  printf '%s\n' '#!/usr/bin/env bash' \
    'if ! declare -F target_paths_all >/dev/null 2>&1; then' \
    '  target_paths_all() {' \
    '    local f="${1:-}"; [ -n "$f" ] && [ -f "$f" ] || return 0' \
    '    grep -oE '"'"'`/[^`]+`'"'"' "$f" 2>/dev/null | tr -d '"'"'`'"'"' | sort -u' \
    '  }' 'fi' > "$kit_b/toolbelt/lib/target-paths.sh"
  out_b="$(RESEARCH_HOME="$ROOT/rh-base" "$BASH_BIN" "$kit_b/toolbelt/sweep-tools.sh" 2>&1)"
  if ! grep -q 'tools: 1 found' <<<"$out_b"; then
    ok "teeth B: Form-2-dropped mutant misses \$RESEARCH_HOME → case 2 goes red" "()"
  else
    no "teeth B: mutant still found tool — case 2 is THEATER" "out=[$out_b]"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
