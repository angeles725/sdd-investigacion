#!/usr/bin/env bash
# sweep-retros.test.sh — harness for sweep-retros.sh, now a shim to `rsdd sweep retros` (kit issue #2358).
#
# Covers the SHIM contract: existence and the executable bit; the arguments handed to the binary (`sweep retros
# --kit <own kit>`, then every caller argument byte for byte, an empty one included); output and exit code passed
# through; a symlinked invocation; the kit is the shim's, never the caller's cwd; a missing lib or an unusable
# binary → a typed degraded line, never a silent pass; and the real Go binary end to end on a mini kit (a pending
# retro, --json, a missing TARGETS.md, and the WIRING-STATUS pass in a kit with neither bin/ nor Go sources).
# Everything the script decided — the marker and delta grammar, aging, MISSING-RETRO, the grace window, wiring,
# the profile, the --json envelope — is pinned in Go (research-sdd/rsdd/internal/sweep: a behaviour table, a
# golden of the delta-counting corpus, and a differential against the frozen script), not here.
#
# Issue #2525 (this suite failed 3/3 under kit-flake-hunt, first at old case 33): the old cases ran COPIES of the
# script in sandbox kits, so the wiring pass, which resolved rsdd through lib/rsdd-exec.sh, found no binary and no
# sources there and printed `degraded: rsdd-unavailable — no sources at <sandbox>` into every report; every case
# that asserted "no WARN" failed. That was not CPU load: it was deterministic wherever RSDD_BIN was not exported
# (run-all.sh exports it; the flake hunt runs a suite directly). The wiring pass is in process now, and this
# suite builds or takes its own binary (REAL_BIN) and hands it only to the shim under test, so it no longer
# depends on what its caller exported. Case 12 pins exactly that.
#
# --prove-teeth mutates the SHIM (each mutant must lose its case); the Go source has its own mutation gate
# (`make teeth` in research-sdd/rsdd).
#
# Usage: sweep-retros.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-retros.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The wiring pass walks up from a target to its git root: stop at the sandbox so an enclosing repository (this
# kit checkout, for instance) never bleeds into a fixture (kit issue #1140).
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# the shim reads none of these; a stale value from the caller must not change a case
unset RSDD_PROFILE RSDD_RETRO_AGE_DAYS RSDD_MISSING_RETRO_GRACE_HOURS RESEARCH_HOME

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
  cp "${2:-$SUT}" "$1/toolbelt/sweep-retros.sh"; chmod +x "$1/toolbelt/sweep-retros.sh"
  cp "$HERE/../lib/rsdd-exec.sh" "$1/toolbelt/lib/" || exit 2   # stage-libs-ok: the shim needs only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case 7
}
# stub_bin RC OUTPUT — a fake rsdd that records its arguments (one per line) in $TMP/args, prints OUTPUT, exits RC.
stub_bin() {
  printf '%s' "$2" > "$TMP/stub-out.txt"; : > "$TMP/args"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %s\n' "$TMP/args" "$TMP/stub-out.txt" "$1" > "$TMP/stub-rsdd"
  chmod +x "$TMP/stub-rsdd"
}

echo "== sweep-retros.test.sh =="

# 1 — the shim exists and is executable.
[ -f "$SUT" ] && [ -x "$SUT" ] && ok "1 shim exists and is executable" || no "1 shim missing or not executable: $SUT"

stage_kit "$TMP/kit"; SHIM="$TMP/kit/toolbelt/sweep-retros.sh"
PHYS="$(cd -P "$TMP/kit/toolbelt" && pwd -P)"

# 2 — the binary gets `sweep retros --kit <own kit>` and then the caller's arguments, byte for byte.
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" --json 'a b' '' '--x=*' >/dev/null 2>&1
want="$(printf '%s\n' sweep retros --kit "$PHYS/.." --json 'a b' '' '--x=*')"
if [ "$(cat "$TMP/args")" = "$want" ]; then ok "2 binary called as 'sweep retros --kit <own kit>' + the caller's arguments verbatim"
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
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/sweep-retros.sh"
OUT="$(bash "$TMP/nolib/sweep-retros.sh" 2>"$TMP/err7")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q "^degraded: rsdd-unavailable — rsdd-exec.sh missing beside $TMP/nolib/sweep-retros.sh\$" "$TMP/err7"; then
  ok "7 missing rsdd-exec.sh → typed degraded line, rc 2"
else no "7 missing lib: rc=$RC out=[$OUT] err=[$(cat "$TMP/err7")]"; fi

# ---- the real binary, end to end on the mini kit ----
real() { env RSDD_BIN="$REAL_BIN" bash "$SHIM" "$@"; }
T1="$TMP/t1"; mkdir -p "$T1/retros" "$T1/.claude"
printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n| 2 | d2 | because |\n' > "$T1/retros/r1.md"
printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate-stop.sh"}]}]}}\n' > "$T1/.claude/settings.json"
printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | `%s` |\n' "$T1" > "$TMP/kit/TARGETS.md"

