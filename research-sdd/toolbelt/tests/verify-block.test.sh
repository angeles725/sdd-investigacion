#!/usr/bin/env bash
# verify-block.test.sh — the SHIM contract of verify-block.sh (kit issue #2456).
#
# verify-block.sh is a compatibility shim to `rsdd verify block`. Every check the old 2,800-line suite made on the
# report (marker tally, citation resolution, digests, ephemeral paths, manifests, back-pointers, ...) now lives in the
# Go package: internal/verify/block runs the frozen bash script (testdata/block-legacy) on every fixture the old suites used
# (testdata/block-cases.txt, captured by running them) plus hand-written and generated ones, and asserts the same
# stdout, stderr and exit code (`make test`; the Go mutation gate is `make teeth` in research-sdd/rsdd). What stays
# here is what only the shim can show: the arguments, the environment and the exit codes cross the bash/Go boundary
# unchanged, and an absent binary or helper is a typed degraded line, never a silent pass.
# --prove-teeth mutates the SHIM (each mutant must lose its case); the Go source has its own mutation gate.
#
# Usage: verify-block.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-block.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The Go binary the shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$TMP/rsdd"
fi
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a fixture toolbelt
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== verify-block.test.sh =="

# A fixture toolbelt holding a shim (the real one, or a mutant) and the libs it hands over to.
stage(){ mkdir -p "$1"; rsdd_stage_libs "$1"; cp "${2:-$SUT}" "$1/verify-block.sh"; }
# A block with a header legend, one [CERT] claim and one citation of a file next to it.
mkblock(){ local f="$1/b.md"; shift; { echo "# Block 1 — t"; echo; echo "> Type: evidence. Method: [CERT] = x."; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$f"; }
D="$TMP/t"; mkdir -p "$D"; mkblock "$D" 'Extends X [CERT] `A.java:2`.'; printf 'a\nb\nc\n' > "$D/A.java"
stage "$TMP/tb"

# SHIM-1 — the report is the binary's, byte for byte, stdout and exit code.
out="$(cd "$D" && bash "$TMP/tb/verify-block.sh" b.md 2>"$TMP/e1")"; rc=$?
want="$(cd "$D" && "$RSDD_BIN" verify block b.md 2>/dev/null)"
if [ "$rc" = 0 ] && [ "$out" = "$want" ] && grep -q '^== verify-block: b.md (target: \.) ==$' <<<"$out" && grep -q '^   ok      A.java:2$' <<<"$out" && grep -q '^== exit 0 ==$' <<<"$out" && [ ! -s "$TMP/e1" ]; then
  ok "SHIM-1 the shim prints the binary's report (rc 0, nothing on stderr)"
else no "SHIM-1 rc=$rc :: $out"; fi

# SHIM-2 — the optional target-dir argument crosses the boundary (a cite resolves against it, not the block's dir).
mkdir -p "$TMP/other"; printf '1\n2\n3\n4\n' > "$TMP/other/A.java"; mkblock "$TMP/other" 'x [CERT] `A.java:4`.'; mkdir -p "$TMP/blk"; mkblock "$TMP/blk" 'x [CERT] `A.java:4`.'
out="$(bash "$TMP/tb/verify-block.sh" "$TMP/blk/b.md" "$TMP/other" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "(target: $TMP/other)" <<<"$out" && grep -q '^   ok      A.java:4$' <<<"$out"; then ok "SHIM-2 target-dir argument is passed through"
else no "SHIM-2 rc=$rc :: $(grep -E 'target|A.java' <<<"$out")"; fi

# SHIM-3 — every flag crosses the boundary: --extern-check, --backptr=off|all, --ephemeral=warn|fail, --strict-ephemeral.
mkblock "$D" 'Cites `/tmp/x/y.log:3`.'
o1="$(cd "$D" && bash "$TMP/tb/verify-block.sh" --extern-check b.md 2>&1)"
o2="$(cd "$D" && bash "$TMP/tb/verify-block.sh" --backptr=off b.md 2>&1)"
o3="$(cd "$D" && bash "$TMP/tb/verify-block.sh" --ephemeral=warn b.md 2>&1)"; r3=$?
o4="$(cd "$D" && bash "$TMP/tb/verify-block.sh" --ephemeral=warn --ephemeral=fail b.md 2>&1)"; r4=$?
o5="$(cd "$D" && bash "$TMP/tb/verify-block.sh" --strict-ephemeral b.md 2>&1)"; r5=$?
o6="$(cd "$D" && bash "$TMP/tb/verify-block.sh" --backptr=all b.md 2>&1)"
if grep -q '^   extern-check: verified ' <<<"$o1" && grep -q 'back-pointer check off' <<<"$o2" && [ "$r3" = 0 ] && grep -q 'EPHEMERAL?' <<<"$o3" \
   && [ "$r4" = 1 ] && grep -q 'EPHEMERAL!' <<<"$o4" && [ "$r5" = 1 ] && grep -q 'EPHEMERAL!' <<<"$o5" && grep -q 'back-pointer check skipped' <<<"$o6"; then
  ok "SHIM-3 --extern-check, --backptr=*, --ephemeral=* and --strict-ephemeral reach the command (the last flag wins)"
else no "SHIM-3 r3=$r3 r4=$r4 r5=$r5 :: $(grep -E 'extern-check|back-pointer|EPHEMERAL' <<<"$o1$o2$o3$o4" | head -5)"; fi

# SHIM-4 — exit codes and the stream each message goes to: usage errors are rc 2 with an empty stdout.
out="$(bash "$TMP/tb/verify-block.sh" 2>"$TMP/e4")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q '^usage: verify-block.sh ' "$TMP/e4"; then ok "SHIM-4a no block → usage on stderr, rc 2"; else no "SHIM-4a rc=$rc out=[$out] err=[$(cat "$TMP/e4")]"; fi
out="$(bash "$TMP/tb/verify-block.sh" --ephemeral=maybe "$D/b.md" 2>"$TMP/e4")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q "unknown --ephemeral value '=maybe'" "$TMP/e4"; then ok "SHIM-4b bad --ephemeral value → rc 2 on stderr"; else no "SHIM-4b rc=$rc err=[$(cat "$TMP/e4")]"; fi
out="$(bash "$TMP/tb/verify-block.sh" --backptr=none "$D/b.md" 2>"$TMP/e4")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q "unknown --backptr value '=none'" "$TMP/e4"; then ok "SHIM-4c bad --backptr value → rc 2 on stderr"; else no "SHIM-4c rc=$rc err=[$(cat "$TMP/e4")]"; fi
out="$(bash "$TMP/tb/verify-block.sh" --possibility-sweep "$TMP/no-such-dir" 2>"$TMP/e4")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q '^usage: verify-block.sh --possibility-sweep <corpus-dir>$' "$TMP/e4"; then ok "SHIM-4d --possibility-sweep without a directory → rc 2"; else no "SHIM-4d rc=$rc"; fi
mkdir -p "$TMP/bad"; printf '# Block 1\n\nCites `Z.java:9`.\n' > "$TMP/bad/b.md"; printf 'x\n' > "$TMP/bad/Z.java"
out="$(bash "$TMP/tb/verify-block.sh" "$TMP/bad/b.md" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q '^   RANGE!  Z.java:9  (file has 1 lines)' <<<"$out" && grep -q '^== exit 1 ==$' <<<"$out"; then ok "SHIM-4e a cite past EOF → rc 1 (the script's own exit contract)"; else no "SHIM-4e rc=$rc"; fi

# SHIM-5 — the environment crosses the boundary: RSDD_STRICT_EPHEMERAL (only 0 opts out; anything else says so once) and SOURCE_ROOT.
mkblock "$D" 'Cites `/tmp/x/y.log:3`.'
out="$(cd "$D" && RSDD_STRICT_EPHEMERAL=0 bash "$TMP/tb/verify-block.sh" b.md 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q 'EPHEMERAL?' <<<"$out"; then ok "SHIM-5a RSDD_STRICT_EPHEMERAL=0 opts out (WARN, rc 0)"; else no "SHIM-5a rc=$rc"; fi
out="$(cd "$D" && RSDD_STRICT_EPHEMERAL=yes bash "$TMP/tb/verify-block.sh" b.md 2>"$TMP/e5")"; rc=$?
if [ "$rc" = 1 ] && grep -q "RSDD_STRICT_EPHEMERAL='yes' is not 0 or 1" "$TMP/e5"; then ok "SHIM-5b a malformed value keeps the FAIL default and says so on stderr"; else no "SHIM-5b rc=$rc err=[$(cat "$TMP/e5")]"; fi
mkdir -p "$TMP/srcroot"; printf '1\n2\n' > "$TMP/srcroot/Q.java"; mkblock "$D" 'x [CERT] `Q.java:2`.'
out="$(cd "$D" && SOURCE_ROOT="$TMP/srcroot" bash "$TMP/tb/verify-block.sh" b.md 2>&1)"
if grep -q '^   ok      Q.java:2$' <<<"$out"; then ok "SHIM-5c SOURCE_ROOT resolves a cite outside the target"; else no "SHIM-5c :: $(grep Q.java <<<"$out")"; fi

# SHIM-6 — a symlinked shim finds its libs beside the real file, not beside the link (kit #1675), and the cwd is irrelevant.
mkdir -p "$TMP/ln"; ln -s "$TMP/tb/verify-block.sh" "$TMP/ln/verify-block.sh"
out="$(cd / && bash "$TMP/ln/verify-block.sh" "$D/b.md" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q '^== exit 0 ==$' <<<"$out"; then ok "SHIM-6 a symlinked shim runs from any cwd"; else no "SHIM-6 rc=$rc :: $out"; fi

# SHIM-7 — a missing rsdd-exec.sh or an unusable binary is a typed degraded line (rc 2, empty stdout), never a pass.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/verify-block.sh"
out="$(bash "$TMP/nolib/verify-block.sh" "$D/b.md" 2>"$TMP/e7")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q '^degraded: rsdd-unavailable — rsdd-exec.sh missing beside ' "$TMP/e7"; then ok "SHIM-7a missing rsdd-exec.sh → typed degraded line, rc 2"; else no "SHIM-7a rc=$rc err=[$(cat "$TMP/e7")]"; fi
out="$(RSDD_BIN="$TMP/does-not-exist" bash "$SUT" "$D/b.md" 2>"$TMP/e7")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/e7"; then ok "SHIM-7b unusable RSDD_BIN → typed degraded line, rc 2"; else no "SHIM-7b rc=$rc err=[$(cat "$TMP/e7")]"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"
  # A: the arguments are dropped → the block is never seen (SHIM-1/2/3).
  if mk_mut "teeth A: arguments dropped" "$SUT" "$TMP/vmutA.sh" 's/rsdd_exec verify block "\$@"/rsdd_exec verify block/'; then
    stage "$TMP/vmA" "$TMP/vmutA.sh"
    mo="$(cd "$D" && bash "$TMP/vmA/verify-block.sh" b.md 2>&1)"; mrc=$?
    if [ "$mrc" = 2 ] && ! grep -q '^== verify-block' <<<"$mo"; then ok "teeth A: arguments dropped → usage error, SHIM-1 would go RED"; else no "teeth A: mutant still reports (rc=$mrc)"; fi
  fi
  # B: the wrong subcommand → no verify-block report.
  if mk_mut "teeth B: wrong subcommand" "$SUT" "$TMP/vmutB.sh" 's/verify block/verify state/'; then
    stage "$TMP/vmB" "$TMP/vmutB.sh"
    mo="$(cd "$D" && bash "$TMP/vmB/verify-block.sh" b.md 2>&1)"
    if ! grep -q '^== verify-block: b.md' <<<"$mo"; then ok "teeth B: wrong subcommand → no verify-block report, SHIM-1 would go RED"; else no "teeth B: mutant still prints the report"; fi
  fi
  # C: the missing-lib guard stripped → no typed degraded line (SHIM-7a).
  if mk_mut "teeth C: guard removed" "$SUT" "$TMP/vmutC.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$TMP/vmC"; cp "$TMP/vmutC.sh" "$TMP/vmC/verify-block.sh"
    bash "$TMP/vmC/verify-block.sh" "$D/b.md" >/dev/null 2>"$TMP/errvmC"
    if ! grep -q 'rsdd-exec.sh missing beside' "$TMP/errvmC"; then ok "teeth C: unguarded shim no longer announces a missing lib → SHIM-7a would go RED"; else no "teeth C: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
