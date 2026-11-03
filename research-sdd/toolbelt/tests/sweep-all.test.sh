#!/usr/bin/env bash
# sweep-all.test.sh — harness for sweep-all.sh, now a shim to `rsdd sweep all` (kit issue #2664).
#
# Covers the SHIM contract and the two checks that read the kit rather than the Go code:
#   1  the shim exists and is executable
#   2  the binary gets `sweep all --kit <own kit>` and then the caller's arguments, byte for byte
#   3  output and exit code pass through unchanged
#   4  invoked through a symlink in another directory, the shim still names its REAL kit
#   5  the kit is the shim's, never the caller's cwd
#   6  an unusable RSDD_BIN → a typed degraded line, rc 2, nothing on stdout
#   7  the shim's own lib missing → a typed degraded line, rc 2
#   8  the real binary end to end on a mini kit of stub scripts: eight banners, the summary, exit 1 on a failure
#   9  the real binary end to end: a hanging stub is reported as timed out, the rest still run
#  10  parity: the Go list of scripts == the kit's registered SessionStart hook set == CANONICAL
#  11  every script the Go list names exists and is executable in the REAL toolbelt
# Everything the aggregator decides — the banners, the order, the independent runs, stderr merged into stdout, the
# timeout and its parsing, the missing-script and failure reports, the environment and RSDD_BIN of the children —
# is pinned in Go (research-sdd/rsdd/internal/sweep: a behaviour table, a golden recorded from the frozen script,
# unit tests of every boundary and a differential against the frozen script). The map from every old case to its
# Go test is L3 of odd/tasks/sweep-all-go.md.
#
# --prove-teeth mutates the SHIM (each mutant must lose its case) and the parity inputs; the Go source has its own
# mutation gate (`make teeth` in research-sdd/rsdd).
#
# Usage: sweep-all.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
SUT="$TOOLBELT/sweep-all.sh"
GOLIST="$TOOLBELT/../rsdd/internal/sweep/allscripts.go"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# the shim reads none of these; a stale value from the caller must not change a case
unset RSDD_SWEEP_TIMEOUT

