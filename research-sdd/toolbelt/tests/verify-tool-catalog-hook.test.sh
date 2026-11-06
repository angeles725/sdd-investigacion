#!/usr/bin/env bash
# verify-tool-catalog-hook.test.sh — harness for verify-tool-catalog-hook.sh, now a shim to
# `rsdd verify tool-catalog-hook` (kit issue #2749).
# Covers: existence, executable; the shim contract against a STUB rsdd (arguments handed over, --full forwarded,
# output and exit code passed through, symlinked invocation, rsdd unavailable → a DEGRADED envelope, rc 0); the real
# Go binary end to end (clean sentinel, empty-input silent, drift compact and --full, could-not-run); and mutation
# proof on the shim. The envelope bytes, the compact form, the 160-byte cut and the capped could-not-run contexts
# are pinned against the old bash hook and against jq by the Go differential and golden tests
# (internal/verify/toolcatalog, `make test`); the teeth that targeted that bash moved there (`make teeth`).
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox toolbelt
SUT="$HERE/../verify-tool-catalog-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-tool-catalog-hook.test.sh =="

# 1. Existence
[ -f "$SUT" ] \
  && ok "1 hook exists at $SUT" \
  || no "1 hook NOT found at $SUT"

# 2. Executable
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 hook is executable" \
  || no "2 hook NOT executable (missing +x bit)"

if [ ! -f "$SUT" ]; then
  for n in 3 4 5 6 7 8 9 10 11; do no "$n (skipped: hook missing)"; done
  echo "== $pass passed · $fail failed =="; exit 2
fi

# ---- Temp workspace ---------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The real binary for the end-to-end cases: the caller's RSDD_BIN, else one build into the temp dir.
REAL_BIN="${RSDD_BIN:-}"
if [ -z "$REAL_BIN" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  REAL_BIN="$TMP/rsdd"
fi

# stage_hook DEST [SHIM] — a sandbox toolbelt holding the hook shim (the real one, or a mutant) and every lib.
stage_hook() { mkdir -p "$1"; cp "${2:-$SUT}" "$1/verify-tool-catalog-hook.sh"; chmod +x "$1/verify-tool-catalog-hook.sh"; rsdd_stage_libs "$1" || exit 2; }

# stub_bin RC OUTPUT — a fake rsdd that records its arguments (one per line) in $TMP/args, prints OUTPUT, exits RC.
stub_bin() {
  printf '%s' "$2" > "$TMP/stub-out.txt"; : > "$TMP/args"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %s\n' "$TMP/args" "$TMP/stub-out.txt" "$1" > "$TMP/stub-rsdd"
  chmod +x "$TMP/stub-rsdd"
}

stage_hook "$TMP/tb"; HOOK="$TMP/tb/verify-tool-catalog-hook.sh"
PHYS="$(cd -P "$TMP/tb" && pwd -P)"

# 3. The binary gets the group, the command and the hook's own directory; its output and exit code pass through.
ENV='{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"drift"}}
'
stub_bin 0 "$ENV"
OUT="$(RSDD_BIN="$TMP/stub-rsdd" bash "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "${ENV%$'\n'}" ] && [ "$(tr '\n' ' ' < "$TMP/args")" = "verify tool-catalog-hook $PHYS " ]; then
  ok "3 binary called as 'verify tool-catalog-hook <own dir>', output passes through, exit 0"
else no "3 shim contract: rc=$RC out=[$OUT] args=[$(tr '\n' ' ' < "$TMP/args")]"; fi

# 4. --full reaches the binary (after the own directory); any other first argument is passed along, never dropped.
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$HOOK" --full >/dev/null 2>&1
if [ "$(tr '\n' ' ' < "$TMP/args")" = "verify tool-catalog-hook $PHYS --full " ]; then ok "4 --full forwarded after the own directory"; else no "4 --full: args=[$(tr '\n' ' ' < "$TMP/args")]"; fi

# 5. Invoked through a symlink in another directory, the hook still names its REAL directory.
mkdir -p "$TMP/elsewhere"; ln -s "$HOOK" "$TMP/elsewhere/link-hook.sh"
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/elsewhere/link-hook.sh" >/dev/null 2>&1
if [ "$(sed -n 3p "$TMP/args")" = "$PHYS" ]; then ok "5 symlinked hook → binary gets the physical own directory"; else no "5 symlink: args=[$(tr '\n' ' ' < "$TMP/args")] want ...$PHYS"; fi

