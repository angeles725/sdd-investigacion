#!/usr/bin/env bash
# verify-kit-clean-hook.test.sh — harness for verify-kit-clean-hook.sh, now a shim to
# `rsdd verify kit-clean-hook` (kit issue #2354).
# Covers: existence, executable; the shim contract against a STUB rsdd (arguments handed over, output and
# exit code passed through, symlinked invocation, rsdd unavailable → a DEGRADED envelope, rc 0); the real Go
# binary end to end (clean kit → silent, dirty kit → banner, not a repo → "could not run" banner); and mutation
# proof on the shim. The envelope bytes and the banner text are pinned against the old bash hook and against
# jq by the Go differential tests (internal/verify, `make test`).
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox toolbelt
SUT="$HERE/../verify-kit-clean-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-kit-clean-hook.test.sh =="

# 1. Existence
[ -f "$SUT" ] \
  && ok "1 hook exists at $SUT" \
  || no "1 hook NOT found at $SUT"

# 2. Executable
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 hook is executable" \
  || no "2 hook NOT executable (missing +x bit)"

if [ ! -f "$SUT" ]; then
  for n in 3 4 5 6 7 8 9; do no "$n (skipped: hook missing)"; done
  echo "== $pass passed · $fail failed =="; exit 2
fi

# ---- Temp workspace ---------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The real binary for the end-to-end cases: the caller's RSDD_BIN, else one build into the temp dir.
REAL_BIN="${RSDD_BIN:-}"
if [ -z "$REAL_BIN" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  REAL_BIN="$TMP/rsdd"
fi

# stage_hook DEST [SHIM] — a sandbox toolbelt holding the hook shim (the real one, or a mutant) and every lib.
stage_hook() { mkdir -p "$1"; cp "${2:-$SUT}" "$1/verify-kit-clean-hook.sh"; chmod +x "$1/verify-kit-clean-hook.sh"; rsdd_stage_libs "$1" || exit 2; }

# stub_bin RC OUTPUT — a fake rsdd that records its arguments (one per line) in $TMP/args, prints OUTPUT, exits RC.
stub_bin() {
  printf '%s' "$2" > "$TMP/stub-out.txt"; : > "$TMP/args"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %s\n' "$TMP/args" "$TMP/stub-out.txt" "$1" > "$TMP/stub-rsdd"
  chmod +x "$TMP/stub-rsdd"
}

stage_hook "$TMP/tb"; HOOK="$TMP/tb/verify-kit-clean-hook.sh"
PHYS="$(cd -P "$TMP/tb" && pwd -P)"

# 3. Clean kit (the binary is silent, rc 0) → hook exits 0 and emits nothing; the binary got the group, the
#    command and the hook's own directory.
stub_bin 0 ""
OUT="$(RSDD_BIN="$TMP/stub-rsdd" bash "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(tr '\n' ' ' < "$TMP/args")" = "verify kit-clean-hook $PHYS " ]; then
  ok "3 clean kit → hook silent (exit 0), binary called as 'verify kit-clean-hook <own dir>'"
else no "3 clean kit → rc=$RC out=[$OUT] args=[$(tr '\n' ' ' < "$TMP/args")]"; fi

# 4. The binary's output and exit code pass through unchanged (the envelope is the binary's work).
ENV='{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"NOT clean"}}
'
stub_bin 0 "$ENV"
OUT="$(RSDD_BIN="$TMP/stub-rsdd" bash "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "${ENV%$'\n'}" ]; then ok "4 binary output passes through, exit 0"; else no "4 passthrough differs (rc=$RC out=[$OUT])"; fi

# 5. Invoked through a symlink in another directory, the hook still names its REAL directory.
mkdir -p "$TMP/elsewhere"; ln -s "$HOOK" "$TMP/elsewhere/link-hook.sh"
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/elsewhere/link-hook.sh" >/dev/null 2>&1
if [ "$(tail -n 1 "$TMP/args")" = "$PHYS" ]; then ok "5 symlinked hook → binary gets the physical own directory"; else no "5 symlink: args=[$(tr '\n' ' ' < "$TMP/args")] want ...$PHYS"; fi

# 6. rsdd unavailable → exit 0 and a DEGRADED SessionStart envelope (never empty stdout), stderr names the cause.
OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$HOOK" 2>"$TMP/err6")"; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'Research-SDD hooks DEGRADED: rsdd-unavailable — RSDD_BIN not executable' <<<"$OUT" \
   && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/err6"; then
  ok "6 rsdd unavailable → rc 0, DEGRADED envelope on stdout, degraded line on stderr"
else no "6 unavailable: rc=$RC out=[$OUT] err=[$(cat "$TMP/err6")]"; fi

# ---- end to end against the real binary ----
mkrepo() {
  local d="$1" origin="$1.origin.git"
  git init -q -b main "$d" 2>/dev/null || { git init -q "$d"; git -C "$d" symbolic-ref HEAD refs/heads/main; }
  echo x > "$d/f.txt"; git -C "$d" add -A; git -C "$d" commit -q -m init
  git init -q --bare "$origin"; git -C "$d" remote add origin "$origin"
  git -C "$d" push -q -u origin main 2>/dev/null
}
# e2e_repo NAME — a pushed repo that holds the hook (so the shim's own directory IS the kit under test).
e2e_repo() { mkrepo "$TMP/$1"; stage_hook "$TMP/$1"; git -C "$TMP/$1" add -A; git -C "$TMP/$1" commit -q -m shim; git -C "$TMP/$1" push -q origin main 2>/dev/null; }

