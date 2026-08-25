#!/usr/bin/env bash
# verify-tool-catalog.test.sh — red-first harness for verify-tool-catalog.sh.
# Covers: absent-input (both files), empty-input, no-match (clean), single missing tool,
# dedup across repeated log rows, first/middle/last row coverage, and mutation proof
# via --prove-teeth.
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

# mkkit <name> — a fresh toolbelt/ dir with a copy of the SUT, ready for fixture files.
mkkit() {
  local kit="$ROOT/$1"
  mkdir -p "$kit"
  cp "$SUT" "$kit/verify-tool-catalog.sh"
  chmod +x "$kit/verify-tool-catalog.sh"
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

# ======================== TEETH (mutation proof) — --prove-teeth ==========================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: verify-tool-catalog.sh must go RED under meaningful mutations --"

  # Tooth A: disable the WARN emission for missing tools (simulates a broken/silenced guard).
  # Test 5 (single uncataloged tool must WARN) must catch this and go RED.
  kit="$(mkkit tA-no-warn)"
  { installed_header; printf '| typst | `brew` | already | kit | 2026-01-01T00:00:00Z | v0.15.1 |\n'; } \
    > "$kit/INSTALLED-TOOLS.md"
  printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n' > "$kit/tool-registry.md"
  sed "s/echo \"WARN  installed-but-not-cataloged/: \"WARN  installed-but-not-cataloged/" \
    "$SUT" > "$kit/verify-tool-catalog.sh"
  chmod +x "$kit/verify-tool-catalog.sh"
  run "$kit"
  if ! grep -q "WARN.*'typst'" <<<"$OUT"; then
    ok "teeth A: WARN-emission mutant silences the finding → test 5 would catch it (RED)"
  else
    no "teeth A: WARN-emission mutant still emitted the WARN — mutation ineffective"
  fi

  # Tooth B: break dedup (drop the awk dedup filter) — inflates the distinct-tool count.
  # Test 6 (3 rows, same tool name → 2 distinct) must catch this and go RED.
  kit="$(mkkit tB-no-dedup)"
  { installed_header
    printf '| blutter | `git clone` | installed | targetA | 2026-01-01T00:00:00Z | n/a |\n'
    printf '| blutter-build | `brew` | failed | targetA | 2026-01-02T00:00:00Z | n/a |\n'
    printf '| blutter | `precheck` | incompatible | targetB | 2026-01-03T00:00:00Z | n/a |\n'
  } > "$kit/INSTALLED-TOOLS.md"
  printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n' > "$kit/tool-registry.md"
  # Literal string replace via python3 (regex escaping of `[$0]` in sed is a false-friend hazard —
  # exact-substring replace sidesteps it entirely).
  python3 -c "
import sys
src = open('$SUT').read()
old = \"awk '!seen[\$0]++'\"
new = 'cat'
assert old in src, 'mutation anchor not found in SUT'
open('$kit/verify-tool-catalog.sh', 'w').write(src.replace(old, new))
"
  chmod +x "$kit/verify-tool-catalog.sh"
  run "$kit"
  if ! grep -q '2 distinct tool(s)' <<<"$OUT"; then
    ok "teeth B: dedup-removal mutant inflates the count → test 6 would catch it (RED)"
  else
    no "teeth B: dedup-removal mutant still reported 2 distinct — mutation ineffective"
  fi

  # Tooth C: widen the registry match from whole-word (-w) to bare substring, so a short tool
  # name (e.g. "capa") false-matches inside an unrelated longer word in the registry.
  # A dedicated fixture (not tests 1-9) isolates this false-positive class.
  kit="$(mkkit tC-substring)"
  { installed_header; printf '| capa | `brew` | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'; } \
    > "$kit/INSTALLED-TOOLS.md"
  printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\nlong capacity build note\n' \
    > "$kit/tool-registry.md"
  python3 -c "
src = open('$SUT').read()
old = 'grep -qwF'
new = 'grep -qF'
assert old in src, 'mutation anchor not found in SUT'
open('$kit/verify-tool-catalog.sh', 'w').write(src.replace(old, new))
"
  chmod +x "$kit/verify-tool-catalog.sh"
  run "$kit"
  if grep -q '0 not cataloged' <<<"$OUT"; then
    ok "teeth C: substring-match mutant false-positives on 'capacity' → dedicated check catches it (RED)"
  else
    no "teeth C: substring-match mutant did not false-positive — mutation ineffective, cannot prove -w matters"
  fi

  # Tooth D: strip the Form-2 (narrative "## <tool> (...)") extraction — those entries then vanish
  # from the sweep. Test 10 (section tool must be checked) must catch this and go RED.
  kit="$(mkkit tD-no-section)"
  { installed_header
    printf '| table-tool | \x60brew\x60 | installed | kit | 2026-01-01T00:00:00Z | n/a |\n'
    printf '\n## section-gap (manual tool) — 2026-07-02\n'
  } > "$kit/INSTALLED-TOOLS.md"
  printf '# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n| A | table-tool direct |\n' \
    > "$kit/tool-registry.md"
  # Remove both lines that reference the Form-2 variable (extraction + append). The comment uses
  # "section names" (space), so only the two code lines carry the "section_names" token.
  grep -v 'section_names' "$SUT" > "$kit/verify-tool-catalog.sh"
  chmod +x "$kit/verify-tool-catalog.sh"
  run "$kit"
  if ! grep -q "WARN.*'section-gap'" <<<"$OUT"; then
    ok "teeth D: Form-2 extraction stripped → '## <tool>' entry vanishes → test 10 catches it (RED)"
  else
    no "teeth D: Form-2 stripped but section tool still seen — mutation ineffective"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
