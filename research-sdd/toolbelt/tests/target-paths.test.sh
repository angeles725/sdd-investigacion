#!/usr/bin/env bash
# target-paths.test.sh — unit suite for lib/target-paths.sh (table-row-scoped path derivation).
# Pins: table-row paths returned; prose citations excluded; truncated table-row path passes
# through (PARTIAL warn preserved); $RESEARCH_HOME rows resolved; absent file → exit 1.
#
# Usage: target-paths.test.sh [--prove-teeth]
# Exit: 0 = all passed · 1 = regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/target-paths.sh"
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf '  SKIP  %-58s %s\n' "$1" "${2:-}"; }  # a skipped check is neither pass nor fail (run-all counts SKIP lines)
# call <lib> <fn> <targets_md>: source lib in a subprocess, invoke fn with targets_md as $1.
call() { "$BASH_BIN" --norc -c "source '$1'; $2 \"\$1\"" -- "$3"; }

# Shared fixture: one real table row, one truncated table row, one prose path citation.
FX="${ROOT}/fixture.md"
cat > "$FX" << 'EOF'
# Targets

Prose citation only: (`/prose/should/not/appear`).

| # | name | path |
|---|------|------|
| 1 | real      | `/table/real/path` |
| 2 | truncated | `/home/x/.../trunc-target` |
EOF

echo "== target-paths.test.sh (SUT: $(basename "$LIB")) =="

# 1a — table-row abs path IS returned by target_paths_all.
# 1b — prose abs path is NOT returned (key defect guard).
out="$(call "$LIB" target_paths_all "$FX")"
if   grep -qF '/table/real/path'        <<<"$out"; then ok "1a table-row abs path returned"
else no "1a table-row abs path returned" "out=[$out]"; fi
if ! grep -qF '/prose/should/not/appear' <<<"$out"; then ok "1b prose abs path excluded (defect guard)"
else no "1b prose abs path excluded (defect guard)" "prose leaked: [$out]"; fi

# 2 — truncated table-row path passes through (caller can warn; anti-silent-zero preserved).
if grep -qF '/home/x/.../trunc-target' <<<"$out"; then ok "2 truncated table-row path passes through"
else no "2 truncated table-row path passes through" "out=[$out]"; fi

# 3 — $RESEARCH_HOME table-row expanded; $RESEARCH_HOME in prose NOT returned.
FX3="${ROOT}/f3.md"
cat > "$FX3" << 'EOF'
# Targets
Prose mentioning `$RESEARCH_HOME/prose-rh` for context only.

| # | name | path |
|---|------|------|
| 1 | rh | `$RESEARCH_HOME/rh-target` |
EOF
out3="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME=/home/rh target_paths_all \"\$1\"" -- "$FX3")"
if   grep -qF '/home/rh/rh-target'  <<<"$out3" \
  && ! grep -qF '/home/rh/prose-rh' <<<"$out3"; then
  ok "3 \$RESEARCH_HOME: table-row expanded; prose excluded"
else no "3 \$RESEARCH_HOME: table-row expanded; prose excluded" "out=[$out3]"; fi

# 4 — absent file → non-zero exit + stderr 'cannot read' (anti-silent-zero).
err4="$("$BASH_BIN" --norc -c "source '$LIB'; target_paths_all '/no/such/TARGETS.md'" 2>&1 >/dev/null)"
rc4=$?
if [ "$rc4" -ne 0 ] && grep -q 'cannot read' <<<"$err4"; then
  ok "4 absent file → non-zero exit + stderr 'cannot read'"
else no "4 absent file → non-zero exit + stderr 'cannot read'" "rc=$rc4 err=[$err4]"; fi

# 5 — target_paths_pairs: table-row as raw-tab-expanded pair; prose excluded.
out5="$(call "$LIB" target_paths_pairs "$FX")"
if   grep -qP '/table/real/path\t/table/real/path' <<<"$out5" \
  && ! grep -qF '/prose/should/not/appear' <<<"$out5"; then
  ok "5 pairs: table row as raw\\texpanded; prose excluded"
else no "5 pairs: table row as raw\\texpanded; prose excluded" "out=[$out5]"; fi

# 6 — target_paths_all with no argument → non-zero exit + stderr 'no argument' (anti-silent-zero).
# Pre-fix: `[ -n "$f" ] || return 0` — exits 0 silently. That is the defect.
# Post-fix must exit non-zero with a message containing "no argument".
err6="$("$BASH_BIN" --norc -c "source '$LIB'; target_paths_all" 2>&1 >/dev/null)"
rc6=$?
if [ "$rc6" -ne 0 ] && grep -q 'no argument' <<<"$err6"; then
  ok "6 target_paths_all no-arg → non-zero exit + stderr 'no argument'"
else no "6 target_paths_all no-arg → non-zero exit + stderr 'no argument'" "rc=$rc6 err=[$err6]"; fi

# 7 — target_paths_pairs with no argument → same contract.
err7="$("$BASH_BIN" --norc -c "source '$LIB'; target_paths_pairs" 2>&1 >/dev/null)"
rc7=$?
if [ "$rc7" -ne 0 ] && grep -q 'no argument' <<<"$err7"; then
  ok "7 target_paths_pairs no-arg → non-zero exit + stderr 'no argument'"
else no "7 target_paths_pairs no-arg → non-zero exit + stderr 'no argument'" "rc=$rc7 err=[$err7]"; fi

