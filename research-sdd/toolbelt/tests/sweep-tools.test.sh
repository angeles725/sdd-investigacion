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

# 3 — NO tools/ directory → distinct INFO empty-input message (not "0 found" or silent skip).
kit="$(mkkit c3-nodir)"; tgt="$kit/targetA"
mkdir -p "$tgt"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'INFO:.*no tools.*directory' <<<"$OUT" \
   && ! grep -qE 'tools: [0-9]+ found' <<<"$OUT"; then
  ok "3 no tools/ directory → INFO empty-input, no found count" "(exit $RC)"
else
  no "3 no tools/ directory → INFO empty-input, no found count" "exit=$RC out=[$OUT]"
fi

# 4 — tools/ EXISTS but EMPTY → INFO empty-input with 'exists but is empty', not 'no tools directory'.
kit="$(mkkit c4-empty)"; tgt="$kit/targetA"
mkdir -p "$tgt/tools"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'INFO:.*exists but is empty' <<<"$OUT" \
   && ! grep -qE 'INFO:.*no tools.*directory' <<<"$OUT"; then
  ok "4 empty tools/ → INFO 'exists but is empty', not 'no tools directory'" "(exit $RC)"
else
  no "4 empty tools/ → INFO 'exists but is empty', not 'no tools directory'" "exit=$RC out=[$OUT]"
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

# 6 — RETRO T-ROW RECORDING. One tool in a retro T-row, one not → 1 recorded (retro) / 1 unrecorded.
kit="$(mkkit c6-recording)"; tgt="$kit/targetA"
mktool "$tgt" "recorded.py"
mktool "$tgt" "unrecorded.sh"
mkretro_trow "$tgt" "r1.md" "recorded.py"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'recorded (retro): 1' <<<"$OUT" \
   && grep -q 'unrecorded: 1' <<<"$OUT" \
   && grep -q 'Summary:.*2 tool(s).*1 recorded (retro).*1 unrecorded' <<<"$OUT"; then
  ok "6 retro T-row → 1 recorded (retro), 1 unrecorded" "(exit $RC)"
else
  no "6 retro T-row → 1 recorded (retro), 1 unrecorded" "exit=$RC out=[$OUT]"
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

# 12 — LEDGER-ONLY. tools/README.md lists 2 tools; NO retro. Must report ledger recordings.
kit="$(mkkit c12-ledger)"; tgt="$kit/targetA"
mktool "$tgt" "ledger-tool.py"
mktool "$tgt" "other-tool.sh"
{ printf '| Tool | Path | Provenance |\n|---|---|---|\n'
  printf '| ledger-tool.py | tools/ledger-tool.py | created |\n'
  printf '| other-tool.sh | tools/other-tool.sh | created |\n'
} > "$tgt/tools/README.md"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'recorded (ledger): 2' <<<"$OUT" \
   && grep -q 'unrecorded: 0' <<<"$OUT" \
   && grep -q 'Summary:.*2 tool(s).*2 recorded (ledger).*0 unrecorded' <<<"$OUT"; then
  ok "12 ledger-only → 2 recorded (ledger), 0 unrecorded" "(exit $RC)"
else
  no "12 ledger-only → 2 recorded (ledger), 0 unrecorded" "exit=$RC out=[$OUT]"
fi

# 13 — BOTH SOURCES + no double-count. Tool A in retro AND ledger, B ledger-only, C neither.
kit="$(mkkit c13-both)"; tgt="$kit/targetA"
mktool "$tgt" "both.py"; mktool "$tgt" "ledger-only.sh"; mktool "$tgt" "neither.py"
mkretro_trow "$tgt" "r1.md" "both.py"
{ printf '| Tool | Path | Provenance |\n|---|---|---|\n'
  printf '| both.py | tools/both.py | created |\n'
  printf '| ledger-only.sh | tools/ledger-only.sh | created |\n'
} > "$tgt/tools/README.md"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'recorded (retro): 1' <<<"$OUT" \
   && grep -q 'recorded (ledger): 1' <<<"$OUT" \
   && grep -q 'unrecorded: 1' <<<"$OUT" \
   && grep -q 'Summary:.*3 tool(s).*1 recorded (retro).*1 recorded (ledger).*1 unrecorded' <<<"$OUT"; then
  ok "13 retro+ledger, no double-count → 1 retro / 1 ledger / 1 unrecorded" "(exit $RC)"
