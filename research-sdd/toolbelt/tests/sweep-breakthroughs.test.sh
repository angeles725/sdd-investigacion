#!/usr/bin/env bash
# sweep-breakthroughs.test.sh — harness for sweep-breakthroughs.sh, now a shim to `rsdd sweep breakthroughs` (kit issue #2360).
#
# Covers the SHIM contract: existence and the executable bit; the arguments handed to the binary (`sweep breakthroughs
# --kit <own kit>`, then every caller argument byte for byte, an empty one included); output and exit code passed
# through; a symlinked invocation; the kit is the shim's, never the caller's cwd; a missing lib or an unusable
# binary → a typed degraded line, never a silent pass; and the real Go binary end to end on a mini kit (one
# unindexed breakthrough, a caller argument the script ignored, a missing TARGETS.md, a missing BREAKTHROUGHS.md, no
# usable target path, and a bare kit copy with neither bin/ nor Go sources).
# Everything the script decided — the marker form, the block-file filter, the ledger pointers and their line
# matching, the drift pass, the absent-input / empty-input / no-match states, the PARTIAL warning, RESEARCH_HOME
# paths — is pinned in Go (research-sdd/rsdd/internal/sweep: a behaviour table, a golden recorded from the frozen
# script, unit tests of every boundary, and a differential against the frozen script). The map from every old case
# to its Go test is L4 of odd/tasks/sweep-breakthroughs-go.md. The old mutation controls M1-M17 mutated the script
# body, which is a shim now: each one is replaced by the Go test named in that map, and the Go source has its own
# mutation gate (`make teeth` in research-sdd/rsdd).
#
# --prove-teeth mutates the SHIM (each mutant must lose its case).
#
# Usage: sweep-breakthroughs.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-breakthroughs.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# the shim reads none of these; a stale value from the caller must not change a case
unset RSDD_RETRO_AGE_DAYS RESEARCH_HOME

