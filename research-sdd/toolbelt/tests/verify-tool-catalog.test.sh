#!/usr/bin/env bash
# verify-tool-catalog.test.sh — harness for verify-tool-catalog.sh, now a shim to `rsdd verify tool-catalog`
# (kit issue #2749).
# Cases 1-12 run the SHIM end to end against the real Go binary (RSDD_BIN, else built once from research-sdd/rsdd):
# absent-input (both files), empty-input, no-match (clean), single missing tool, dedup, first/middle/last row,
# no trailing newline, the Tool-paths table, the "## <tool> (...)" form, case-insensitive match and the alias token.
# The report is also pinned byte for byte against the old bash script, in both locales, by the Go differential and
# golden tests (internal/verify/toolcatalog, `make test`); the mutation teeth that targeted that bash (the WARN
# emission, the dedup, -w, -i, the form-2 extraction) moved there with it (`make teeth`). Cases 13-16 pin the shim:
# own-directory argument, symlinked invocation, missing lib, unusable binary (a typed degraded state, never a silent
# pass). --prove-teeth mutates the SHIM (each mutant must lose its case).
# Exit: 0 = every assertion held · 1 = regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-tool-catalog.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-70s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-70s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# The Go binary the shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$ROOT/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$ROOT/rsdd"
fi

# stage_shim DEST [SHIM] — a toolbelt dir holding the shim (the real one, or a mutant) and lib/rsdd-exec.sh.
stage_shim() { mkdir -p "$1/lib"; cp "${2:-$SUT}" "$1/verify-tool-catalog.sh"; chmod +x "$1/verify-tool-catalog.sh"; cp "$HERE/../lib/rsdd-exec.sh" "$1/lib/" || exit 2; }   # stage-libs-ok: the shim needs only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case 15

# mkkit <name> — a fresh toolbelt/ dir with the shim, ready for fixture files.
mkkit() {
  local kit="$ROOT/$1"
  stage_shim "$kit"
  printf '%s' "$kit"
}

installed_header() {
  printf '# Installed tools log — Research-SDD\n\n> Append-only. Written by install-tool.sh.\n\n'
  printf '| Tool | How | Status | Target | Date (UTC) | Notes |\n|---|---|---|---|---|---|\n'
}

run() { OUT="$("$BASH_BIN" "$1/verify-tool-catalog.sh" 2>&1)"; RC=$?; }

echo "== verify-tool-catalog.test.sh (SUT: $(basename "$SUT")) =="

# 1 — absent-input: INSTALLED-TOOLS.md missing entirely → operational failure, exit 1.
kit="$(mkkit c1-no-installed)"
printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n' > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 1 ] && grep -qi 'INSTALLED-TOOLS.md' <<<"$OUT"; then
  ok "1 INSTALLED-TOOLS.md absent → exit 1 (operational)" "(exit $RC)"
else
  no "1 INSTALLED-TOOLS.md absent → exit 1 (operational)" "exit=$RC out=[$OUT]"
fi

# 2 — absent-input: tool-registry.md missing entirely → operational failure, exit 1.
kit="$(mkkit c2-no-registry)"
{ installed_header; printf '| widget | `brew` | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'; } \
  > "$kit/INSTALLED-TOOLS.md"
run "$kit"
if [ "$RC" = 1 ] && grep -qi 'tool-registry.md' <<<"$OUT"; then
  ok "2 tool-registry.md absent → exit 1 (operational)" "(exit $RC)"
else
  no "2 tool-registry.md absent → exit 1 (operational)" "exit=$RC out=[$OUT]"
fi

# 3 — empty-input: INSTALLED-TOOLS.md present but no data rows → exit 0, distinct message.
kit="$(mkkit c3-empty)"
installed_header > "$kit/INSTALLED-TOOLS.md"
printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n' > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 0 ] && grep -qi 'empty-input\|no tool log rows' <<<"$OUT"; then
  ok "3 empty-input (no data rows) → exit 0, distinct message" "(exit $RC)"
else
  no "3 empty-input (no data rows) → exit 0, distinct message" "exit=$RC out=[$OUT]"
fi