# 8 — RESEARCH_HOME with trailing slash: target_paths_all must strip it so the expanded
# path has no // (trailing slash in rh + "/" separator = double slash without %/ fix).
FX8="${ROOT}/f8.md"
cat > "$FX8" << 'EOF'
# Targets
| # | name | path |
|---|------|------|
| 1 | rh | `$RESEARCH_HOME/sub-target` |
EOF
out8="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME='/rh-slash/' target_paths_all \"\$1\"" -- "$FX8")"
if grep -qF '/rh-slash/sub-target' <<<"$out8" && ! grep -qF '//' <<<"$out8"; then
  ok "8 RESEARCH_HOME trailing slash → expanded path has no double slash"
else no "8 RESEARCH_HOME trailing slash → expected /rh-slash/sub-target without //" "out=[$out8]"; fi

# 9 — RESEARCH_HOME containing '&': target_paths_all must return literal path without
# awk sub() & expansion (ENVIRON-based awk so & is never treated as matched-text).
FX9="${ROOT}/f9.md"
cat > "$FX9" << 'EOF'
# Targets
| # | name | path |
|---|------|------|
| 1 | rh | `$RESEARCH_HOME/tgt` |
EOF
out9="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME='/rh&amp/path' target_paths_all \"\$1\"" -- "$FX9")"
if grep -qF '/rh&amp/path/tgt' <<<"$out9"; then
  ok "9 RESEARCH_HOME with '&' → literal path returned (ENVIRON-based awk, no & expansion)"
else no "9 RESEARCH_HOME with '&' → expected literal /rh&amp/path/tgt" "out=[$out9]"; fi

# ---------------------------------------------------------------------------
# target_name_for_retro <targets_md> <retro> (kit issue #1287 item 1): the ONE walk-up + name
# lookup shared by stage-retro-issues / reconcile-issues / stage-retro. Contract:
#   rc 0 + name on stdout  -> nearest registered ancestor of the retro's retros/ directory
#   rc 2 + empty stdout    -> TARGETS.md read fine, but no ancestor is registered (no-match)
#   rc 1 + typed stderr    -> operational failure (TARGETS.md absent/unreadable/no rows parsed)
# tnr <targets_md> <retro> [RESEARCH_HOME]: sets TNR_OUT / TNR_ERR / TNR_RC.
tnr() {
  local errf="${ROOT}/tnr.err"
  TNR_OUT="$(RESEARCH_HOME="${3:-$ROOT}" "$BASH_BIN" --norc -c \
    "set -uo pipefail; source '$LIB'; target_name_for_retro \"\$1\" \"\$2\"" -- "$1" "$2" 2>"$errf")"; TNR_RC=$?
  TNR_ERR="$(cat "$errf")"
}
# mkretro <dir>: create <dir>/retros/r.md and echo its path.
mkretro() { mkdir -p "$1/retros"; : > "$1/retros/r.md"; printf '%s' "$1/retros/r.md"; }

N="${ROOT}/tn"; mkdir -p "$N"
TN1="${N}/t1.md"
{
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n'
  printf '| 1 | reg-first | `%s/first` |\n' "$N"
  printf '| 2 | reg-middle | `%s/middle` |\n' "$N"
  printf '| 3 | reg-last | `%s/last` |\n' "$N"
} > "$TN1"

# 10 — flat layout resolves to the registered NAME (cell 2), not the path basename
tnr "$TN1" "$(mkretro "$N/middle")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "reg-middle" ]; then ok "10 flat <target>/retros → registered name"
else no "10 flat <target>/retros → registered name" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi

# 11 — list edges: FIRST / LAST rows resolve too (a loop that skips an edge row must be caught)
tnr "$TN1" "$(mkretro "$N/first")";  r1="$TNR_OUT/$TNR_RC"
tnr "$TN1" "$(mkretro "$N/last")";   r3="$TNR_OUT/$TNR_RC"
if [ "$r1" = "reg-first/0" ] && [ "$r3" = "reg-last/0" ]; then ok "11 first and last table rows resolve (list edges)"
else no "11 first and last table rows resolve (list edges)" "first=[$r1] last=[$r3]"; fi

# 12 — single-row table
TN12="${N}/t12.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | only-one | `%s/solo` |\n' "$N" > "$TN12"
tnr "$TN12" "$(mkretro "$N/solo")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "only-one" ]; then ok "12 single-row table resolves"
else no "12 single-row table resolves" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi

# 13 — nested corpus layout (<target>/corpus/retros) and a deeper one both resolve
tnr "$TN1" "$(mkretro "$N/middle/corpus")"; n1="$TNR_OUT/$TNR_RC"
tnr "$TN1" "$(mkretro "$N/middle/sub/deeper")"; n2="$TNR_OUT/$TNR_RC"
if [ "$n1" = "reg-middle/0" ] && [ "$n2" = "reg-middle/0" ]; then ok "13 nested corpus/retros and deeper layouts resolve"
else no "13 nested corpus/retros and deeper layouts resolve" "corpus=[$n1] deeper=[$n2]"; fi

