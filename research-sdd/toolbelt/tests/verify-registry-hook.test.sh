#!/usr/bin/env bash
# verify-registry-hook.test.sh — shim-contract harness for verify-registry-hook.sh, now a shim to
# `rsdd verify registry-hook` (kit issues #2363/#2364).
#
# The behaviour itself — the compact filter (WARN cap and ranking, per-row INFO count, long-INFO shortening, the UTF-8
# trim), the two headers and the envelope — is pinned in Go: research-sdd/rsdd/internal/verify (registryhook_test.go and,
# against the frozen bash hook, registryhook_diff_test.go; run by `make test`). This suite keeps what a bash caller can
# break: the SHIM — its kit hand-off, the arguments, the exit code (a hook never fails the session), a missing lib and an
# unusable binary — end to end through the real Go binary (RSDD_BIN, else one build into the temp dir).
# --prove-teeth mutates the SHIM (each mutant must lose its case); the Go source has its own mutation gate.
#
# Usage: verify-registry-hook.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.

set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-registry-hook.sh"
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox toolbelt
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to read the hook envelope" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The Go binary the shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$TMP/rsdd"
fi
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-registry-hook.test.sh =="

# 1-2. Existence and executable bit.
[ -f "$SUT" ] && ok "1 hook exists at $SUT" || no "1 hook NOT found at $SUT"
[ -x "$SUT" ] && ok "2 hook is executable" || no "2 hook NOT executable (missing +x bit)"