# The Go binary the end-to-end cases run: the caller's RSDD_BIN, else one build into the temp dir.
REAL_BIN="${RSDD_BIN:-}"
if [ -z "$REAL_BIN" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  REAL_BIN="$TMP/rsdd"
fi

CANONICAL=(sweep-retros.sh sweep-audits.sh sweep-breakthroughs.sh verify-registry.sh verify-kit-clean.sh sweep-tools.sh verify-tool-catalog.sh verify-skill-drift.sh)

# stage_kit DEST [SHIM] — a mini kit: the shim (the real one, or a mutant) and lib/rsdd-exec.sh. The toolbelt is
# DEST/toolbelt. No bin/ and no Go sources: the binary can only come from RSDD_BIN.
stage_kit() {
  mkdir -p "$1/toolbelt/lib"
  cp "${2:-$SUT}" "$1/toolbelt/sweep-all.sh"; chmod +x "$1/toolbelt/sweep-all.sh"
  cp "$HERE/../lib/rsdd-exec.sh" "$1/toolbelt/lib/" || exit 2   # stage-libs-ok: the shim needs only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case 7
}
# stub_bin RC OUTPUT — a fake rsdd that records its arguments (one per line) in $TMP/args, prints OUTPUT, exits RC.
stub_bin() {
  printf '%s' "$2" > "$TMP/stub-out.txt"; : > "$TMP/args"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %s\n' "$TMP/args" "$TMP/stub-out.txt" "$1" > "$TMP/stub-rsdd"
  chmod +x "$TMP/stub-rsdd"
}

echo "== sweep-all.test.sh =="

# 1 — the shim exists and is executable.
[ -f "$SUT" ] && [ -x "$SUT" ] && ok "1 shim exists and is executable" || no "1 shim missing or not executable: $SUT"

stage_kit "$TMP/kit"; SHIM="$TMP/kit/toolbelt/sweep-all.sh"
PHYS="$(cd -P "$TMP/kit/toolbelt" && pwd -P)"

# 2 — the binary gets `sweep all --kit <own kit>` and then the caller's arguments, byte for byte.
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$SHIM" --json 'a b' '' '--x=*' >/dev/null 2>&1
want="$(printf '%s\n' sweep all --kit "$PHYS/.." --json 'a b' '' '--x=*')"
if [ "$(cat "$TMP/args")" = "$want" ]; then ok "2 binary called as 'sweep all --kit <own kit>' + the caller's arguments verbatim"
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
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/sweep-all.sh"
OUT="$(bash "$TMP/nolib/sweep-all.sh" 2>"$TMP/err7")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q "^degraded: rsdd-unavailable — rsdd-exec.sh missing beside $TMP/nolib/sweep-all.sh\$" "$TMP/err7"; then
  ok "7 missing rsdd-exec.sh → typed degraded line, rc 2"
else no "7 missing lib: rc=$RC out=[$OUT] err=[$(cat "$TMP/err7")]"; fi

# ---- the real binary, end to end on the mini kit of stub scripts ----
real() { env RSDD_BIN="$REAL_BIN" bash "$SHIM"; }
# stub_scripts RC_OF_AUDITS — the eight canonical names as stubs beside the shim; sweep-audits.sh exits RC_OF_AUDITS.
stub_scripts() {
  local s rc
  for s in "${CANONICAL[@]}"; do
    rc=0; [ "$s" = sweep-audits.sh ] && rc="$1"
    printf '#!/usr/bin/env bash\necho "stub:%s"\nexit %s\n' "$s" "$rc" > "$TMP/kit/toolbelt/$s"; chmod +x "$TMP/kit/toolbelt/$s"
  done
}

# 8 — one failing stub: all eight banners, the summary, the failing one named, exit 1, nothing on stderr.
stub_scripts 3
OUT="$(real 2>"$TMP/err8")"; RC=$?
nb="$(grep -c '^== ' <<<"$OUT")"
if [ "$RC" = 1 ] && [ "$nb" = 9 ] && grep -qx 'FAIL  sweep-audits.sh (exit 3)' <<<"$OUT" && grep -qx 'PASS  verify-skill-drift.sh' <<<"$OUT" \
   && grep -qx '== sweep-all summary' <<<"$OUT" && grep -qx '  FAIL  sweep-audits.sh (exit 3)' <<<"$OUT" && [ ! -s "$TMP/err8" ]; then
  ok "8 end to end: eight banners and the summary, the failing script named, exit 1"
else no "8 end to end: rc=$RC banners=$nb out=[$OUT] err=[$(cat "$TMP/err8")]"; fi

# 9 — a hanging stub is killed at RSDD_SWEEP_TIMEOUT and reported; the stubs after it still run. The timeout is
# short and the stub sleeps longer, so the run is bounded.
stub_scripts 0
printf '#!/usr/bin/env bash\necho "stub:hang"\nsleep 30\n' > "$TMP/kit/toolbelt/sweep-audits.sh"
OUT="$(env RSDD_SWEEP_TIMEOUT=1 RSDD_BIN="$REAL_BIN" bash "$SHIM" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -qx 'FAIL  sweep-audits.sh (timed out after 1s)' <<<"$OUT" && grep -qx 'PASS  verify-skill-drift.sh' <<<"$OUT"; then
  ok "9 end to end: a hanging stub is reported as timed out and the rest run"
else no "9 timeout: rc=$RC out=[$OUT]"; fi

# ---- the kit's own wiring: the Go list, the registered hooks, the real toolbelt ----
SETTINGS="$TOOLBELT/../../.claude/settings.json"
# listed_scripts <go-list-path> — the unique, sorted script names the Go list holds as quoted "<name>.sh".
# The single extraction for cases 10 and 11 and their teeth.
listed_scripts() {
  grep -oE '"[A-Za-z0-9_.-]+\.sh"' "$1" | tr -d '"' | sort -u
}
# parity_diff <go-list-path> — prints the divergence ("registered-only=[..] list-only=[..]"); empty output means
# the two sets are equal. rc 2 = could not extract a set (never a silent pass).
parity_diff() {
  local list="$1" reg mine only_reg only_list
  reg="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
for grp in d.get("hooks", {}).get("SessionStart", []):
    for h in grp.get("hooks", []):
        m = re.search(r"toolbelt/([A-Za-z0-9_.-]+)-hook\.sh", h.get("command", ""))
        if m:
            print(m.group(1) + ".sh")
PY
)"
  reg="$(printf '%s\n' "$reg" | sort -u)"
  mine="$(listed_scripts "$list")"
  if [ -z "$reg" ] || [ -z "$mine" ]; then
    echo "could not extract a set (registered=[${reg//$'\n'/ }] list=[${mine//$'\n'/ }])"; return 2
  fi
  only_reg="$(comm -23 <(printf '%s\n' "$reg") <(printf '%s\n' "$mine") | tr '\n' ' ')"
  only_list="$(comm -13 <(printf '%s\n' "$reg") <(printf '%s\n' "$mine") | tr '\n' ' ')"
  [ -z "$only_reg" ] && [ -z "$only_list" ] || echo "registered-only=[$only_reg] list-only=[$only_list]"
}