else
  no "13 retro+ledger, no double-count → 1 retro / 1 ledger / 1 unrecorded" "exit=$RC out=[$OUT]"
fi

# 14 — LEDGER UNPARSEABLE. tools/README.md present but has no markdown table → WARN, no ledger count.
kit="$(mkkit c14-noparseable)"; tgt="$kit/targetA"
mktool "$tgt" "scan.py"
printf 'Tools are documented in ESTADO-SITIO.md.\n\nNo table here.\n' > "$tgt/tools/README.md"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -qiE 'WARN.*README.*table|WARN.*ledger' <<<"$OUT" \
   && ! grep -q 'recorded (ledger):' <<<"$OUT"; then
  ok "14 unparseable ledger → WARN shown, no 'recorded (ledger):' count" "(exit $RC)"
else
  no "14 unparseable ledger → WARN shown, no 'recorded (ledger):' count" "exit=$RC out=[$OUT]"
fi

# 15 — DEPENDENCY DIRS EXCLUDED. tools/ has 2 real tools plus a node_modules/ full of .js/.py
#      files (deps, not tools) — including an executable one. The census must NOT count them, so a
#      stray `npm install` / `pip install` under tools/ cannot inflate the count (reproducible census).
kit="$(mkkit c15-deps)"; tgt="$kit/targetA"
mktool "$tgt" "scan.py"; mktool "$tgt" "extract.sh"
mkdir -p "$tgt/tools/node_modules/pkg" "$tgt/tools/__pycache__"
printf 'x\n' > "$tgt/tools/node_modules/pkg/index.js"
printf 'x\n' > "$tgt/tools/node_modules/pkg/dep.py"
chmod +x "$tgt/tools/node_modules/pkg/dep.py"
printf 'x\n' > "$tgt/tools/__pycache__/mod.cpython-314.pyc"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'tools: 2 found' <<<"$OUT"; then
  ok "15 dependency dirs (node_modules/__pycache__) excluded → 2 found, not inflated" "(exit $RC)"
else
  no "15 dependency dirs excluded → 2 found, not inflated" "exit=$RC out=[$OUT]"
fi

# 16 — LIB EXCLUSION (*_lib). tools/ has 1 top-level .py and a module_nav_lib/ subdir with 2 .py files.
#      Library modules must be DISCLOSED separately, not counted in the tool total (§7 Part A).
#      No double-disclosure: the lib count appears once; Summary reflects top-level tools only.
kit="$(mkkit c16-lib)"; tgt="$kit/targetA"
mktool "$tgt" "main_tool.py"
mkdir -p "$tgt/tools/module_nav_lib"
printf '#!/usr/bin/env python3\n# lib module\n' > "$tgt/tools/module_nav_lib/parser.py"
printf '#!/usr/bin/env python3\n# lib module\n' > "$tgt/tools/module_nav_lib/scanner.py"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'tools: 1 found' <<<"$OUT" \
   && grep -qE '2 library module' <<<"$OUT" \
   && grep -q 'Summary:.*1 tool(s).*1 target' <<<"$OUT" \
   && ! grep -qE 'tools: 3 found' <<<"$OUT"; then
  ok "16 *_lib/ dir → 1 tool + 2 lib modules disclosed, Summary shows 1" "(exit $RC)"
else
  no "16 *_lib/ dir → 1 tool + 2 lib modules disclosed, Summary shows 1" "exit=$RC out=[$OUT]"
fi