# mk_kit <name> [shim] : a sandbox kit <TMP>/<name>/toolbelt holding the shim (the real one, or a mutant) and every lib;
# prints the kit dir. A drift fixture (claim 40 md, real 5) goes in TARGETS.md when the kit is given a target.
mk_kit() { local k="$TMP/$1"; rsdd_stage_libs "$k/toolbelt"; cp "${2:-$SUT}" "$k/toolbelt/verify-registry-hook.sh"; chmod +x "$k/toolbelt/verify-registry-hook.sh"; printf '%s' "$k"; }
mkdir -p "$TMP/tgt"; echo s > "$TMP/tgt/RESEARCH-STATE.md"; for i in 1 2 3 4 5; do echo b > "$TMP/tgt/p-block$i.md"; done
put_targets() { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n| 0 | kit | active (0 md / nc / git yes) | `%s` |\n| 1 | t1 | mature (40 md / git yes) | `%s` |\n' "$1" "$TMP/tgt" > "$1/TARGETS.md"; }
# ctx <json> : the envelope's additionalContext.
ctx() { jq -r '.hookSpecificOutput.additionalContext' <<<"$1" 2>/dev/null; }
DRIFT='WARN  tgt — TARGETS.md row claims 40 md but the corpus has 5 real block file'
export RESEARCH_HOME="$TMP/home"

K="$(mk_kit k1)"; put_targets "$K"

# 3. The registry check could not run (no TARGETS.md) → the operational-failure banner, exit 0: a hook never fails the session.
K3="$(mk_kit k3)"
OUT="$(bash "$K3/toolbelt/verify-registry-hook.sh" 2>&1)"; RC=$?
C="$(ctx "$OUT")"
if [ "$RC" = 0 ] && grep -q '^Research-SDD registry check could not run (exit 1 — check TARGETS.md and lib/ helper):$' <<<"$C" && grep -q 'cannot find' <<<"$C"; then
  ok "3 registry check failure (exit 1) → 'could not run' banner with the check's message, hook exits 0"
else no "3 operational failure: rc=$RC out=[$OUT]"; fi

# 4. Success → the neutral header, the compact report of THIS kit (its own drift named) and the pointer to the full detail.
OUT="$(bash "$K/toolbelt/verify-registry-hook.sh" 2>&1)"; RC=$?
C="$(ctx "$OUT")"
if [ "$RC" = 0 ] && [ "$(head -1 <<<"$C")" = "Research-SDD registry check (TARGETS.md vs reality):" ] && grep -qE "^$DRIFT" <<<"$C" \
   && [ "$(tail -1 <<<"$C")" = "Full detail: toolbelt/verify-registry.sh (or this hook with --full)." ] \
   && [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$OUT")" = SessionStart ]; then
  ok "4 success → SessionStart envelope, 'registry check' header, this kit's drift, compact pointer"
else no "4 success: rc=$RC out=[$OUT]"; fi

# 5. --full reaches the binary: the report is unchanged (no compact pointer, the Summary line is there).
OUT="$(bash "$K/toolbelt/verify-registry-hook.sh" --full 2>&1)"; RC=$?
C="$(ctx "$OUT")"
if [ "$RC" = 0 ] && grep -q '^Summary: reconciled 2 target' <<<"$C" && grep -qE "^$DRIFT" <<<"$C" && ! grep -q 'Full detail: toolbelt' <<<"$C"; then
  ok "5 --full → the report passes through unchanged (no compact pointer)"
else no "5 --full: rc=$RC out=[$OUT]"; fi

# 6. The shim's own lib missing → a visible line (never empty stdout), exit 0.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/verify-registry-hook.sh"
OUT="$(bash "$TMP/nolib/verify-registry-hook.sh" 2>"$TMP/err6")"; RC=$?
if [ "$RC" = 0 ] && [ "$OUT" = "Research-SDD hook: lib/rsdd-exec.sh missing beside $TMP/nolib/verify-registry-hook.sh" ]; then
  ok "6 missing rsdd-exec.sh → announced on stdout, exit 0"
else no "6 missing lib: rc=$RC out=[$OUT] err=[$(cat "$TMP/err6")]"; fi

# 7. An unusable RSDD_BIN → the sweep-mode degraded envelope on stdout (typed line on stderr), exit 0.
OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$K/toolbelt/verify-registry-hook.sh" 2>"$TMP/err7")"; RC=$?
C="$(ctx "$OUT")"
if [ "$RC" = 0 ] && grep -q '^Research-SDD hooks DEGRADED: rsdd-unavailable — RSDD_BIN not executable: ' <<<"$C" && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/err7"; then
  ok "7 unusable RSDD_BIN → DEGRADED envelope (stdout) and typed stderr line, exit 0"
else no "7 unusable binary: rc=$RC out=[$OUT] err=[$(cat "$TMP/err7")]"; fi

# 8. Run through a symlink (the idiom installed corpora use): the shim still finds its lib and ITS kit.
ln -s "$K/toolbelt/verify-registry-hook.sh" "$TMP/hook-link.sh"
OUT8="$(bash "$TMP/hook-link.sh" 2>&1)"; RC8=$?
if [ "$RC8" = 0 ] && [ "$OUT8" = "$(bash "$K/toolbelt/verify-registry-hook.sh" 2>&1)" ]; then ok "8 a symlinked shim resolves its own directory and kit (same envelope)"
else no "8 symlinked shim: rc=$RC8 out=[$OUT8]"; fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutants are built by lib/mutant.sh (kit #1299), sourced ONLY on this path. It refuses an empty, byte-identical,
  # syntax-broken or live-tree mutant; mutant_chain also refuses a sed stage that matches nothing. A refused build is
  # counted exactly once (mk_mut) and its tooth is skipped.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut() { rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"

  # A: the kit hand-off dropped → the binary reconciles some other kit: case 4 loses this kit's own drift.
  if mk_mut "teeth A: --kit dropped" "$SUT" "$TMP/mutA.sh" 's/ --kit "\$KIT"//'; then
    KA="$(mk_kit tmA "$TMP/mutA.sh")"; put_targets "$KA"
    OUTA="$(bash "$KA/toolbelt/verify-registry-hook.sh" 2>&1)"
    if ! grep -qE "^$DRIFT" <<<"$(ctx "$OUTA")"; then ok "teeth A: no --kit → this kit's drift is not reported, case 4 would go RED"; else no "teeth A: mutant still reports this kit's drift"; fi
  fi
  # B: the arguments dropped → --full ignored: case 5 sees the compact pointer.
  if mk_mut "teeth B: arguments dropped" "$SUT" "$TMP/mutB.sh" 's/ "\$@"$//'; then
    KB="$(mk_kit tmB "$TMP/mutB.sh")"; put_targets "$KB"
    OUTB="$(bash "$KB/toolbelt/verify-registry-hook.sh" --full 2>&1)"
    if grep -q 'Full detail: toolbelt' <<<"$(ctx "$OUTB")"; then ok "teeth B: arguments dropped → --full still compact, case 5 would go RED"; else no "teeth B: mutant honours --full"; fi
  fi
  # C: the wrong command → no envelope, a failing exit: cases 3-5 lose the header.
  if mk_mut "teeth C: wrong command" "$SUT" "$TMP/mutC.sh" 's/registry-hook/registryx-hook/'; then
    KC="$(mk_kit tmC "$TMP/mutC.sh")"; put_targets "$KC"
    OUTC="$(bash "$KC/toolbelt/verify-registry-hook.sh" 2>&1)"; RCC=$?
    if [ "$RCC" != 0 ] && ! grep -q 'registry check' <<<"$OUTC"; then ok "teeth C: wrong command → no envelope and a failing exit, case 4 would go RED"; else no "teeth C: mutant rc=$RCC out=[$OUTC]"; fi
  fi
  # D: the missing-lib guard stripped → empty stdout instead of the announcement: case 6.
  if mk_mut "teeth D: guard removed" "$SUT" "$TMP/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 0; }//'; then
    mkdir -p "$TMP/mD"; cp "$TMP/mutD.sh" "$TMP/mD/verify-registry-hook.sh"
    OUTD="$(bash "$TMP/mD/verify-registry-hook.sh" 2>/dev/null)"
    if [ -z "$OUTD" ]; then ok "teeth D: unguarded shim says nothing on a missing lib → case 6 would go RED"; else no "teeth D: mutant still announces [$OUTD]"; fi
  fi
  # E: the wrong hook mode (guard instead of sweep) → the degraded envelope of case 7 changes shape.
  if mk_mut "teeth E: wrong hook mode" "$SUT" "$TMP/mutE.sh" 's/rsdd_exec_hook sweep /rsdd_exec_hook guard /'; then
    KE="$(mk_kit tmE "$TMP/mutE.sh")"; put_targets "$KE"
    OUTE="$(RSDD_BIN="$TMP/does-not-exist" bash "$KE/toolbelt/verify-registry-hook.sh" 2>/dev/null)"
    if ! grep -q 'Research-SDD hooks DEGRADED' <<<"$OUTE"; then ok "teeth E: guard mode → no sweep DEGRADED envelope, case 7 would go RED"; else no "teeth E: mutant still prints the sweep envelope"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
