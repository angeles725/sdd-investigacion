#!/usr/bin/env bash
# verify-skill-drift.test.sh — harness for verify-skill-drift.sh, now a shim to `rsdd verify skill-drift`
# (kit issue #2365).
#
# Covers the SHIM contract: existence and the executable bit; the arguments handed to the binary (`--kit` with
# the shim's own kit, then every caller argument byte for byte, an empty one included); output and exit code
# passed through; a symlinked invocation; a missing lib or an unusable binary → a typed degraded line, never a
# silent pass; and the real Go binary end to end on a mini kit (in sync, diverged, absent, --all, --help).
# Everything the script decided — exit codes, every message, profiles, the pi override, the adapter table — is
# pinned in Go (internal/verify, skilldrift*_test.go: behaviour tests plus a differential against the frozen
# script), not here.
# --prove-teeth mutates the SHIM (each mutant must lose its case); the Go source has its own mutation gate
# (`make teeth` in research-sdd/rsdd).
#
# Usage: verify-skill-drift.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-skill-drift.sh"
ADAPTERS="$HERE/../../install/adapters.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$ADAPTERS" ] || { echo "FATAL: adapters.sh not found: $ADAPTERS" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# the shim reads none of these; a stale value from the caller must not change a case
unset RESEARCH_SDD_PROFILE GENTLE_PI_AGENT_HOME PI_CODING_AGENT_DIR

# The Go binary the end-to-end cases run: the caller's RSDD_BIN, else one build into the temp dir.
REAL_BIN="${RSDD_BIN:-}"
if [ -z "$REAL_BIN" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  REAL_BIN="$TMP/rsdd"
fi

# stage_kit DEST [SHIM] — a mini kit: the shim (the real one, or a mutant), lib/rsdd-exec.sh, the real adapters.sh and
# a kit SKILL.md. The toolbelt is DEST/toolbelt.
stage_kit() {
  mkdir -p "$1/toolbelt/lib" "$1/install" "$1/skills/research-sdd"
  cp "${2:-$SUT}" "$1/toolbelt/verify-skill-drift.sh"; chmod +x "$1/toolbelt/verify-skill-drift.sh"
  cp "$HERE/../lib/rsdd-exec.sh" "$1/toolbelt/lib/" || exit 2   # stage-libs-ok: the shim needs only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case 7
  cp "$ADAPTERS" "$1/install/adapters.sh"
  printf 'kit skill\n' > "$1/skills/research-sdd/SKILL.md"
}
# stub_bin RC OUTPUT — a fake rsdd that records its arguments (one per line) in $TMP/args, prints OUTPUT, exits RC.
stub_bin() {
  printf '%s' "$2" > "$TMP/stub-out.txt"; : > "$TMP/args"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %s\n' "$TMP/args" "$TMP/stub-out.txt" "$1" > "$TMP/stub-rsdd"
  chmod +x "$TMP/stub-rsdd"
}

echo "== verify-skill-drift.test.sh =="

# 1 — the shim exists and is executable.
[ -f "$SUT" ] && [ -x "$SUT" ] && ok "1 shim exists and is executable" || no "1 shim missing or not executable: $SUT"

stage_kit "$TMP/kit"; SHIM="$TMP/kit/toolbelt/verify-skill-drift.sh"
PHYS="$(cd -P "$TMP/kit/toolbelt" && pwd -P)"

# 2 — the binary gets `verify skill-drift --kit <own kit>` and then the caller's arguments, byte for byte.
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" --all --home "$TMP/h o m e" '' '--x=*' >/dev/null 2>&1
want="$(printf '%s\n' verify skill-drift --kit "$PHYS/.." --all --home "$TMP/h o m e" '' '--x=*')"
if [ "$(cat "$TMP/args")" = "$want" ]; then ok "2 binary called as 'verify skill-drift --kit <own kit>' + the caller's arguments verbatim"
else no "2 arguments differ: [$(tr '\n' '|' < "$TMP/args")]"; fi

# 3 — output and exit code pass through unchanged (stdout and the code are the binary's work).
stub_bin 3 "from the binary
"
OUT="$(RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" 2>&1)"; RC=$?
if [ "$RC" = 3 ] && [ "$OUT" = "from the binary" ]; then ok "3 output and exit code pass through"; else no "3 passthrough differs (rc=$RC out=[$OUT])"; fi

# 4 — invoked through a symlink in another directory, the shim still names its REAL kit.
mkdir -p "$TMP/elsewhere"; ln -s "$SHIM" "$TMP/elsewhere/link.sh"
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/elsewhere/link.sh" >/dev/null 2>&1
if [ "$(sed -n 4p "$TMP/args")" = "$PHYS/.." ]; then ok "4 symlinked shim → binary gets the physical own kit"; else no "4 symlink: args=[$(tr '\n' '|' < "$TMP/args")]"; fi

# 5 — the kit is the shim's, never the caller's cwd.
( cd "$TMP/elsewhere" && RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" >/dev/null 2>&1 )
if [ "$(sed -n 4p "$TMP/args")" = "$PHYS/.." ]; then ok "5 the kit does not depend on the cwd"; else no "5 cwd leaked into the kit: [$(sed -n 4p "$TMP/args")]"; fi

# 6 — an unusable RSDD_BIN → a typed degraded line on stderr, rc 2, nothing on stdout (the check could not run).
OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$SHIM" --all 2>"$TMP/err6")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/err6"; then
  ok "6 unusable RSDD_BIN → typed degraded line, rc 2"
else no "6 unusable binary: rc=$RC out=[$OUT] err=[$(cat "$TMP/err6")]"; fi

# 7 — the shim's own lib missing → a typed degraded line, rc 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/verify-skill-drift.sh"
OUT="$(bash "$TMP/nolib/verify-skill-drift.sh" 2>"$TMP/err7")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q "^degraded: rsdd-unavailable — rsdd-exec.sh missing beside $TMP/nolib/verify-skill-drift.sh\$" "$TMP/err7"; then
  ok "7 missing rsdd-exec.sh → typed degraded line, rc 2"
else no "7 missing lib: rc=$RC out=[$OUT] err=[$(cat "$TMP/err7")]"; fi

# ---- the real binary, end to end on the mini kit ----
HOMEDIR="$TMP/home"; DEP="$HOMEDIR/.claude/skills/research-sdd/SKILL.md"
real() { env -u RESEARCH_SDD_PROFILE -u GENTLE_PI_AGENT_HOME -u PI_CODING_AGENT_DIR RSDD_BIN="$REAL_BIN" bash "$SHIM" --home "$HOMEDIR" "$@"; }
mkdir -p "$(dirname "$DEP")"

# 8 — deployed == kit source → silent, exit 0.
cp "$TMP/kit/skills/research-sdd/SKILL.md" "$DEP"
OUT="$(real 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "8 in sync → silent, exit 0"; else no "8 in sync: rc=$RC out=[$OUT]"; fi

# 9 — a hand-edited deployed skill → exit 1 and the diverged line.
echo "edited" > "$DEP"
OUT="$(real 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "verify-skill-drift: diverged harness=claude deployed=$DEP" ]; then ok "9 diverged → exit 1 and the typed line"; else no "9 diverged: rc=$RC out=[$OUT]"; fi

# 10 — no deployed skill → exit 3 (absent), distinct from in sync.
rm -f "$DEP"
OUT="$(real 2>&1)"; RC=$?
if [ "$RC" = 3 ] && grep -q "^verify-skill-drift: absent harness=claude deployed=$DEP\$" <<<"$OUT"; then ok "10 absent → exit 3, never confused with in sync"; else no "10 absent: rc=$RC out=[$OUT]"; fi

# 11 — --all: one diverged harness among absent ones → exit 1, the fix line and the summary on stderr, stdout empty.
echo "edited" > "$DEP"
OUT="$(real --all 2>"$TMP/err11")"; RC=$?
if [ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q '^verify-skill-drift: fix: research-sdd-install.sh --harness claude --force-skill' "$TMP/err11" \
   && grep -q '^verify-skill-drift: all: checked=3 in-sync=0 diverged=1 absent=2 could-not-run=0$' "$TMP/err11"; then
  ok "11 --all → exit 1 with the fix line and the summary"
else no "11 --all: rc=$RC out=[$OUT] err=[$(cat "$TMP/err11")]"; fi

# 12 — --help is the script header (the shim has none of its own) and exits 0 without HOME.
OUT="$(env -u HOME RSDD_BIN="$REAL_BIN" bash "$SHIM" --help 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q '^Usage: verify-skill-drift.sh \[--all | --harness <h>\] \[--home <dir>\] \[--profile <name>\]$' <<<"$OUT"; then
  ok "12 --help prints the usage, exit 0, no HOME needed"
else no "12 --help: rc=$RC out=[$OUT]"; fi

# 13 — an unknown argument is exit 2 (the internal --kit/--hook modes are not reachable from a caller).
OUT="$(real --kit "$TMP" 2>&1)"; RC=$?
if [ "$RC" = 2 ] && grep -q '^verify-skill-drift: unknown argument: --kit$' <<<"$OUT"; then ok "13 a caller's --kit is an unknown argument"; else no "13 --kit: rc=$RC out=[$OUT]"; fi

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
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mA/toolbelt/verify-skill-drift.sh" --all >/dev/null 2>&1
    if [ "$(sed -n 3p "$TMP/args")" != "--kit" ]; then ok "teeth A: --kit dropped → case 2 would go RED"; else no "teeth A: mutant still passes --kit"; fi
  fi
  # B: the caller's arguments are dropped → case 2 and 11.
  if mk_mut "teeth B: arguments dropped" "$SUT" "$TMP/mutB.sh" 's/"\$@"$//'; then
    stage_kit "$TMP/mB" "$TMP/mutB.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mB/toolbelt/verify-skill-drift.sh" --all >/dev/null 2>&1
    if ! grep -qx -- '--all' "$TMP/args"; then ok "teeth B: arguments dropped → case 2 would go RED"; else no "teeth B: mutant still passes the arguments"; fi
  fi
  # C: the shim runs the hook command instead of the check → case 2 sees the wrong command.
  if mk_mut "teeth C: wrong command" "$SUT" "$TMP/mutC.sh" 's/verify skill-drift --kit/verify kit-clean --kit/'; then
    stage_kit "$TMP/mC" "$TMP/mutC.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mC/toolbelt/verify-skill-drift.sh" >/dev/null 2>&1
    if [ "$(sed -n 2p "$TMP/args")" != "skill-drift" ]; then ok "teeth C: wrong command → case 2 would go RED"; else no "teeth C: mutant still calls skill-drift"; fi
  fi
  # D: the missing-lib guard stripped → no typed degraded line → case 7.
  if mk_mut "teeth D: guard removed" "$SUT" "$TMP/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$TMP/mD"; cp "$TMP/mutD.sh" "$TMP/mD/verify-skill-drift.sh"
    bash "$TMP/mD/verify-skill-drift.sh" >/dev/null 2>"$TMP/errD"
    if ! grep -q 'rsdd-exec.sh missing beside' "$TMP/errD"; then ok "teeth D: unguarded shim no longer announces a missing lib → case 7 would go RED"; else no "teeth D: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