# 16b — PACKAGE-INTERNAL EXCLUSION (__init__.py). tools/ has 1 top-level tool + a subdir
#        with __init__.py (Python package). Package-internal .py files are library modules,
#        not standalone tools.
kit="$(mkkit c16b-pkg)"; tgt="$kit/targetA"
mktool "$tgt" "main_tool.py"
mkdir -p "$tgt/tools/my_package"
printf '#!/usr/bin/env python3\n' > "$tgt/tools/my_package/__init__.py"
printf '#!/usr/bin/env python3\n# helper\n' > "$tgt/tools/my_package/helper.py"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'tools: 1 found' <<<"$OUT" \
   && grep -qE '[0-9]+ library module' <<<"$OUT" \
   && grep -q 'Summary:.*1 tool(s).*1 target' <<<"$OUT"; then
  ok "16b __init__.py package subdir → package internals disclosed, not counted as tools" "(exit $RC)"
else
  no "16b __init__.py package subdir → package internals disclosed, not counted as tools" "exit=$RC out=[$OUT]"
fi

# 17 — ABSENT-INPUT THREE-STATE. One real target + one non-existent path in TARGETS.md.
#      Must emit INFO per absent target, footer count, exit 0; real target still processed.
kit="$(mkkit c17-absent)"; tgt="$kit/targetA"
mktool "$tgt" "scan.py"
write_targets "$kit" "$tgt" "$kit/nonexistent-target"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'INFO: corpus not found (absent-input):' <<<"$OUT" \
   && grep -qE 'INFO:.*1 target.*not traversed.*absent-input' <<<"$OUT" \
   && grep -q 'TARGET.*targetA' <<<"$OUT" \
   && grep -q 'Summary:.*1 tool' <<<"$OUT"; then
  ok "17 absent target → INFO per target + footer count, real target processed, exit 0" "(exit $RC)"
else
  no "17 absent target → INFO per target + footer count, real target processed, exit 0" "exit=$RC out=[$OUT]"
fi

# 18 — RETRO SCAN ERROR (site 133). A grep error while scanning retro files must emit a WARN
#       instead of silently treating the retro as having no T-rows.
#       Stubs grep so calls with pattern '^\| T[0-9]+' exit 2 (ENOMEM-class error).
_st_real_grep=/usr/bin/grep
_stub_st18="$ROOT/stub-bin-st18"; mkdir -p "$_stub_st18"
cat > "$_stub_st18/grep" << STUB_ST18
#!/usr/bin/env bash
[ "\$#" -ge 2 ] && [ "\$2" = '^\| T[0-9]+' ] && exit 2
exec "${_st_real_grep}" "\$@"
STUB_ST18
chmod +x "$_stub_st18/grep"
kit18="$(mkkit c18-retro-err)"; tgt18="$kit18/targetA"
mktool "$tgt18" "tool.sh"
mkretro_trow "$tgt18" "retro1.md" "tool.sh"
write_targets "$kit18" "$tgt18"
OUT18="$(PATH="$_stub_st18:$PATH" "$BASH_BIN" "$kit18/toolbelt/sweep-tools.sh" 2>&1)"; RC18=$?
if grep -q 'retro(s) unreadable during T-row scan' <<<"$OUT18"; then
  ok "18 retro scan grep exit-2 → WARN emitted (not silent)" "(exit $RC18)"
else
  no "18 retro scan grep exit-2 not reported" "exit=$RC18 out=[$OUT18]"
fi

# 19 — LEDGER SCAN ERROR on SECOND grep (site 148, rc2). A grep error in the separator-filter
#       stage must set ledger_status="error" and emit a WARN instead of silently counting 0.
#       Stubs grep so the separator-filter call (pattern '^\|[[:space:]]*[-:]+[[:space:]]*\|') exits 2.
_stub_st19="$ROOT/stub-bin-st19"; mkdir -p "$_stub_st19"
cat > "$_stub_st19/grep" << STUB_ST19
#!/usr/bin/env bash
[ "\$#" -ge 2 ] && [ "\$2" = '^\|[[:space:]]*[-:]+[[:space:]]*\|' ] && exit 2
exec "${_st_real_grep}" "\$@"
STUB_ST19
chmod +x "$_stub_st19/grep"
kit19="$(mkkit c19-ledger-err)"; tgt19="$kit19/targetA"
mktool "$tgt19" "scan.py"
{ printf '| Tool | Path | Provenance |\n|---|---|---|\n| scan.py | tools/scan.py | created |\n'; } \
  > "$tgt19/tools/README.md"