# 7. Clean kit, real binary → silent.
e2e_repo e2e-clean
OUT="$(RSDD_BIN="$REAL_BIN" bash "$TMP/e2e-clean/verify-kit-clean-hook.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "7 real binary, clean kit → silent, exit 0"; else no "7 clean kit not silent (rc=$RC out=[$OUT])"; fi

# 8. Dirty kit, real binary → a valid SessionStart envelope whose context carries the banner and the report.
e2e_repo e2e-dirty; echo n > "$TMP/e2e-dirty/new.txt"
OUT="$(RSDD_BIN="$REAL_BIN" bash "$TMP/e2e-dirty/verify-kit-clean-hook.sh" 2>&1)"; RC=$?
CTX="$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT" 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$OUT" 2>/dev/null)" = SessionStart ] \
   && [[ "$CTX" == "Research-SDD KIT is NOT clean"* ]] && grep -q 'working tree : DIRTY — uncommitted: 0 staged · 0 unstaged · 1 untracked' <<<"$CTX"; then
  ok "8 real binary, dirty kit → SessionStart envelope with the NOT clean banner and the report"
else no "8 dirty kit: rc=$RC out=[$OUT]"; fi

# 9. Not a repo, real binary → the error banner (exit 2 of the check), still exit 0 for the hook.
stage_hook "$TMP/e2e-plain"
OUT="$(RSDD_BIN="$REAL_BIN" bash "$TMP/e2e-plain/verify-kit-clean-hook.sh" 2>&1)"; RC=$?
CTX="$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT" 2>/dev/null)"
if [ "$RC" -eq 0 ] && [[ "$CTX" == "Research-SDD kit-clean check could not run (exit 2 — misconfigured path or not a git repo):"* ]]; then
  ok "9 real binary, not a repo → 'could not run (exit 2)' banner, hook exit 0"
else no "9 not a repo: rc=$RC out=[$OUT]"; fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutants are built by lib/mutant.sh (kit #1299), sourced ONLY on this path. It refuses an empty,
  # byte-identical, syntax-broken or live-tree mutant; mutant_chain also refuses a sed stage that matches
  # nothing. A refused build is counted exactly once (mk_mut) and its tooth is skipped.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"

  # A: the own-directory argument dropped → case 3 sees no directory (and the real binary would check the cwd).
  if mk_mut "teeth A: own dir dropped" "$SUT" "$TMP/mutA.sh" 's/ "\$_RSDD_SELF"$//'; then
    stage_hook "$TMP/mA" "$TMP/mutA.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mA/verify-kit-clean-hook.sh" >/dev/null 2>&1
    if [ "$(tr '\n' ' ' < "$TMP/args")" = "verify kit-clean-hook " ]; then ok "teeth A: own dir dropped → case 3 would go RED"; else no "teeth A: mutant still passes the own dir (args=[$(tr '\n' ' ' < "$TMP/args")])"; fi
  fi
  # B: sweep mode changed to gate → the degraded envelope vanishes (stdout empty) → case 6.
  if mk_mut "teeth B: sweep → gate" "$SUT" "$TMP/mutB.sh" 's/rsdd_exec_hook sweep /rsdd_exec_hook gate /'; then
    stage_hook "$TMP/mB" "$TMP/mutB.sh"
    OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$TMP/mB/verify-kit-clean-hook.sh" 2>/dev/null)"
    if [ -z "$OUT" ]; then ok "teeth B: gate degraded mode → empty stdout, case 6 would go RED"; else no "teeth B: mutant still emits [$OUT]"; fi
  fi
  # C: wrong command (the check instead of the hook) → real run prints the plain report, not an envelope → case 8.
  if mk_mut "teeth C: wrong command" "$SUT" "$TMP/mutC.sh" 's/verify kit-clean-hook /verify kit-clean /'; then
    e2e_repo e2e-mutc; echo n > "$TMP/e2e-mutc/new.txt"; cp "$TMP/mutC.sh" "$TMP/e2e-mutc/verify-kit-clean-hook.sh"
    OUT="$(RSDD_BIN="$REAL_BIN" bash "$TMP/e2e-mutc/verify-kit-clean-hook.sh" 2>&1)"
    if ! jq -e . >/dev/null 2>&1 <<<"$OUT"; then ok "teeth C: wrong command → plain report, no envelope → case 8 would go RED"; else no "teeth C: mutant still emits an envelope"; fi
  fi
  # D: the missing-lib guard stripped → no announcement → hook-emit.test.sh case 10 (checked here directly).
  if mk_mut "teeth D: guard removed" "$SUT" "$TMP/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 0; }//'; then
    mkdir -p "$TMP/mD"; cp "$TMP/mutD.sh" "$TMP/mD/verify-kit-clean-hook.sh"
    OUT="$(bash "$TMP/mD/verify-kit-clean-hook.sh" 2>/dev/null)"
    if [ -z "$OUT" ]; then ok "teeth D: unguarded hook is silent when the lib is missing → the guard has teeth"; else no "teeth D: mutant still announces [$OUT]"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