# 10 — the Go list == the registered SessionStart hook set == CANONICAL (the manual stand-in for the Claude hooks
# must run exactly what Claude runs: a hook added without a list entry, or the reverse, is how one went unwired).
if [ ! -f "$SETTINGS" ]; then
  no "10 parity: $SETTINGS not found (cannot prove the SessionStart set)"
elif [ ! -f "$GOLIST" ]; then
  no "10 parity: $GOLIST not found (cannot read the Go list)"
else
  diff10="$(parity_diff "$GOLIST")"; rc10=$?
  canon="$(printf '%s\n' "${CANONICAL[@]}" | sort -u)"
  mine10="$(listed_scripts "$GOLIST")"
  [ "$rc10" -eq 0 ] && [ -z "$diff10" ] && [ "$canon" = "$mine10" ] \
    && ok "10 parity: Go script list == registered SessionStart hook set == test CANONICAL" \
    || no "10 parity: $diff10 (rc=$rc10, canonical-equals-list=$([ "$canon" = "$mine10" ] && echo y || echo n))"
fi

# 11 — every listed script exists AND is executable in the REAL toolbelt. The Go tests stub every script, so nothing
# else proves the real list resolves or that no script lost its mode; the aggregator runs a script with bash, so a
# lost execute bit would not fail a sweep, only every other caller of that script.
missing_real() {
  local f
  while IFS= read -r f; do
    [ -f "$TOOLBELT/$f" ] && [ -x "$TOOLBELT/$f" ] || printf '%s ' "$f"
  done < <(listed_scripts "$1")
}
listed11="$(listed_scripts "$GOLIST" | grep -c '^')"
miss11="$(missing_real "$GOLIST")"
[ "$listed11" -gt 0 ] && [ -z "$miss11" ] \
  && ok "11 real-scripts: all $listed11 listed scripts exist and are executable in the real toolbelt" \
  || no "11 real-scripts: listed=$listed11 missing-or-not-executable=[$miss11]"