write_targets "$kit19" "$tgt19"
OUT19="$(PATH="$_stub_st19:$PATH" "$BASH_BIN" "$kit19/toolbelt/sweep-tools.sh" 2>&1)"; RC19=$?
if grep -q 'scan FAILED.*ledger count unavailable' <<<"$OUT19"; then
  ok "19 ledger scan second-grep exit-2 (rc2) → WARN emitted (ledger_status=error)" "(exit $RC19)"
else
  no "19 ledger scan second-grep exit-2 not reported" "exit=$RC19 out=[$OUT19]"
fi

# 19b — LEDGER SCAN ERROR on FIRST grep (site 148, rc1). A grep error in the row-collect stage
#        (PIPESTATUS[0]) must ALSO set ledger_status="error". Previously only rc2 ($?) was captured;
#        this test proves PIPESTATUS[0] is now checked independently — §7.
#        Stubs grep so the row-collect call (pattern '^\|' with flag -E) exits 2.
_stub_st19b="$ROOT/stub-bin-st19b"; mkdir -p "$_stub_st19b"
cat > "$_stub_st19b/grep" << STUB_ST19B
#!/usr/bin/env bash
[ "\$1" = "-E" ] && [ "\$2" = '^\|' ] && exit 2
exec "${_st_real_grep}" "\$@"
STUB_ST19B
chmod +x "$_stub_st19b/grep"
kit19b="$(mkkit c19b-ledger-rc1)"; tgt19b="$kit19b/targetA"
mktool "$tgt19b" "scan.py"
{ printf '| Tool | Path | Provenance |\n|---|---|---|\n| scan.py | tools/scan.py | created |\n'; } \
  > "$tgt19b/tools/README.md"
write_targets "$kit19b" "$tgt19b"
OUT19b="$(PATH="$_stub_st19b:$PATH" "$BASH_BIN" "$kit19b/toolbelt/sweep-tools.sh" 2>&1)"; RC19b=$?
if grep -q 'scan FAILED.*ledger count unavailable' <<<"$OUT19b"; then
  ok "19b ledger scan first-grep exit-2 (rc1) → WARN emitted (PIPESTATUS[0] captured)" "(exit $RC19b)"