# 6. rsdd unavailable → exit 0 and a DEGRADED SessionStart envelope (never empty stdout), stderr names the cause.
OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$HOOK" 2>"$TMP/err6")"; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'Research-SDD hooks DEGRADED: rsdd-unavailable — RSDD_BIN not executable' <<<"$OUT" \
   && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/err6"; then
  ok "6 rsdd unavailable → rc 0, DEGRADED envelope on stdout, degraded line on stderr"
else no "6 unavailable: rc=$RC out=[$OUT] err=[$(cat "$TMP/err6")]"; fi

# ---- end to end against the real binary ----
# e2e_kit NAME "<logged tools>" "<cataloged tools>" — a toolbelt holding the hook shim and the two inputs (a tool
# per word; `-` for none).
e2e_kit() {
  local t
  stage_hook "$TMP/$1"
  { printf '| Tool | How | Status | Target | Date | Notes |\n|---|---|---|---|---|---|\n'
    for t in $2; do [ "$t" = - ] || printf '| %s | `brew` | installed | kit | 2026-01-01T00:00:00Z | n/a |\n' "$t"; done; } > "$TMP/$1/INSTALLED-TOOLS.md"
  { printf '| Artifact type | Tool |\n|---|---|\n'
    for t in $3; do [ "$t" = - ] || printf '| A | %s |\n' "$t"; done; } > "$TMP/$1/tool-registry.md"
}
ctx_of() { jq -r '.hookSpecificOutput.additionalContext' <<<"$1" 2>/dev/null; }
run_e2e() { RSDD_BIN="$REAL_BIN" bash "$TMP/$1/verify-tool-catalog-hook.sh" "${@:2}" 2>&1; }

# 7. Every logged tool cataloged → the declared-clean sentinel (a silent clean run is the defect, #380 precedent).
e2e_kit e2e-clean "alpha beta" "alpha beta"
OUT="$(run_e2e e2e-clean)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(ctx_of "$OUT")" = "Research-SDD tool catalog: clean (2 logged tools, 0 uncataloged)." ]; then
  ok "7 real binary, all cataloged → clean sentinel in a SessionStart envelope"
else no "7 clean: rc=$RC out=[$OUT]"; fi

# 8. A log with no tool → silent (the legitimate empty-input state), exit 0.
e2e_kit e2e-empty - -
OUT="$(run_e2e e2e-empty)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "8 real binary, empty log → silent, exit 0"; else no "8 empty-input not silent: rc=$RC out=[$OUT]"; fi

# 9. Drift → the compact report: ONE line naming every uncataloged tool, the Summary, the pointer to the full list.
e2e_kit e2e-drift "typst bkcrack ok" "ok"
OUT="$(run_e2e e2e-drift)"; RC=$?; CTX="$(ctx_of "$OUT")"
if [ "$RC" -eq 0 ] && [[ "$CTX" == "Research-SDD tool catalog drift (installed but not cataloged):"$'\n'"WARN  installed-but-not-cataloged (2): typst, bkcrack — add a tool-registry.md row each (propose-never-apply)."$'\n'"Summary: 3 distinct tool(s) logged in INSTALLED-TOOLS.md · 1 cataloged · 2 not cataloged."$'\n'"Run toolbelt/verify-tool-catalog.sh for the full list." ]]; then
  ok "9 real binary, drift → compact report naming every uncataloged tool"
else no "9 drift: rc=$RC ctx=[$CTX]"; fi