# 4 — no-match (clean): every logged tool is cataloged → exit 0, 0 missing.
kit="$(mkkit c4-clean)"
{ installed_header
  printf '| alpha | `brew` | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'
  printf '| beta | `apt` | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'
} > "$kit/INSTALLED-TOOLS.md"
{ printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n'
  printf '| Widget A | alpha direct |\n'
  printf '| Widget B | beta direct |\n'
} > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 0 ] && grep -q '0 not cataloged' <<<"$OUT" && ! grep -q '^WARN' <<<"$OUT"; then
  ok "4 all cataloged (no-match) → exit 0, 0 missing, no WARN" "(exit $RC)"
else
  no "4 all cataloged (no-match) → exit 0, 0 missing, no WARN" "exit=$RC out=[$OUT]"
fi

# 5 — single tool, not cataloged: exactly one row, one WARN, missing=1.
kit="$(mkkit c5-single)"
{ installed_header; printf '| typst | `brew` | already | kit | 2026-01-01T00:00:00Z | v0.15.1 |\n'; } \
  > "$kit/INSTALLED-TOOLS.md"
printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n' > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 0 ] && grep -q "WARN.*'typst'" <<<"$OUT" && grep -q '1 not cataloged' <<<"$OUT"; then
  ok "5 single uncataloged tool → WARN fires, missing=1" "(exit $RC)"
else
  no "5 single uncataloged tool → WARN fires, missing=1" "exit=$RC out=[$OUT]"
fi

# 6 — dedup: the same tool name logged 3x (installed, failed, incompatible) counts ONCE.
kit="$(mkkit c6-dedup)"
{ installed_header
  printf '| blutter | `git clone` | installed | targetA | 2026-01-01T00:00:00Z | n/a |\n'
  printf '| blutter-build | `brew` | failed | targetA | 2026-01-02T00:00:00Z | n/a |\n'
  printf '| blutter | `precheck` | incompatible | targetB | 2026-01-03T00:00:00Z | n/a |\n'
} > "$kit/INSTALLED-TOOLS.md"
printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n' > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 0 ] && grep -q '2 distinct tool(s)' <<<"$OUT" && grep -q '2 not cataloged' <<<"$OUT"; then
  ok "6 repeated tool name across 3 rows dedups to 1 (2 distinct total)" "(exit $RC)"
else
  no "6 repeated tool name across 3 rows dedups to 1 (2 distinct total)" "exit=$RC out=[$OUT]"
fi

# 7 — first/middle/last row coverage: 5 rows, only the MIDDLE one uncataloged.
# Regression guard for the exact "last field/row never checked" class of bug this kit has hit before
# (an unterminated read loop silently skipping the final row) — assert first AND last are cataloged
# too, not just that the middle WARN fires.
kit="$(mkkit c7-position)"
{ installed_header
  printf '| first-tool | \x60brew\x60 | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'
  printf '| second-tool | \x60brew\x60 | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'
  printf '| middle-gap | \x60brew\x60 | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'
  printf '| fourth-tool | \x60brew\x60 | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'
  printf '| last-tool | \x60brew\x60 | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'
} > "$kit/INSTALLED-TOOLS.md"
{ printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n'
  printf '| A | first-tool direct |\n'
  printf '| B | second-tool direct |\n'
  printf '| D | fourth-tool direct |\n'
  printf '| E | last-tool direct |\n'
} > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q "WARN.*'middle-gap'" <<<"$OUT" \
   && ! grep -q "WARN.*'first-tool'" <<<"$OUT" \
   && ! grep -q "WARN.*'last-tool'" <<<"$OUT" \
   && grep -q '5 distinct tool(s)' <<<"$OUT" \
   && grep -q '1 not cataloged' <<<"$OUT"; then
  ok "7 first/middle/last rows all reach the check; only middle WARNs" "(exit $RC)"
else
  no "7 first/middle/last rows all reach the check; only middle WARNs" "exit=$RC out=[$OUT]"
fi

# 8 — trailing row with NO final newline in the file must still be checked (the exact defect shape
# documented in this kit: tr/read loses the last unterminated token).
kit="$(mkkit c8-no-trailing-newline)"
{ installed_header
  printf '| only-tool | \x60brew\x60 | installed | kit | 2026-01-01T00:00:00Z | n/a |'
} > "$kit/INSTALLED-TOOLS.md"
printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n' > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 0 ] && grep -q "WARN.*'only-tool'" <<<"$OUT" && grep -q '1 not cataloged' <<<"$OUT"; then
  ok "8 no trailing newline in INSTALLED-TOOLS.md → last row still checked" "(exit $RC)"