# 14 — NESTED REGISTERED TARGETS: the NEAREST ancestor wins, in BOTH row orders (a mutant that
#      matches the OUTERMOST ancestor, or depends on row order, must not survive).
mkdir -p "$N/outer/inner"
TN14a="${N}/t14a.md"; TN14b="${N}/t14b.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | outer-t | `%s/outer` |\n| 2 | inner-t | `%s/outer/inner` |\n' "$N" "$N" > "$TN14a"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | inner-t | `%s/outer/inner` |\n| 2 | outer-t | `%s/outer` |\n' "$N" "$N" > "$TN14b"
ri="$(mkretro "$N/outer/inner")"; ro="$(mkretro "$N/outer")"
tnr "$TN14a" "$ri"; a_in="$TNR_OUT"; tnr "$TN14a" "$ro"; a_out="$TNR_OUT"
tnr "$TN14b" "$ri"; b_in="$TNR_OUT"; tnr "$TN14b" "$ro"; b_out="$TNR_OUT"
if [ "$a_in" = inner-t ] && [ "$a_out" = outer-t ] && [ "$b_in" = inner-t ] && [ "$b_out" = outer-t ]; then
  ok "14 nested registered targets: nearest ancestor wins in both row orders"
else no "14 nested registered targets: nearest ancestor wins in both row orders" \
  "a_in=$a_in a_out=$a_out b_in=$b_in b_out=$b_out"; fi

# 15 — RAW $RESEARCH_HOME token (the form every real row uses), both $X and ${X} spellings
TN15="${N}/t15.md"
{
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n'
  printf '| 1 | rh-plain | `$RESEARCH_HOME/rhp` |\n'
  printf '| 2 | rh-braced | `${RESEARCH_HOME}/rhb` |\n'
} > "$TN15"
tnr "$TN15" "$(mkretro "$N/rhp")" "$N"; p1="$TNR_OUT/$TNR_RC"
tnr "$TN15" "$(mkretro "$N/rhb/corpus")" "$N"; p2="$TNR_OUT/$TNR_RC"
if [ "$p1" = "rh-plain/0" ] && [ "$p2" = "rh-braced/0" ]; then ok "15 raw \$RESEARCH_HOME and \${RESEARCH_HOME} tokens resolve to the row name"
else no "15 raw \$RESEARCH_HOME and \${RESEARCH_HOME} tokens resolve to the row name" "plain=[$p1] braced=[$p2]"; fi

# 16 — NAME FALLBACK: an empty name cell falls back to the path basename (quietly: no usable name
#      is a registry-shape fact, not a lookup failure) …
TN16="${N}/t16.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 |  | `%s/blankname` |\n' "$N" > "$TN16"
tnr "$TN16" "$(mkretro "$N/blankname")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "blankname" ]; then ok "16a empty name cell → path basename fallback"
else no "16a empty name cell → path basename fallback" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi
# … and a name containing whitespace falls back WITH a WARN (it was silent before: R2-whitespace-fallback)
TN16b="${N}/t16b.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | two words | `%s/spacename` |\n' "$N" > "$TN16b"
tnr "$TN16b" "$(mkretro "$N/spacename")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "spacename" ] && grep -qi 'WARN' <<<"$TNR_ERR" && grep -qF 'two words' <<<"$TNR_ERR"; then
  ok "16b whitespace name → basename fallback with a WARN naming the cell"
else no "16b whitespace name → basename fallback with a WARN naming the cell" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi
# markdown decoration (**bold**/backticks) is stripped from the name cell
TN16c="${N}/t16c.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | **bold-name** | `%s/boldt` |\n' "$N" > "$TN16c"
tnr "$TN16c" "$(mkretro "$N/boldt")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "bold-name" ]; then ok "16c markdown decoration stripped from the name cell"
else no "16c markdown decoration stripped from the name cell" "rc=$TNR_RC out=[$TNR_OUT]"; fi

# 17 — SYMLINKS: physical resolution on BOTH sides (retro reached via a symlink to a registered
#      dir; registered path itself written through a symlink).
mkdir -p "$N/real-t/retros"; : > "$N/real-t/retros/r.md"
ln -sfn "$N/real-t" "$N/link-t"
TN17="${N}/t17.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | sym-t | `%s/real-t` |\n' "$N" > "$TN17"
tnr "$TN17" "$N/link-t/retros/r.md"; s1="$TNR_OUT/$TNR_RC"           # retro via symlink
TN17b="${N}/t17b.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | sym-t | `%s/link-t` |\n' "$N" > "$TN17b"
tnr "$TN17b" "$N/real-t/retros/r.md"; s2="$TNR_OUT/$TNR_RC"          # registered via symlink
if [ "$s1" = "sym-t/0" ] && [ "$s2" = "sym-t/0" ]; then ok "17 symlinked retro dir / symlinked registered path both resolve physically"
else no "17 symlinked retro dir / symlinked registered path both resolve physically" "retro-via-link=[$s1] reg-via-link=[$s2]"; fi

# 18 — no registered ancestor: rc 2, EMPTY stdout (no-match is distinct from operational failure)
mkdir -p "$N/stranger"
tnr "$TN1" "$(mkretro "$N/stranger")"
if [ "$TNR_RC" = 2 ] && [ -z "$TNR_OUT" ]; then ok "18 unregistered retro → rc 2, empty stdout (no-match)"
else no "18 unregistered retro → rc 2, empty stdout (no-match)" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi

# 19 — OPERATIONAL failures are rc 1 with typed stderr, never a quiet no-match:
tnr "${N}/does-not-exist.md" "$(mkretro "$N/middle")"
if [ "$TNR_RC" = 1 ] && [ -z "$TNR_OUT" ] && grep -qF 'cannot read' <<<"$TNR_ERR"; then ok "19a absent TARGETS.md → rc 1, typed 'cannot read'"
else no "19a absent TARGETS.md → rc 1, typed 'cannot read'" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi
TN19b="${N}/t19b.md"; : > "$TN19b"
tnr "$TN19b" "$(mkretro "$N/middle")"
if [ "$TNR_RC" = 1 ] && [ -z "$TNR_OUT" ] && grep -qi 'no registered target paths parsed' <<<"$TNR_ERR"; then ok "19b empty TARGETS.md → rc 1, typed 'no registered target paths'"
else no "19b empty TARGETS.md → rc 1, typed 'no registered target paths'" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi
TN19c="${N}/t19c.md"; printf '# t\n\n| # | Target | Path |\n|---|---|---|\n' > "$TN19c"
tnr "$TN19c" "$(mkretro "$N/middle")"
if [ "$TNR_RC" = 1 ] && grep -qi 'no registered target paths parsed' <<<"$TNR_ERR"; then ok "19c header-only TARGETS.md (zero rows) → rc 1"
else no "19c header-only TARGETS.md (zero rows) → rc 1" "rc=$TNR_RC err=[$TNR_ERR]"; fi
TN19d="${N}/t19d.md"; cp "$TN1" "$TN19d"; chmod 000 "$TN19d"
if [ ! -r "$TN19d" ]; then
  tnr "$TN19d" "$(mkretro "$N/middle")"
  if [ "$TNR_RC" = 1 ] && grep -qF 'cannot read' <<<"$TNR_ERR"; then ok "19d unreadable TARGETS.md → rc 1, typed 'cannot read'"
  else no "19d unreadable TARGETS.md → rc 1, typed 'cannot read'" "rc=$TNR_RC err=[$TNR_ERR]"; fi
else skip "19d unreadable TARGETS.md" "chmod 000 still readable (running as root?) — premise unavailable, NOT a pass"; fi
chmod 600 "$TN19d"
tnr "$TN1" "${N}/no-such-dir/retros/r.md"
if [ "$TNR_RC" = 1 ] && grep -qi 'retro' <<<"$TNR_ERR"; then ok "19e retro directory that does not exist → rc 1, typed message"
else no "19e retro directory that does not exist → rc 1, typed message" "rc=$TNR_RC err=[$TNR_ERR]"; fi
out19f="$("$BASH_BIN" --norc -c "source '$LIB'; target_name_for_retro" 2>&1)"; rc19f=$?
if [ "$rc19f" = 1 ] && grep -qi 'target_name_for_retro' <<<"$out19f"; then ok "19f no arguments → rc 1, typed usage message"
else no "19f no arguments → rc 1, typed usage message" "rc=$rc19f out=[$out19f]"; fi

# 20 — a registered row whose path does not exist is skipped, later rows still resolve
TN20="${N}/t20.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | ghost | `%s/ghost-dir` |\n| 2 | real-after-ghost | `%s/middle` |\n' "$N" "$N" > "$TN20"
tnr "$TN20" "$(mkretro "$N/middle")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "real-after-ghost" ]; then ok "20 nonexistent registered path is skipped, later row resolves"
else no "20 nonexistent registered path is skipped, later row resolves" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi

# 21 — WRONG RESEARCH_HOME (kit issue #1304 item 3): when NO parsed registered path resolves to a
#      directory (every row is a $RESEARCH_HOME row and RESEARCH_HOME points nowhere), the helper
#      must report an operational failure (rc 1, typed message) — NOT the "no ancestor registered"
#      rc 2, which callers read as "this target is simply not registered" and answer with a quiet
#      basename fallback. §7: absent-input must stay distinguishable from no-match.
tnr "$TN15" "$(mkretro "$N/rhp")" "/nonexistent-research-home-$$"
if [ "$TNR_RC" = 1 ] && [ -z "$TNR_OUT" ] && grep -qi 'no registered target path' <<<"$TNR_ERR" && grep -qi 'director' <<<"$TNR_ERR"; then
  ok "21a RESEARCH_HOME points nowhere (no row resolves) → rc 1, typed message"
else no "21a RESEARCH_HOME points nowhere (no row resolves) → rc 1, typed message" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi
# 21b — LIST EDGE: ONE resolving row among ghosts (ghost first AND ghost last) is enough: case 20
#       already pins ghost-first; here the ghost is LAST and the retro sits under the first row.
TN21b="${N}/t21b.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | solid | `%s/middle` |\n| 2 | ghost-last | `%s/ghost-dir-2` |\n' "$N" "$N" > "$TN21b"
tnr "$TN21b" "$(mkretro "$N/middle")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "solid" ]; then ok "21b one resolving row among ghosts (ghost LAST) → still resolves"
else no "21b one resolving row among ghosts (ghost LAST) → still resolves" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi
# 21c — an ABSOLUTE-only registry whose only path is a ghost stays rc 2 (no-match): RESEARCH_HOME
#       cannot be the cause, and the consumers' fixture kits rely on a dummy absolute row (rc 2 →
#       legacy WARN + basename fallback; research-sdd-status.test.sh mk_kit_real_reconcile).
TN21c="${N}/t21c.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | only-ghost | `%s/ghost-dir-3` |\n' "$N" > "$TN21c"
tnr "$TN21c" "$(mkretro "$N/middle")"
if [ "$TNR_RC" = 2 ] && [ -z "$TNR_OUT" ] && [ -z "$TNR_ERR" ]; then ok "21c absolute-only ghost registry → rc 2 (unchanged no-match)"
else no "21c absolute-only ghost registry → rc 2 (unchanged no-match)" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi
# 21d — MIXED registry: an absolute ghost row AND $RESEARCH_HOME rows, nothing resolves → rc 1.
TN21d="${N}/t21d.md"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | abs-ghost | `%s/ghost-dir-4` |\n| 2 | rh-row | `$RESEARCH_HOME/rhp` |\n' "$N" > "$TN21d"
tnr "$TN21d" "$(mkretro "$N/rhp")" "/nonexistent-research-home-$$"
if [ "$TNR_RC" = 1 ] && grep -qi 'RESEARCH_HOME' <<<"$TNR_ERR"; then ok "21d mixed abs-ghost + \$RESEARCH_HOME rows, none resolves → rc 1"
else no "21d mixed abs-ghost + \$RESEARCH_HOME rows, none resolves → rc 1" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi

# 22 — ROW LOOKUP MATCHES THE PATH CELL ONLY (kit issue #1304 item 4): a registered path quoted in
#      ANOTHER row's non-path cell (a Notes column) must not make that earlier row's name win.
TN22="${N}/t22.md"
{
  printf '# t\n\n| # | Target | Path | Notes |\n|---|---|---|---|\n'
  printf '| 1 | decoy-first | `%s/first` | superseded by `%s/last` |\n' "$N" "$N"
  printf '| 2 | the-real-last | `%s/last` | none |\n' "$N"
} > "$TN22"
tnr "$TN22" "$(mkretro "$N/last")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "the-real-last" ]; then ok "22a path quoted in another row's Notes cell → the Path-cell row's name wins"
else no "22a path quoted in another row's Notes cell → the Path-cell row's name wins" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi
# 22b — LIST EDGE: the quoted decoy sits in the LAST row's cell, the real row is FIRST.
TN22b="${N}/t22b.md"
{
  printf '# t\n\n| # | Target | Path | Notes |\n|---|---|---|---|\n'
  printf '| 1 | the-real-first | `%s/first` | none |\n' "$N"
  printf '| 2 | decoy-last | `%s/last` | see `%s/first` |\n' "$N" "$N"
} > "$TN22b"
tnr "$TN22b" "$(mkretro "$N/first")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "the-real-first" ]; then ok "22b real row FIRST, decoy quote in the LAST row → real name"
else no "22b real row FIRST, decoy quote in the LAST row → real name" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi
# 22c — a path that is only a PREFIX of another row's path must not match it (backtick-delimited).
TN22c="${N}/t22c.md"
mkdir -p "$N/pfx" "$N/pfxlong"
{
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n'
  printf '| 1 | long-one | `%s/pfxlong` |\n' "$N"
  printf '| 2 | short-one | `%s/pfx` |\n' "$N"
} > "$TN22c"
tnr "$TN22c" "$(mkretro "$N/pfx")"
if [ "$TNR_RC" = 0 ] && [ "$TNR_OUT" = "short-one" ]; then ok "22c path that prefixes another row's path → exact cell match"
else no "22c path that prefixes another row's path → exact cell match" "rc=$TNR_RC out=[$TNR_OUT] err=[$TNR_ERR]"; fi

# --- summary ---
echo ""
total=$((pass+fail))
[ "$total" -gt 0 ] || { echo "FATAL: zero tests executed." >&2; exit 2; }
if [ "$fail" -gt 0 ]; then
  printf 'RESULT: %d passed / %d FAILED\n' "$pass" "$fail"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"
  [ "${1:-}" = "--prove-teeth" ] || exit 1
else
  printf 'RESULT: %d passed / 0 failed\n' "$pass"
  printf '== %d passed · 0 failed ==\n' "$pass"
  [ "${1:-}" = "--prove-teeth" ] || exit 0
fi

# --- teeth: every mutant is built through lib/mutant.sh (refuses empty / identical / syntax-broken /
# live-tree mutants) and every tooth is a mutant_tooth with EXACT good/bad exit codes, so a crashing
# mutant (wrong rc) is THEATER, not teeth. Where the contract has a typed line it is asserted on the
# run that emits it (and its absence on the other); TNR-7 and the mutant side of TNR-8 are the silent
# no-match contract (rc 2, empty output) and instead assert no bash runtime error on the mutant run.
# The mutants live under $ROOT (mktemp -d, trap-cleaned above), never beside the SUT.
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_built mutant_tooth mutant_or_count mutant_chain_or_count mutant_built_or_count || exit 2
# shellcheck disable=SC2034  # read by mutant_tooth (default original) in lib/mutant.sh
SUT="$LIB"
# mk LABEL OUT EXPR... — sed-build a mutant of $LIB (each EXPR must change the SUT on its own); a refusal
# records one FAIL (printed by the helper) and returns 1 so the caller never runs a tooth on it.
mk() {
  local l="$1" out="$2"; shift 2
  if mutant_chain_or_count fail "$l" "$LIB" "$out" "$@"; then
    ok "$l (a): mutant differs from SUT"; ok "$l (b): mutant passes bash -n"; return 0
  fi
  return 1
}
tt() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
# blk FILE START_FIXED END — "N,M" line range of ONE exact block: the single line containing START_FIXED
# through the first later line containing END (END starting with '=' means a whole-line match of the rest).
# Fails when START is absent or ambiguous or END is missing, so a deletion mutant never becomes open-ended.
blk() {
  awk -v s="$2" -v e="$3" '
    index($0, s) { if (sl) dup = 1; else sl = NR }
    sl && !el && NR >= sl { if (substr(e, 1, 1) == "=") { if ($0 == substr(e, 2)) el = NR } else if (index($0, e)) el = NR }
    END { if (sl && el && !dup) print sl "," el; else exit 1 }' "$1"
}
# tnr_tt LABEL GOOD_RC BAD_RC MUTANT TARGETS RETRO HOME [tooth opts...] — target_name_for_retro on the
# original vs the mutant. The tooth merges stderr into the checked output; rc is exact on both runs.
tnr_tt() {
  local l="$1" g="$2" b="$3" m="$4" t="$5" r="$6" h="$7"; shift 7
  tt "$l" "$g" "$b" "$m" "$@" -- env RESEARCH_HOME="$h" "$BASH_BIN" --norc -c \
    "set -uo pipefail; source '@SUT@'; target_name_for_retro \"\$1\" \"\$2\"" -- "$t" "$r"
}