else
  no "19b ledger scan first-grep exit-2 not reported (rc1 gap)" "exit=$RC19b out=[$OUT19b]"
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

  # Tooth C: break ledger matching → case-12 fixture (2 ledger-only tools) must report 0, not 2.
  kit_c="$(mkkit teeth-c)"; tgt_c="$kit_c/targetA"
  mktool "$tgt_c" "ledger-tool.py"; mktool "$tgt_c" "other-tool.sh"
  { printf '| Tool | Path | Provenance |\n|---|---|---|\n'
    printf '| ledger-tool.py | tools/ledger-tool.py | created |\n'
    printf '| other-tool.sh | tools/other-tool.sh | created |\n'
  } > "$tgt_c/tools/README.md"
  write_targets "$kit_c" "$tgt_c"
  # Mutant: disable ledger match by changing sentinel in_ledger=1 to in_ledger=0
  sed 's/in_ledger=1/in_ledger=0/' "$SUT" > "$kit_c/toolbelt/sweep-tools.sh"
  out_c="$("$BASH_BIN" "$kit_c/toolbelt/sweep-tools.sh" 2>&1)"
  if ! grep -q 'recorded (ledger): 2' <<<"$out_c"; then
    ok "teeth C: ledger-match-broken mutant misses ledger → case 12 goes red" "()"
  else
    no "teeth C: mutant still found 2 ledger recordings — case 12 is THEATER" "out=[$out_c]"
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

  # Tooth D: strip the dependency-dir exclusions from the find → node_modules deps get counted →
  #          case-15 fixture reports more than 2.
  kit_d="$(mkkit teeth-d)"; tgt_d="$kit_d/targetA"
  mktool "$tgt_d" "scan.py"; mktool "$tgt_d" "extract.sh"
  mkdir -p "$tgt_d/tools/node_modules/pkg"
  printf 'x\n' > "$tgt_d/tools/node_modules/pkg/index.js"
  printf 'x\n' > "$tgt_d/tools/node_modules/pkg/dep.py"
  write_targets "$kit_d" "$tgt_d"
  sed "s/-not -path '[^']*'//g" "$SUT" > "$kit_d/toolbelt/sweep-tools.sh"
  out_d="$("$BASH_BIN" "$kit_d/toolbelt/sweep-tools.sh" 2>&1)"
  if ! grep -q 'tools: 2 found' <<<"$out_d"; then
    ok "teeth D: exclude-stripped mutant counts node_modules deps → case 15 goes red" "()"
  else
    no "teeth D: mutant still found only 2 — case 15 is THEATER" "out=[$out_d]"
  fi

  # Tooth E: kill *_lib discriminator → lib modules get counted as tools →
  #          case-16 fixture reports 3 tools instead of 1.
  kit_e="$(mkkit teeth-e)"; tgt_e="$kit_e/targetA"
  mktool "$tgt_e" "main_tool.py"
  mkdir -p "$tgt_e/tools/module_nav_lib"
  printf '#!/usr/bin/env python3\n# lib\n' > "$tgt_e/tools/module_nav_lib/parser.py"
  printf '#!/usr/bin/env python3\n# lib\n' > "$tgt_e/tools/module_nav_lib/scanner.py"
  write_targets "$kit_e" "$tgt_e"
  # Mutant: make *_lib case never match by replacing the glob with a literal non-matching name
  sed 's/[*]_lib) return 0/NOMATCH_LIB) return 0/' "$SUT" > "$kit_e/toolbelt/sweep-tools.sh"
  out_e="$("$BASH_BIN" "$kit_e/toolbelt/sweep-tools.sh" 2>&1)"
  if ! grep -q 'tools: 1 found' <<<"$out_e"; then
    ok "teeth E: *_lib-broken mutant counts lib modules as tools → case 16 goes red" "()"
  else
    no "teeth E: mutant still reported 1 tool — case 16 is THEATER" "out=[$out_e]"
  fi

  # Tooth F: disable absent-input INFO → case-17 fixture must not find INFO line.
  kit_f="$(mkkit teeth-f)"; tgt_f="$kit_f/targetA"
  mktool "$tgt_f" "scan.py"
  write_targets "$kit_f" "$tgt_f" "$kit_f/nonexistent-target"
  # Mutant: suppress the per-absent-target INFO echo
  sed 's/echo "INFO: corpus not found/true # disabled:/' "$SUT" > "$kit_f/toolbelt/sweep-tools.sh"
  out_f="$("$BASH_BIN" "$kit_f/toolbelt/sweep-tools.sh" 2>&1)"
  if ! grep -q 'INFO: corpus not found (absent-input):' <<<"$out_f"; then
    ok "teeth F: absent-INFO-disabled mutant hides absent target → case 17 goes red" "()"
  else
    no "teeth F: mutant still showed INFO line — case 17 is THEATER" "out=[$out_f]"
  fi

  # Tooth G: neutralize _st_chunk_rc so retro scan error passes silently → test 18 goes red.
  echo "-- teeth G: neutralize _st_chunk_rc; retro-scan exit-2 must pass silently → test 18 goes red --"
  kit_g="$(mkkit teeth-g)"; tgt_g="$kit_g/targetA"
  mktool "$tgt_g" "tool.sh"
  mkretro_trow "$tgt_g" "retro1.md" "tool.sh"
  write_targets "$kit_g" "$tgt_g"
  sed 's/_st_chunk_rc=\$?/_st_chunk_rc=0/' "$SUT" > "$kit_g/toolbelt/sweep-tools.sh"
  out_g="$(PATH="$_stub_st18:$PATH" "$BASH_BIN" "$kit_g/toolbelt/sweep-tools.sh" 2>&1)"
  if grep -q 'retro(s) unreadable during T-row scan' <<<"$out_g"; then
    no "teeth G: rc-zeroed mutant still emitted WARN — test 18 is THEATER" "out=[$out_g]"
  else
    ok "teeth G: rc-zeroed mutant passes silently — retro-scan guard has teeth" "()"
  fi

  # Tooth H: zero BOTH rc1 and rc2 (simulates the pre-PIPESTATUS path that only sees $?) so any
  #   pipeline error passes silently → test 19 (second-grep stub) goes red.
  # Note: zeroing only rc2 is insufficient because a second-grep exit-2 causes SIGPIPE on the
  # first grep (rc1→141), so rc1 alone would still trigger the WARN. Zeroing both proves that
  # the PIPESTATUS capture is what lets pipeline errors surface.
  echo "-- teeth H: zero both rcs (pre-PIPESTATUS path); second-grep exit-2 must pass silently → test 19 goes red --"
  kit_h="$(mkkit teeth-h)"; tgt_h="$kit_h/targetA"
  mktool "$tgt_h" "scan.py"
  { printf '| Tool | Path | Provenance |\n|---|---|---|\n| scan.py | tools/scan.py | created |\n'; } \
    > "$tgt_h/tools/README.md"
  write_targets "$kit_h" "$tgt_h"
  sed -e 's/_st_ledger_rc1=\${_st_ledger_ps\[0\]}/_st_ledger_rc1=0/' \
      -e 's/_st_ledger_rc2=\${_st_ledger_ps\[1\]}/_st_ledger_rc2=0/' \
      "$SUT" > "$kit_h/toolbelt/sweep-tools.sh"
  out_h="$(PATH="$_stub_st19:$PATH" "$BASH_BIN" "$kit_h/toolbelt/sweep-tools.sh" 2>&1)"
  if grep -q 'scan FAILED.*ledger count unavailable' <<<"$out_h"; then
    no "teeth H: both-rcs-zeroed mutant still emitted WARN — test 19 is THEATER" "out=[$out_h]"
  else
    ok "teeth H: both-rcs-zeroed mutant passes silently — PIPESTATUS capture has teeth" "()"
  fi

  # Tooth H2: neutralize _st_ledger_rc1 (PIPESTATUS[0]) so first-grep error passes silently → test 19b goes red.
  # This is the critical proof: a mutant that reads ONLY rc2 (ignoring rc1) goes RED under first-grep stub.
  echo "-- teeth H2: neutralize _st_ledger_rc1; first-grep exit-2 must pass silently → test 19b goes red --"
  kit_h2="$(mkkit teeth-h2)"; tgt_h2="$kit_h2/targetA"
  mktool "$tgt_h2" "scan.py"
  { printf '| Tool | Path | Provenance |\n|---|---|---|\n| scan.py | tools/scan.py | created |\n'; } \
    > "$tgt_h2/tools/README.md"
  write_targets "$kit_h2" "$tgt_h2"
  # Mutant: zero rc1 only — simulates the pre-fix "read only last rc" behaviour (the old gap)
  sed 's/_st_ledger_rc1=\${_st_ledger_ps\[0\]}/_st_ledger_rc1=0/' "$SUT" > "$kit_h2/toolbelt/sweep-tools.sh"
  out_h2="$(PATH="$_stub_st19b:$PATH" "$BASH_BIN" "$kit_h2/toolbelt/sweep-tools.sh" 2>&1)"
  if grep -q 'scan FAILED.*ledger count unavailable' <<<"$out_h2"; then
    no "teeth H2: rc1-zeroed mutant still emitted WARN — test 19b is THEATER" "out=[$out_h2]"
  else
    ok "teeth H2: rc1-zeroed mutant passes silently — first-grep guard has teeth" "()"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