else
  no "8 no trailing newline in INSTALLED-TOOLS.md → last row still checked" "exit=$RC out=[$OUT]"
fi

# 9 — Tool paths table counts too: a tool absent from the capability table but present in
# "## Tool paths (verified)" is treated as cataloged (both live in the same file/search).
kit="$(mkkit c9-pathtable)"
{ installed_header; printf '| markitdown | `pip` | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'; } \
  > "$kit/INSTALLED-TOOLS.md"
{ printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n\n'
  printf '## Tool paths (verified)\n\n| Tool | Path |\n|---|---|\n'
  printf '| markitdown | ~/.local/bin/markitdown |\n'
} > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 0 ] && grep -q '0 not cataloged' <<<"$OUT" && ! grep -q '^WARN' <<<"$OUT"; then
  ok "9 tool cataloged only in the Tool-paths table counts as cataloged" "(exit $RC)"
else
  no "9 tool cataloged only in the Tool-paths table counts as cataloged" "exit=$RC out=[$OUT]"
fi

# 10 — narrative "## <tool> (...)" section entries are LOGGED tools too and must be checked (§7
# report-only-what-you-measured). INSTALLED-TOOLS.md carries a second form beside the auto-log table:
# older hand-written "## <tool> (desc) — <date>" sections (js-beautify, bkcrack on the real fleet).
# An uncataloged section tool must WARN; a cataloged one must not; the table tool is unaffected.
kit="$(mkkit c10-section)"
{ installed_header
  printf '| table-tool | \x60brew\x60 | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'
  printf '\n## section-gap (some manual tool) — 2026-07-02\n'
  printf '\n## section-ok (another manual tool) — 2026-07-10\n'
} > "$kit/INSTALLED-TOOLS.md"
{ printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n'
  printf '| A | table-tool direct |\n'
  printf '| B | section-ok direct |\n'
} > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q "WARN.*'section-gap'" <<<"$OUT" \
   && ! grep -q "WARN.*'section-ok'" <<<"$OUT" \
   && ! grep -q "WARN.*'table-tool'" <<<"$OUT" \
   && grep -q '3 distinct tool(s)' <<<"$OUT" \
   && grep -q '1 not cataloged' <<<"$OUT"; then
  ok "10 narrative '## <tool>' section entries are checked; uncataloged one WARNs" "(exit $RC)"
else
  no "10 narrative '## <tool>' section entries are checked; uncataloged one WARNs" "exit=$RC out=[$OUT]"
fi

# 11 — case-insensitive match: logged lowercase tool name ('vineflower') vs cataloged Title-case
# ('Vineflower') in tool-registry.md. Must count as CATALOGED (no WARN). Without -i the match
# fails and a false WARN fires — this is the exact false-negative the case fix closes.
kit="$(mkkit c11-case)"
{ installed_header; printf '| vineflower | `brew` | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'; } \
  > "$kit/INSTALLED-TOOLS.md"
{ printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n'
  printf '| JAR decompile | Vineflower direct |\n'
} > "$kit/tool-registry.md"
run "$kit"
if [ "$RC" = 0 ] && grep -q '0 not cataloged' <<<"$OUT" && ! grep -q "WARN.*'vineflower'" <<<"$OUT"; then
  ok "11 case-insensitive: logged 'vineflower' matches cataloged 'Vineflower' → no WARN" "(exit $RC)"
else
  no "11 case-insensitive: logged 'vineflower' matches cataloged 'Vineflower' → no WARN" "exit=$RC out=[$OUT]"
fi

# 12 — alias token: logged 'kaitai-struct-compiler' vs display name 'ksc' in catalog.
# (a) WITH the alias token 'kaitai-struct-compiler' present in the row  → CATALOGED, no WARN.
# (b) WITHOUT the alias token (only display name 'ksc')                 → NOT cataloged, WARN fires.
# Both directions must hold to prove the alias token is what carries the match.
kit="$(mkkit c12-alias)"
{ installed_header; printf '| kaitai-struct-compiler | `brew` | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'; } \
  > "$kit/INSTALLED-TOOLS.md"