# The Go binary the end-to-end cases run: the caller's RSDD_BIN, else one build into the temp dir.
REAL_BIN="${RSDD_BIN:-}"
if [ -z "$REAL_BIN" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  REAL_BIN="$TMP/rsdd"
fi

# stage_kit DEST [SHIM] — a mini kit: the shim (the real one, or a mutant) and lib/rsdd-exec.sh. The toolbelt is
# DEST/toolbelt. No bin/ and no Go sources: the binary can only come from RSDD_BIN.
stage_kit() {
  mkdir -p "$1/toolbelt/lib"
  cp "${2:-$SUT}" "$1/toolbelt/sweep-breakthroughs.sh"; chmod +x "$1/toolbelt/sweep-breakthroughs.sh"
  cp "$HERE/../lib/rsdd-exec.sh" "$1/toolbelt/lib/" || exit 2   # stage-libs-ok: the shim needs only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case 7
}
# stub_bin RC OUTPUT — a fake rsdd that records its arguments (one per line) in $TMP/args, prints OUTPUT, exits RC.
stub_bin() {
  printf '%s' "$2" > "$TMP/stub-out.txt"; : > "$TMP/args"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %s\n' "$TMP/args" "$TMP/stub-out.txt" "$1" > "$TMP/stub-rsdd"
  chmod +x "$TMP/stub-rsdd"
}

echo "== sweep-breakthroughs.test.sh =="

# 1 — the shim exists and is executable.
[ -f "$SUT" ] && [ -x "$SUT" ] && ok "1 shim exists and is executable" || no "1 shim missing or not executable: $SUT"

stage_kit "$TMP/kit"; SHIM="$TMP/kit/toolbelt/sweep-breakthroughs.sh"
PHYS="$(cd -P "$TMP/kit/toolbelt" && pwd -P)"

# 2 — the binary gets `sweep breakthroughs --kit <own kit>` and then the caller's arguments, byte for byte.
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" --json 'a b' '' '--x=*' >/dev/null 2>&1
want="$(printf '%s\n' sweep breakthroughs --kit "$PHYS/.." --json 'a b' '' '--x=*')"
if [ "$(cat "$TMP/args")" = "$want" ]; then ok "2 binary called as 'sweep breakthroughs --kit <own kit>' + the caller's arguments verbatim"
else no "2 arguments differ: [$(tr '\n' '|' < "$TMP/args")]"; fi

# 3 — output and exit code pass through unchanged (stdout and the code are the binary's work).
stub_bin 1 "from the binary
"
OUT="$(RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "from the binary" ]; then ok "3 output and exit code pass through"; else no "3 passthrough differs (rc=$RC out=[$OUT])"; fi

# 4 — invoked through a symlink in another directory, the shim still names its REAL kit.
mkdir -p "$TMP/elsewhere"; ln -s "$SHIM" "$TMP/elsewhere/link.sh"
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/elsewhere/link.sh" >/dev/null 2>&1
if [ "$(sed -n 4p "$TMP/args")" = "$PHYS/.." ]; then ok "4 symlinked shim → binary gets the physical own kit"; else no "4 symlink: args=[$(tr '\n' '|' < "$TMP/args")]"; fi

# 5 — the kit is the shim's, never the caller's cwd.
( cd "$TMP/elsewhere" && RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" >/dev/null 2>&1 )
if [ "$(sed -n 4p "$TMP/args")" = "$PHYS/.." ]; then ok "5 the kit does not depend on the cwd"; else no "5 cwd leaked into the kit: [$(sed -n 4p "$TMP/args")]"; fi

# 6 — an unusable RSDD_BIN → a typed degraded line on stderr, rc 2, nothing on stdout (the sweep could not run).
OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$SHIM" 2>"$TMP/err6")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/err6"; then
  ok "6 unusable RSDD_BIN → typed degraded line, rc 2"
else no "6 unusable binary: rc=$RC out=[$OUT] err=[$(cat "$TMP/err6")]"; fi

# 7 — the shim's own lib missing → a typed degraded line, rc 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/sweep-breakthroughs.sh"
OUT="$(bash "$TMP/nolib/sweep-breakthroughs.sh" 2>"$TMP/err7")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q "^degraded: rsdd-unavailable — rsdd-exec.sh missing beside $TMP/nolib/sweep-breakthroughs.sh\$" "$TMP/err7"; then
  ok "7 missing rsdd-exec.sh → typed degraded line, rc 2"
else no "7 missing lib: rc=$RC out=[$OUT] err=[$(cat "$TMP/err7")]"; fi

# ---- the real binary, end to end on the mini kit ----
real() { env RSDD_BIN="$REAL_BIN" bash "$SHIM" "$@"; }
T1="$TMP/t1"; mkdir -p "$T1"
printf '# Block 1\n\n> **Breakthrough:** cracked it\n' > "$T1/pfx-block1.md"
printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | `%s` |\n' "$T1" > "$TMP/kit/TARGETS.md"
printf '| # | target | what | how |\n|---|---|---|---|\n' > "$TMP/kit/BREAKTHROUGHS.md"
KITPHYS="$(cd -P "$TMP/kit" && pwd -P)"

# 8 — an unindexed breakthrough → the WARN, the Summary and the hint, exit 0, stderr empty.
OUT="$(real 2>"$TMP/err8")"; RC=$?
if [ "$RC" = 0 ] && grep -qxF "WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: $T1/pfx-block1.md:3" <<<"$OUT" \
   && grep -q '^Summary: 1 tagged breakthrough(s) across corpora · 1 unindexed · 0 drifted · 0 skipped-unreadable\.$' <<<"$OUT" \
   && [ ! -s "$TMP/err8" ]; then
  ok "8 end to end: unindexed breakthrough warned, summary printed, exit 0"
else no "8 end to end: rc=$RC out=[$OUT] err=[$(cat "$TMP/err8")]"; fi

# 9 — an unknown argument is a usage error (#2687; the bash script ignored it): exit 2, the typed line, no report.
OUT="$(real --json extra 2>"$TMP/err9")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$(cat "$TMP/err9")" = "sweep-breakthroughs: unsupported argument \"extra\"" ]; then
  ok "9 end to end: an unknown argument is refused with exit 2 (#2687)"
else no "9 unknown argument: rc=$RC out=[$OUT] err=[$(cat "$TMP/err9")]"; fi

# 10 — no TARGETS.md → exit 1 and the typed line naming the kit's physical path, no report.
mv "$TMP/kit/TARGETS.md" "$TMP/targets.keep"
OUT="$(real 2>"$TMP/err10")"; RC=$?
if [ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(cat "$TMP/err10")" = "sweep-breakthroughs: cannot find $KITPHYS/TARGETS.md" ]; then
  ok "10 missing TARGETS.md → exit 1, typed message, no report"
else no "10 missing TARGETS.md: rc=$RC out=[$OUT] err=[$(cat "$TMP/err10")]"; fi
mv "$TMP/targets.keep" "$TMP/kit/TARGETS.md"

# 11 — no BREAKTHROUGHS.md → exit 1 and the typed line, no report.
mv "$TMP/kit/BREAKTHROUGHS.md" "$TMP/ledger.keep"
OUT="$(real 2>"$TMP/err11")"; RC=$?
if [ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(cat "$TMP/err11")" = "sweep-breakthroughs: cannot find $KITPHYS/BREAKTHROUGHS.md" ]; then
  ok "11 missing BREAKTHROUGHS.md → exit 1, typed message, no report"
else no "11 missing BREAKTHROUGHS.md: rc=$RC out=[$OUT] err=[$(cat "$TMP/err11")]"; fi
mv "$TMP/ledger.keep" "$TMP/kit/BREAKTHROUGHS.md"

# 12 — a TARGETS.md with no usable path → exit 1 and the typed ERROR line (anti-silent-zero), no Summary.
mv "$TMP/kit/TARGETS.md" "$TMP/targets.keep"
printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | /no/backticks |\n' > "$TMP/kit/TARGETS.md"
OUT="$(real 2>"$TMP/err12")"; RC=$?
if [ "$RC" = 1 ] && [ -z "$OUT" ] && grep -qxF "sweep-breakthroughs: ERROR — no usable target paths in $KITPHYS/TARGETS.md" "$TMP/err12"; then
  ok "12 no usable target path → exit 1, typed ERROR, no Summary"
else no "12 no usable path: rc=$RC out=[$OUT] err=[$(cat "$TMP/err12")]"; fi
rm -f "$TMP/kit/TARGETS.md"; mv "$TMP/targets.keep" "$TMP/kit/TARGETS.md"

# 13 — a kit with NO bin/ and NO Go sources, RSDD_BIN set only for the shim under test: the report carries no
# degraded line (the binary is the only thing the shim needs; it resolves nothing else).
OUT="$(env -u RSDD_BIN RSDD_BIN="$REAL_BIN" bash "$SHIM" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! grep -qi 'degraded' <<<"$OUT" && grep -q '^Summary: 1 tagged breakthrough(s) across corpora' <<<"$OUT"; then
  ok "13 a bare kit copy reports and prints no degraded line"
else no "13 bare kit: rc=$RC out=[$OUT]"; fi

# NEGATIVE CONTROL — each shim mutation must lose its case.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"

  # A: the own kit is no longer handed over → case 2 (and the real binary would resolve some other kit).
  if mk_mut "teeth A: --kit dropped" "$SUT" "$TMP/mutA.sh" 's/ --kit "\$_RSDD_SELF\/\.\."//'; then
    stage_kit "$TMP/mA" "$TMP/mutA.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mA/toolbelt/sweep-breakthroughs.sh" --json >/dev/null 2>&1
    if [ "$(sed -n 3p "$TMP/args")" != "--kit" ]; then ok "teeth A: --kit dropped → case 2 would go RED"; else no "teeth A: mutant still passes --kit"; fi
  fi
  # B: the caller's arguments are dropped → case 2.
  if mk_mut "teeth B: arguments dropped" "$SUT" "$TMP/mutB.sh" 's/"\$@"$//'; then
    stage_kit "$TMP/mB" "$TMP/mutB.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mB/toolbelt/sweep-breakthroughs.sh" --json >/dev/null 2>&1
    if ! grep -qx -- '--json' "$TMP/args"; then ok "teeth B: arguments dropped → case 2 would go RED"; else no "teeth B: mutant still passes the arguments"; fi
  fi
  # C: the shim runs the hook mode instead of the sweep → case 2 sees the wrong command.
  if mk_mut "teeth C: wrong command" "$SUT" "$TMP/mutC.sh" 's/rsdd_exec sweep breakthroughs --kit/rsdd_exec sweep breakthroughs --hook --kit/'; then
    stage_kit "$TMP/mC" "$TMP/mutC.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mC/toolbelt/sweep-breakthroughs.sh" >/dev/null 2>&1
    if grep -qx -- '--hook' "$TMP/args"; then ok "teeth C: hook mode in the CLI shim → case 2 would go RED"; else no "teeth C: mutant does not pass --hook"; fi
  fi
  # D: the missing-lib guard stripped → no typed degraded line → case 7.
  if mk_mut "teeth D: guard removed" "$SUT" "$TMP/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$TMP/mD"; cp "$TMP/mutD.sh" "$TMP/mD/sweep-breakthroughs.sh"
    bash "$TMP/mD/sweep-breakthroughs.sh" >/dev/null 2>"$TMP/errD"
    if ! grep -q 'rsdd-exec.sh missing beside' "$TMP/errD"; then ok "teeth D: unguarded shim no longer announces a missing lib → case 7 would go RED"; else no "teeth D: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