# NEGATIVE CONTROL — each shim mutation and each parity input mutation must lose its case.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each mutation must lose its case --"

  # A: the own kit is no longer handed over → case 2 (and the real binary would resolve some other kit).
  if mk_mut "teeth A: --kit dropped" "$SUT" "$TMP/mutA.sh" 's/ --kit "\$_RSDD_SELF\/\.\."//'; then
    stage_kit "$TMP/mA" "$TMP/mutA.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mA/toolbelt/sweep-all.sh" --json >/dev/null 2>&1
    if [ "$(sed -n 3p "$TMP/args")" != "--kit" ]; then ok "teeth A: --kit dropped → case 2 would go RED"; else no "teeth A: mutant still passes --kit"; fi
  fi
  # B: the caller's arguments are dropped → case 2.
  if mk_mut "teeth B: arguments dropped" "$SUT" "$TMP/mutB.sh" 's/"\$@"$//'; then
    stage_kit "$TMP/mB" "$TMP/mutB.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mB/toolbelt/sweep-all.sh" --json >/dev/null 2>&1
    if ! grep -qx -- '--json' "$TMP/args"; then ok "teeth B: arguments dropped → case 2 would go RED"; else no "teeth B: mutant still passes the arguments"; fi
  fi
  # C: the shim runs another command → case 2 sees the wrong command.
  if mk_mut "teeth C: wrong command" "$SUT" "$TMP/mutC.sh" 's/rsdd_exec sweep all --kit/rsdd_exec sweep tools --kit/'; then
    stage_kit "$TMP/mC" "$TMP/mutC.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mC/toolbelt/sweep-all.sh" >/dev/null 2>&1
    if [ "$(sed -n 2p "$TMP/args")" != "all" ]; then ok "teeth C: wrong command → case 2 would go RED"; else no "teeth C: mutant still runs 'sweep all'"; fi
  fi
  # D: the missing-lib guard stripped → no typed degraded line → case 7.
  if mk_mut "teeth D: guard removed" "$SUT" "$TMP/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$TMP/mD"; cp "$TMP/mutD.sh" "$TMP/mD/sweep-all.sh"
    bash "$TMP/mD/sweep-all.sh" >/dev/null 2>"$TMP/errD"
    if ! grep -q 'rsdd-exec.sh missing beside' "$TMP/errD"; then ok "teeth D: unguarded shim no longer announces a missing lib → case 7 would go RED"; else no "teeth D: mutant still announces"; fi
  fi
  # Parity teeth: dropping one script (the original gap) and adding an unregistered one must each diverge.
  if MUTANT_SYNTAX=none mutant_chain "teeth: parity drop-script mutant build" "$GOLIST" "$TMP/mutant-drop.go" '/"verify-skill-drift\.sh",/d'; then
    d="$(parity_diff "$TMP/mutant-drop.go")"
    [ -n "$d" ] && ok "teeth: dropped script is reported by parity ($d)" || no "teeth: parity did not notice a dropped script — THEATER"
  else no "teeth: could not build parity drop mutant"; fi
  if MUTANT_SYNTAX=none mutant_chain "teeth: parity extra-script mutant build" "$GOLIST" "$TMP/mutant-extra.go" '/"verify-skill-drift\.sh",/a\	"not-a-hook.sh",'; then
    d="$(parity_diff "$TMP/mutant-extra.go")"
    [ -n "$d" ] && ok "teeth: extra script is reported by parity ($d)" || no "teeth: parity did not notice an extra script — THEATER"
  else no "teeth: could not build parity extra mutant"; fi
  if MUTANT_SYNTAX=none mutant_chain "teeth: missing-script mutant build" "$GOLIST" "$TMP/mutant-missing.go" '/"verify-skill-drift\.sh",/a\	"does-not-exist.sh",'; then
    d="$(missing_real "$TMP/mutant-missing.go")"
    [ -n "$d" ] && ok "teeth: nonexistent listed script is reported by the real-script check ($d)" || no "teeth: real-script check did not notice a missing script — THEATER"
  else no "teeth: could not build missing-script mutant"; fi
  # A listed script that lost its execute bit must be reported too (a copy of the toolbelt with one mode dropped).
  mkdir -p "$TMP/modetb"; cp "$TOOLBELT/sweep-retros.sh" "$TMP/modetb/"; chmod -x "$TMP/modetb/sweep-retros.sh"
  printf '\t"sweep-retros.sh",\n' > "$TMP/modelist.go"
  d="$(TOOLBELT="$TMP/modetb" missing_real "$TMP/modelist.go")"
  [ -n "$d" ] && ok "teeth: a listed script without its execute bit is reported ($d)" || no "teeth: real-script check did not notice a lost execute bit — THEATER"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