# (a) alias present
{ printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n'
  printf '| Binary parse | ksc 0.11 (alias: kaitai-struct-compiler) direct |\n'
} > "$kit/tool-registry.md"
run "$kit"
alias_present_rc=$RC; alias_present_out="$OUT"
# (b) alias absent (only display name 'ksc')
{ printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n'
  printf '| Binary parse | ksc 0.11 direct |\n'
} > "$kit/tool-registry.md"
run "$kit"
alias_absent_rc=$RC; alias_absent_out="$OUT"
if [ "$alias_present_rc" = 0 ] \
   && grep -q '0 not cataloged' <<<"$alias_present_out" \
   && ! grep -q "WARN.*'kaitai-struct-compiler'" <<<"$alias_present_out" \
   && [ "$alias_absent_rc" = 0 ] \
   && grep -q "WARN.*'kaitai-struct-compiler'" <<<"$alias_absent_out" \
   && grep -q '1 not cataloged' <<<"$alias_absent_out"; then
  ok "12 alias token: cataloged via alias in ksc row; without alias → WARN fires" "(exit $alias_present_rc / $alias_absent_rc)"
else
  no "12 alias token: expected CATALOGED with alias, NOT-CATALOGED without" \
    "with_alias=[exit=$alias_present_rc out=$alias_present_out] without_alias=[exit=$alias_absent_rc out=$alias_absent_out]"
fi

# stub_bin RC OUTPUT — a fake rsdd that records its arguments (one per line) in $ROOT/args, prints OUTPUT, exits RC.
stub_bin() {
  printf '%s' "$2" > "$ROOT/stub-out.txt"; : > "$ROOT/args"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %s\n' "$ROOT/args" "$ROOT/stub-out.txt" "$1" > "$ROOT/stub-rsdd"
  chmod +x "$ROOT/stub-rsdd"
}

# 13 — the shim hands the binary the group, the command and its OWN directory (never the caller's cwd), and the
#      binary's output and exit code pass through unchanged.
kit="$(mkkit c13-args)"; PHYS="$(cd -P "$kit" && pwd -P)"
stub_bin 1 "stub report"
OUT="$(cd "$ROOT" && RSDD_BIN="$ROOT/stub-rsdd" "$BASH_BIN" "$kit/verify-tool-catalog.sh" extra-arg 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "stub report" ] && [ "$(tr '\n' ' ' < "$ROOT/args")" = "verify tool-catalog $PHYS " ]; then
  ok "13 shim → 'verify tool-catalog <own dir>', output and exit code pass through, arguments not forwarded" "(exit $RC)"
else
  no "13 shim contract" "rc=$RC out=[$OUT] args=[$(tr '\n' ' ' < "$ROOT/args")]"
fi

# 14 — invoked through a symlink in another directory, the shim still names its REAL directory.
mkdir -p "$ROOT/elsewhere"; ln -s "$kit/verify-tool-catalog.sh" "$ROOT/elsewhere/link.sh"
stub_bin 0 ""
RSDD_BIN="$ROOT/stub-rsdd" "$BASH_BIN" "$ROOT/elsewhere/link.sh" >/dev/null 2>&1
if [ "$(tail -n 1 "$ROOT/args")" = "$PHYS" ]; then ok "14 symlinked shim → binary gets the physical own directory"; else no "14 symlink" "args=[$(tr '\n' ' ' < "$ROOT/args")] want ...$PHYS"; fi

# 15 — the shim's own lib missing → a typed degraded line, rc 2, nothing on stdout (never a silent pass).
mkdir -p "$ROOT/nolib"; cp "$SUT" "$ROOT/nolib/verify-tool-catalog.sh"
OUT="$("$BASH_BIN" "$ROOT/nolib/verify-tool-catalog.sh" 2>"$ROOT/err15")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q '^degraded: rsdd-unavailable — rsdd-exec.sh missing beside ' "$ROOT/err15"; then
  ok "15 lib missing → degraded line on stderr, rc 2, empty stdout" "(exit $RC)"
else no "15 lib missing" "rc=$RC out=[$OUT] err=[$(cat "$ROOT/err15")]"; fi