# 8 — a pending retro → PENDING, its count, the Summary, the wiring line, exit 0, stderr empty.
OUT="$(real 2>"$TMP/err8")"; RC=$?
if [ "$RC" = 0 ] && grep -qF "PENDING  $T1/retros/r1.md" <<<"$OUT" && grep -q '~2 proposed deltas' <<<"$OUT" \
   && grep -q '^Summary: 1 pending / 1 retros across targets\.$' <<<"$OUT" \
   && grep -q '^Wiring: 1 wired / 0 wired-off-root / 0 unwired / 0 absent-settings / 0 unreadable — 1 targets checked\.$' <<<"$OUT" \
   && [ ! -s "$TMP/err8" ]; then
  ok "8 end to end: pending retro surfaced, summary and wiring lines, exit 0"
else no "8 end to end: rc=$RC out=[$OUT] err=[$(cat "$TMP/err8")]"; fi

# 9 — --json → exactly one envelope of the documented schema (jq reads it), stdout only.
OUT="$(real --json 2>/dev/null)"; RC=$?
if [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -s length 2>/dev/null)" = 1 ] \
   && [ "$(printf '%s' "$OUT" | jq -r '[.schema,.state,.counts.pending,.items[0].deltas]|join(",")' 2>/dev/null)" = "research-sdd.sweep-retros/v1,ok,1,2" ]; then
  ok "9 end to end --json: one research-sdd.sweep-retros/v1 envelope, state ok"
else no "9 --json: rc=$RC out=[$OUT]"; fi

# 10 — no TARGETS.md → exit 1 and the typed line naming the kit's physical path, no report.
KITPHYS="$(cd -P "$TMP/kit" && pwd -P)"
mv "$TMP/kit/TARGETS.md" "$TMP/targets.keep"
OUT="$(real 2>"$TMP/err10")"; RC=$?
if [ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(cat "$TMP/err10")" = "sweep-retros: cannot find $KITPHYS/TARGETS.md" ]; then
  ok "10 missing TARGETS.md → exit 1, typed message, no report"
else no "10 missing TARGETS.md: rc=$RC out=[$OUT] err=[$(cat "$TMP/err10")]"; fi

# 11 — a TARGETS.md with no usable path → exit 1 and the two typed ERROR lines (anti-silent-zero), no Summary.
printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | /no/backticks |\n' > "$TMP/kit/TARGETS.md"
OUT="$(real 2>"$TMP/err11")"; RC=$?
if [ "$RC" = 1 ] && [ -z "$OUT" ] && grep -qxF "sweep-retros: ERROR — no usable target paths in $KITPHYS/TARGETS.md" "$TMP/err11"; then
  ok "11 no usable target path → exit 1, typed ERROR, no Summary"
else no "11 no usable path: rc=$RC out=[$OUT] err=[$(cat "$TMP/err11")]"; fi
printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | `%s` |\n' "$T1" > "$TMP/kit/TARGETS.md"

# 12 — #2525: a kit with NO bin/ and NO Go sources, RSDD_BIN set only for the shim under test: the wiring pass is in
# process, so the report carries no degraded line and the wiring counts are real. (The old script resolved rsdd a
# second time inside the sandbox and printed `degraded: rsdd-unavailable — no sources` there.)
OUT="$(env -u RSDD_BIN RSDD_BIN="$REAL_BIN" bash "$SHIM" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! grep -qi 'degraded' <<<"$OUT" && grep -q '^Wiring: 1 wired / ' <<<"$OUT" && ! grep -q '^WARN' <<<"$OUT"; then
  ok "12 #2525: no second rsdd resolution — a bare kit copy reports real wiring counts and no degraded line"
else no "12 #2525: rc=$RC out=[$OUT]"; fi

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
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mA/toolbelt/sweep-retros.sh" --json >/dev/null 2>&1
    if [ "$(sed -n 3p "$TMP/args")" != "--kit" ]; then ok "teeth A: --kit dropped → case 2 would go RED"; else no "teeth A: mutant still passes --kit"; fi
  fi
  # B: the caller's arguments are dropped → case 2 and 9.
  if mk_mut "teeth B: arguments dropped" "$SUT" "$TMP/mutB.sh" 's/"\$@"$//'; then
    stage_kit "$TMP/mB" "$TMP/mutB.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mB/toolbelt/sweep-retros.sh" --json >/dev/null 2>&1
    if ! grep -qx -- '--json' "$TMP/args"; then ok "teeth B: arguments dropped → case 2 would go RED"; else no "teeth B: mutant still passes the arguments"; fi
  fi
  # C: the shim runs the hook mode instead of the sweep → case 2 sees the wrong command.
  if mk_mut "teeth C: wrong command" "$SUT" "$TMP/mutC.sh" 's/rsdd_exec sweep retros --kit/rsdd_exec sweep retros --hook --kit/'; then
    stage_kit "$TMP/mC" "$TMP/mutC.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mC/toolbelt/sweep-retros.sh" >/dev/null 2>&1
    if grep -qx -- '--hook' "$TMP/args"; then ok "teeth C: hook mode in the CLI shim → case 2 would go RED"; else no "teeth C: mutant does not pass --hook"; fi
  fi
  # D: the missing-lib guard stripped → no typed degraded line → case 7.
  if mk_mut "teeth D: guard removed" "$SUT" "$TMP/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$TMP/mD"; cp "$TMP/mutD.sh" "$TMP/mD/sweep-retros.sh"
    bash "$TMP/mD/sweep-retros.sh" >/dev/null 2>"$TMP/errD"
    if ! grep -q 'rsdd-exec.sh missing beside' "$TMP/errD"; then ok "teeth D: unguarded shim no longer announces a missing lib → case 7 would go RED"; else no "teeth D: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