# 10. --full keeps one WARN line per tool.
OUT="$(run_e2e e2e-drift --full)"; RC=$?; CTX="$(ctx_of "$OUT")"
if [ "$RC" -eq 0 ] && [ "$(grep -c "^WARN  installed-but-not-cataloged: '" <<<"$CTX")" = 2 ] && grep -q "'typst'" <<<"$CTX" && grep -q "'bkcrack'" <<<"$CTX"; then
  ok "10 real binary, drift --full → one WARN line per tool"
else no "10 drift --full: rc=$RC ctx=[$CTX]"; fi

# 11. A missing input → the could-not-run banner naming the exit code, never silence; the hook still exits 0.
stage_hook "$TMP/e2e-absent"; printf '| Artifact type | Tool |\n' > "$TMP/e2e-absent/tool-registry.md"
OUT="$(run_e2e e2e-absent)"; RC=$?; CTX="$(ctx_of "$OUT")"
if [ "$RC" -eq 0 ] && [[ "$CTX" == "Research-SDD tool catalog check could not run (exit 1 — check INSTALLED-TOOLS.md and tool-registry.md):"$'\n'"verify-tool-catalog: ERROR — cannot find "*"INSTALLED-TOOLS.md (absent-input)" ]]; then
  ok "11 real binary, input absent → 'could not run (exit 1)' banner with the ERROR line, hook exit 0"
else no "11 absent input: rc=$RC ctx=[$CTX]"; fi

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
  if mk_mut "teeth A: own dir dropped" "$SUT" "$TMP/mutA.sh" 's/ "\$_RSDD_SELF" "\$@"$/ "$@"/'; then
    stage_hook "$TMP/mA" "$TMP/mutA.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mA/verify-tool-catalog-hook.sh" >/dev/null 2>&1
    if [ "$(tr '\n' ' ' < "$TMP/args")" = "verify tool-catalog-hook " ]; then ok "teeth A: own dir dropped → case 3 would go RED"; else no "teeth A: mutant still passes the own dir (args=[$(tr '\n' ' ' < "$TMP/args")])"; fi
  fi
  # B: the caller's arguments dropped → --full never reaches the binary → case 4.
  if mk_mut "teeth B: arguments dropped" "$SUT" "$TMP/mutB.sh" 's/ "\$@"$//'; then
    stage_hook "$TMP/mB" "$TMP/mutB.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mB/verify-tool-catalog-hook.sh" --full >/dev/null 2>&1
    if [ "$(tr '\n' ' ' < "$TMP/args")" = "verify tool-catalog-hook $(cd -P "$TMP/mB" && pwd -P) " ]; then ok "teeth B: --full lost → case 4 would go RED"; else no "teeth B: mutant still forwards --full (args=[$(tr '\n' ' ' < "$TMP/args")])"; fi
  fi
  # C: sweep mode changed to gate → the degraded envelope vanishes (stdout empty) → case 6.
  if mk_mut "teeth C: sweep → gate" "$SUT" "$TMP/mutC.sh" 's/rsdd_exec_hook sweep /rsdd_exec_hook gate /'; then
    stage_hook "$TMP/mC" "$TMP/mutC.sh"
    OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$TMP/mC/verify-tool-catalog-hook.sh" 2>/dev/null)"
    if [ -z "$OUT" ]; then ok "teeth C: gate degraded mode → empty stdout, case 6 would go RED"; else no "teeth C: mutant still emits [$OUT]"; fi
  fi
  # D: wrong command (the check instead of the hook) → the real run prints the plain report, not an envelope → case 9.
  if mk_mut "teeth D: wrong command" "$SUT" "$TMP/mutD.sh" 's/verify tool-catalog-hook /verify tool-catalog /'; then
    e2e_kit e2e-mutd "typst" -; cp "$TMP/mutD.sh" "$TMP/e2e-mutd/verify-tool-catalog-hook.sh"
    OUT="$(RSDD_BIN="$REAL_BIN" bash "$TMP/e2e-mutd/verify-tool-catalog-hook.sh" 2>&1)"
    if ! jq -e . >/dev/null 2>&1 <<<"$OUT"; then ok "teeth D: wrong command → plain report, no envelope → case 9 would go RED"; else no "teeth D: mutant still emits an envelope"; fi
  fi
  # E: the missing-lib guard stripped → no announcement → checked here directly.
  if mk_mut "teeth E: guard removed" "$SUT" "$TMP/mutE.sh" 's/ 2>\/dev\/null || { printf .*exit 0; }//'; then
    mkdir -p "$TMP/mE"; cp "$TMP/mutE.sh" "$TMP/mE/verify-tool-catalog-hook.sh"
    OUT="$(bash "$TMP/mE/verify-tool-catalog-hook.sh" 2>/dev/null)"
    if [ -z "$OUT" ]; then ok "teeth E: unguarded hook is silent when the lib is missing → the guard has teeth"; else no "teeth E: mutant still announces [$OUT]"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