# Teeth for case 1b: pre-fix (wide-scan) mutant must leak prose. Good run: table path only (rc 0);
# mutant: rc 0 too, but the prose path appears — told apart by the typed line, not by rc.
echo ""
echo "-- teeth: wide-scan (pre-fix) mutant; expect prose path to leak in case 1b --"
if ! grep -qF 'grep -E' "$LIB"; then
  no "teeth: locate table-row filter in LIB" "anchor not found — LIB drifted?"
else
  MUTANT="${ROOT}/tp-mutant.sh"
  cat > "$MUTANT" << 'MUTANT_SRC'
if ! declare -F target_paths_all >/dev/null 2>&1; then
  target_paths_all() {
    local f="${1:-}"; [ -n "$f" ] || return 0
    [ -f "$f" ] || { echo "target-paths: cannot read ${f}" >&2; return 1; }
    grep -oE '`/[^`]+`' "$f" 2>/dev/null | tr -d '`' | sort -u
  }
  target_paths_pairs() {
    local f="${1:-}"; [ -n "$f" ] || return 0
    [ -f "$f" ] || { echo "target-paths: cannot read ${f}" >&2; return 1; }
    grep -oE '`/[^`]+`' "$f" 2>/dev/null | tr -d '`' | awk '{print $0"\t"$0}' | sort -u
  }
fi
MUTANT_SRC
  if mutant_built_or_count fail "teeth: wide-scan mutant build" "$LIB" "$MUTANT"; then
    tt "teeth: wide-scan mutant leaks prose (case 1b has teeth)" 0 0 "$MUTANT" \
      --good-has '^/table/real/path$' --good-lacks '/prose/should/not/appear' \
      --bad-has '^/prose/should/not/appear$' -- \
      "$BASH_BIN" --norc -c "source '@SUT@'; target_paths_all \"\$1\"" -- "$FX"
  fi
fi

# Teeth for cases 6 and 7: delete the exact SENTINEL-TP-*-NOARG block (the fix guard). Both runs exit 1
# (the mutant falls through to the absent-file check): rc cannot tell them apart, the typed line does —
# original says 'no argument', the mutant says 'cannot read'.
for _t in "6 ALL all" "7 PAIRS pairs"; do
  read -r _n _s _f <<<"$_t"
  echo "-- teeth $_n: no-arg guard for target_paths_$_f --"
  if ! _r="$(blk "$LIB" "# SENTINEL-TP-$_s-NOARG-START" "# SENTINEL-TP-$_s-NOARG-END")"; then
    no "teeth $_n: locate exact SENTINEL-TP-$_s-NOARG block in LIB" "anchor missing or ambiguous — LIB drifted?"
  elif mk "teeth $_n" "${ROOT}/tp-noarg-$_f-mutant.sh" "${_r}d"; then
    tt "teeth $_n: no-arg mutant lacks 'no argument' in stderr (case $_n has teeth)" 1 1 \
      "${ROOT}/tp-noarg-$_f-mutant.sh" --good-has 'no argument' \
      --bad-has 'cannot read' --bad-lacks 'no argument' -- \
      "$BASH_BIN" --norc -c "source '@SUT@'; target_paths_$_f"
  fi
done

# Teeth for case 8: removing the rh%/ normalization must make // appear in the expanded path.
echo "-- teeth 8: trailing-slash normalization for target_paths_all --"
MUTANT_TP8="${ROOT}/tp-slash-mutant.sh"
if mk "teeth 8" "$MUTANT_TP8" '/rh="\${rh%\/}"/d'; then
  # control on the original, same artifact the case-8 assertion reads (stdout of target_paths_all)
  out_m8_ctrl="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME='/rh-slash/' target_paths_all \"\$1\"" -- "$FX8" 2>/dev/null)"
  if grep -qF '/rh-slash/sub-target' <<<"$out_m8_ctrl" && ! grep -qF '//' <<<"$out_m8_ctrl"; then
    ok "teeth 8 (d) ctrl: SUT strips trailing slash (no // in expanded path)"
  else no "teeth 8 (d) ctrl: SUT output unexpected (case 8 premise broken)" "out=[$out_m8_ctrl]"; fi
  tt "teeth 8: no-norm mutant produces // in path (case 8 has teeth)" 0 0 "$MUTANT_TP8" \
    --good-has '^/rh-slash/sub-target$' --good-lacks '//' --bad-has '//' -- \
    "$BASH_BIN" --norc -c "source '@SUT@'; RESEARCH_HOME='/rh-slash/' target_paths_all \"\$1\"" -- "$FX8"