# 16 — rsdd unusable → a typed degraded state on stderr, rc 2 (the check never "passes" without a binary).
kit="$(mkkit c16-nobin)"
OUT="$(RSDD_BIN="$ROOT/does-not-exist" "$BASH_BIN" "$kit/verify-tool-catalog.sh" 2>"$ROOT/err16")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$ROOT/err16"; then
  ok "16 rsdd unusable → degraded line, rc 2, empty stdout" "(exit $RC)"
else no "16 rsdd unusable" "rc=$RC out=[$OUT] err=[$(cat "$ROOT/err16")]"; fi

# ======================== TEETH (mutation proof) — --prove-teeth ==========================
if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutants are built by lib/mutant.sh (kit #1299), sourced ONLY on this path. It refuses an empty,
  # byte-identical, syntax-broken or live-tree mutant; mutant_chain also refuses a sed stage that matches
  # nothing. A refused build is counted exactly once (mk_mut) and its tooth is skipped.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"

  # A: the own-directory argument dropped → the binary would check the cwd; case 13 sees no directory.
  if mk_mut "teeth A: own dir dropped" "$SUT" "$ROOT/mutA.sh" 's/ "\$_RSDD_SELF"$//'; then
    stage_shim "$ROOT/mA" "$ROOT/mutA.sh"; stub_bin 0 ""
    RSDD_BIN="$ROOT/stub-rsdd" "$BASH_BIN" "$ROOT/mA/verify-tool-catalog.sh" >/dev/null 2>&1
    if [ "$(tr '\n' ' ' < "$ROOT/args")" = "verify tool-catalog " ]; then ok "teeth A: own dir dropped → case 13 would go RED"; else no "teeth A: mutant still passes the own dir" "args=[$(tr '\n' ' ' < "$ROOT/args")]"; fi
  fi
  # B: the wrong command (the hook instead of the check) → the binary's answer is an envelope, not the report.
  if mk_mut "teeth B: wrong command" "$SUT" "$ROOT/mutB.sh" 's/verify tool-catalog /verify tool-catalog-hook /'; then
    stage_shim "$ROOT/mB" "$ROOT/mutB.sh"; stub_bin 0 ""
    RSDD_BIN="$ROOT/stub-rsdd" "$BASH_BIN" "$ROOT/mB/verify-tool-catalog.sh" >/dev/null 2>&1
    if [ "$(sed -n 2p "$ROOT/args")" = "tool-catalog-hook" ]; then ok "teeth B: wrong command → case 13 would go RED"; else no "teeth B: mutant still runs the check" "args=[$(tr '\n' ' ' < "$ROOT/args")]"; fi
  fi
  # C: the missing-lib guard stripped → no degraded line and no rc 2 → case 15.
  if mk_mut "teeth C: guard removed" "$SUT" "$ROOT/mutC.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$ROOT/mC"; cp "$ROOT/mutC.sh" "$ROOT/mC/verify-tool-catalog.sh"
    OUT="$("$BASH_BIN" "$ROOT/mC/verify-tool-catalog.sh" 2>"$ROOT/errC")"; RC=$?
    if ! grep -q '^degraded: rsdd-unavailable' "$ROOT/errC"; then ok "teeth C: unguarded shim announces nothing when the lib is missing → case 15 would go RED"; else no "teeth C: mutant still announces" "rc=$RC"; fi
  fi
  # D: the caller's cwd instead of the own directory → case 13 (run from another cwd) sees the wrong directory.
  if mk_mut "teeth D: cwd instead of own dir" "$SUT" "$ROOT/mutD.sh" 's/"\$_RSDD_SELF"$/"$PWD"/'; then
    stage_shim "$ROOT/mD" "$ROOT/mutD.sh"; stub_bin 0 ""
    (cd "$ROOT" && RSDD_BIN="$ROOT/stub-rsdd" "$BASH_BIN" "$ROOT/mD/verify-tool-catalog.sh" >/dev/null 2>&1)
    if [ "$(sed -n 3p "$ROOT/args")" = "$ROOT" ]; then ok "teeth D: cwd passed instead of the own directory → case 13 would go RED"; else no "teeth D: mutant still passes the own directory" "args=[$(tr '\n' ' ' < "$ROOT/args")]"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