fi

# Teeth for case 9: replacing the ENVIRON lookup with sub()-based expansion must corrupt a '&' path.
echo "-- teeth 9: ENVIRON-based awk (no sub() & expansion) for target_paths_all --"
MUTANT_TP9="${ROOT}/tp-amp-mutant.sh"
# braces make the injected statement one compound statement so the existing else branch stays valid
if mk "teeth 9" "$MUTANT_TP9" 's|print rh "/" substr($0, length(pfx2) + 1)|{ sub(/^[$]RESEARCH_HOME[/]/, rh "/"); print }|'; then
  out_m9_ctrl="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME='/rh&amp/path' target_paths_all \"\$1\"" -- "$FX9" 2>/dev/null)"
  if grep -qF '/rh&amp/path/tgt' <<<"$out_m9_ctrl"; then
    ok "teeth 9 (d) ctrl: SUT preserves & in RESEARCH_HOME path"
  else no "teeth 9 (d) ctrl: SUT does not preserve & (case 9 premise broken)" "out=[$out_m9_ctrl]"; fi
  # the mutant must RUN (rc 0) and emit the specific &-corrupted path (a crash emits nothing)
  tt "teeth 9: sub()-mutant corrupts & path (case 9 has teeth)" 0 0 "$MUTANT_TP9" \
    --good-has '^/rh&amp/path/tgt$' --bad-has '^/rh[$]RESEARCH_HOME/amp/path/tgt$' \
    --bad-lacks '/rh&amp/path/tgt' -- \
    "$BASH_BIN" --norc -c "source '@SUT@'; RESEARCH_HOME='/rh&amp/path' target_paths_all \"\$1\"" -- "$FX9"
fi
# Sabotage: the old injection (no braces → orphan else) is an awk syntax error → crash. The tooth above
# requires mutant rc 0, so a crash cannot pass; the broken program must return non-zero on parse.
echo "-- teeth 9 sabotage: old broken-awk injection is a non-zero awk parse --"
_sab9_rc=0
echo '' | awk 'BEGIN { rh="" }
  {
    pfx2 = "$RESEARCH_HOME/"
    if (substr($0, 1, length(pfx2)) == pfx2)
      sub(/^\$RESEARCH_HOME\//,rh "/"); print
    else
      print
  }' >/dev/null 2>&1 || _sab9_rc=$?
if [ "$_sab9_rc" -ne 0 ]; then
  ok "teeth 9 sabotage: crash-prone awk exits non-zero on parse (crash is not a bite)"
else no "teeth 9 sabotage: old broken awk parsed — sabotage detection ineffective"; fi

# Teeth for target_name_for_retro (kit issue #1287): each mutant is vetted by lib/mutant.sh and must
# flip the specific case that guards the behavior it removes — rc AND typed output asserted on BOTH runs.
echo "-- teeth TNR: target_name_for_retro mutants --"
M="${ROOT}/tnr-mutant"
# NODIR: the typed no-resolving-path refusal; RTERR: bash runtime errors that would make a mutant's rc a crash.
NODIR='resolves to a directory'
RTERR="$(mutant_crash_re bash)" || exit 2
# TNR-1: keep walking after the first match -> OUTERMOST registered ancestor wins (case 14).
if mk "teeth TNR-1" "$M-1.sh" 's|break 2   # SENTINEL-TNR-NEAREST.*|:|'; then
  tnr_tt "teeth TNR-1: outermost-ancestor mutant flips case 14 (has teeth)" 0 0 "$M-1.sh" "$TN14a" "$ri" "$ROOT" \
    --good-has '^inner-t$' --bad-has '^outer-t$' --bad-lacks '^inner-t$'
fi
# TNR-2: logical instead of physical paths (case 17).
if mk "teeth TNR-2" "$M-2.sh" 's/cd -P/cd/g; s/pwd -P/pwd/g'; then
  tnr_tt "teeth TNR-2: logical-path mutant flips case 17 (has teeth)" 0 2 "$M-2.sh" "$TN17" "$N/link-t/retros/r.md" "$ROOT" \
    --good-has '^sym-t$' --bad-lacks '^sym-t$'
fi
# TNR-3: drop the absent/unreadable guard (case 19d: an unreadable file keeps the 'cannot read' message).
if _r="$(blk "$LIB" 'if [ ! -f "$f" ] || [ ! -r "$f" ]; then' '=    fi')"; then
  if mk "teeth TNR-3" "$M-3.sh" "${_r}d"; then
    chmod 000 "$TN19d"
    if [ ! -r "$TN19d" ]; then
      tnr_tt "teeth TNR-3: guard-less mutant flips case 19d (has teeth)" 1 1 "$M-3.sh" "$TN19d" "$(mkretro "$N/middle")" "$ROOT" \
        --good-has 'cannot read' --bad-lacks 'cannot read'
    else skip "teeth TNR-3: guard-less mutant vs case 19d" "chmod 000 still readable (running as root?) — mutant not exercised, NOT a pass"; fi
    chmod 600 "$TN19d"
  fi
else no "teeth TNR-3: locate exact unreadable-file guard block in LIB" "anchor missing or ambiguous — LIB drifted?"; fi
# TNR-4: drop the empty-pairs guard -> a registry with zero rows reads as a quiet no-match (19b/19c).
if _r="$(blk "$LIB" 'if [ -z "$pairs" ]; then' '=    fi')"; then
  if mk "teeth TNR-4" "$M-4.sh" "${_r}d"; then
    tnr_tt "teeth TNR-4: empty-pairs-guard mutant flips case 19c (has teeth)" 1 2 "$M-4.sh" "$TN19c" "$(mkretro "$N/middle")" "$ROOT" \
      --good-has 'no registered target paths parsed' --good-lacks "$RTERR" \
      --bad-lacks "no registered target paths parsed|$RTERR"
  fi
else no "teeth TNR-4: locate exact empty-pairs guard block in LIB" "anchor missing or ambiguous — LIB drifted?"; fi
# TNR-5: ignore the name cell, always use the basename (cases 15 / 16c).
if mk "teeth TNR-5" "$M-5.sh" 's#^    name="\$(_TP_RAW=.*#    name=""; arc=0#'; then
  tnr_tt "teeth TNR-5: basename-only mutant flips case 15 (has teeth)" 0 0 "$M-5.sh" "$TN15" "$(mkretro "$N/rhp")" "$N" \
    --good-lacks '^rhp$' --bad-has '^rhp$'
fi
# TNR-6: drop the whitespace WARN (case 16b).
if mk "teeth TNR-6" "$M-6.sh" '/contains whitespace and cannot be a label/d'; then
  tnr_tt "teeth TNR-6: WARN-less mutant flips case 16b (has teeth)" 0 0 "$M-6.sh" "$TN16b" "$(mkretro "$N/spacename")" "$ROOT" \
    --good-has 'WARN' --bad-lacks 'WARN'
fi
# TNR-7: no-match returns 0 instead of 2 (case 18).
if mk "teeth TNR-7" "$M-7.sh" 's/\[ "\$hit" -ge 0 \] || return 2/[ "$hit" -ge 0 ] || return 0/'; then
  tnr_tt "teeth TNR-7: no-match-rc mutant flips case 18 (has teeth)" 2 0 "$M-7.sh" "$TN1" "$(mkretro "$N/stranger")" "$ROOT" \
    --good-lacks "$RTERR" --bad-lacks "$RTERR"
fi
# TNR-8: drop the no-resolving-path guard -> a wrong RESEARCH_HOME reads as rc 2 no-match (21a/21d).
if _r="$(blk "$LIB" 'SENTINEL-TNR-NODIR-START' 'SENTINEL-TNR-NODIR-END')"; then
  if mk "teeth TNR-8" "$M-8.sh" "${_r}d"; then
    tnr_tt "teeth TNR-8: no-dir-guard mutant flips case 21a to rc 2 (has teeth)" 1 2 "$M-8.sh" "$TN15" "$(mkretro "$N/rhp")" "/nonexistent-research-home-$$" \
      --good-has "$NODIR" --bad-lacks "$NODIR|$RTERR"
    tnr_tt "teeth TNR-8: no-dir-guard mutant flips case 21d to rc 2 (has teeth)" 1 2 "$M-8.sh" "$TN21d" "$(mkretro "$N/rhp")" "/nonexistent-research-home-$$" \
      --good-has "$NODIR" --bad-lacks "$NODIR|$RTERR"
  fi
else no "teeth TNR-8: locate exact SENTINEL-TNR-NODIR block in LIB" "anchor missing or ambiguous — LIB drifted?"; fi
# TNR-8b: drop the "$RESEARCH_HOME rows exist" scope -> an absolute-only ghost registry becomes rc 1 (21c).
if mk "teeth TNR-8b" "$M-8b.sh" 's/ && \[ "\$_tnr_has_rh" -eq 1 \]//'; then
  tnr_tt "teeth TNR-8b: unscoped no-dir guard flips case 21c to rc 1 (has teeth)" 2 1 "$M-8b.sh" "$TN21c" "$(mkretro "$N/middle")" "$ROOT" \
    --good-lacks "$NODIR|$RTERR" --bad-has "$NODIR" --bad-lacks "$RTERR"
fi
# TNR-9: select the row from the WHOLE line instead of the Path cell (case 22a).
if mk "teeth TNR-9" "$M-9.sh" 's/index(\$4, want)/index($0, want)/'; then
  tnr_tt "teeth TNR-9: whole-row-match mutant flips case 22a (has teeth)" 0 0 "$M-9.sh" "$TN22" "$(mkretro "$N/last")" "$ROOT" \
    --good-lacks '^decoy-first$' --bad-has '^decoy-first$'
fi
# TNR-10: drop the backtick delimiters -> a path that prefixes another row's path matches it (22c).
if mk "teeth TNR-10" "$M-10.sh" 's/want = "`" ENVIRON\["_TP_RAW"\] "`"/want = ENVIRON["_TP_RAW"]/'; then
  tnr_tt "teeth TNR-10: undelimited-match mutant flips case 22c (has teeth)" 0 0 "$M-10.sh" "$TN22c" "$(mkretro "$N/pfx")" "$ROOT" \
    --good-has '^short-one$' --good-lacks '^long-one$' --bad-has '^long-one$'
fi

echo ""
if [ "$fail" -gt 0 ]; then
  printf 'RESULT (with teeth): %d passed / %d FAILED\n' "$pass" "$fail"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"; exit 1
else
  printf 'RESULT (with teeth): %d passed / 0 failed\n' "$pass"
  printf '== %d passed · 0 failed ==\n' "$pass"; exit 0
fi
