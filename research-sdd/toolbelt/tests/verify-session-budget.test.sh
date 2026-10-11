#!/usr/bin/env bash
# verify-session-budget.test.sh — harness for verify-session-budget.sh (kit issue #2129).
# Fixture targets live under tests/fixtures/verify-session-budget/ (stub SessionStart hooks that emit
# known character counts). Pins: per-hook chars, TRUNCATED (> 10,000), OVER BUDGET (aggregate >= 8,000),
# JSON-shaped output, per-source matcher filtering and dedupe, multi-line commands, hook-own timeouts,
# typed degraded / absent-input / empty-input states (jq missing, invalid settings JSON, no bwrap, bwrap
# that cannot start, no UTF-8 locale, incomplete sandbox copy), sandbox containment (no write to $HOME or
# /tmp, no network, no agent-socket variables) and that the target is byte-identical after the run.
# Sandbox-dependent cases need a USABLE unprivileged bwrap (probed once with `bwrap --ro-bind / / true`);
# without it they print a typed `  SKIP  ... (no usable bwrap)` line and are NOT counted as passed or failed.
# Usage: verify-session-budget.test.sh [--prove-teeth]
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-session-budget.sh"
FIXSRC="$HERE/fixtures/verify-session-budget"
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
pass=0; fail=0; skipped=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
sk() { printf '  SKIP  %s (no usable bwrap)\n' "$1"; skipped=$((skipped+1)); }
echo "== verify-session-budget.test.sh =="

[ -f "$SUT" ] || { no "0 SUT not found: $SUT"; echo "== $pass passed · $fail failed =="; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"
BW_OK=0
if command -v bwrap >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && bwrap --ro-bind / / true >/dev/null 2>&1; then BW_OK=1; fi
[ "$BW_OK" = 1 ] || echo "  NOTE  no usable unprivileged bwrap here: sandbox-dependent cases are SKIPPED, not passed"

snap() { ( cd "$1" && find . -printf '%p %y %s %T@\n' | LC_ALL=C sort; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) ; }

run() { # run SUT ($1) against a fixture dir ($2), short hook cap; sets OUT, RC
  OUT="$(RSDD_BUDGET_HOOK_TIMEOUT="${HOOK_TO:-10}" "$BASH_BIN" "$1" ${2:+"$2"} 2>&1)"; RC=$?
}
has() { grep -qE -- "$2" <<<"$1"; }
block() { sed -n "/^source $2:/,/^aggregate\[$2\]/p" <<<"$1"; }   # one source's hook lines

# mkbin <dir> [omit...] : a PATH holding symlinks to every tool the SUT and the stub hooks use, minus <omit>.
mkbin() {
  local d="$1" t p o skip; shift
  mkdir -p "$d"
  for t in mktemp rm mkdir basename head cut tr wc cat sleep timeout jq bwrap cp date true env bash; do
    skip=0; for o in "$@"; do [ "$o" = "$t" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    p="$(type -P "$t")" || continue
    ln -sf "$p" "$d/$t"
  done
}

check_suite() { # $1 = SUT path used by every case; runs on a FRESH COPY of the fixtures (a mutant may leak writes)
  local S="$1" FIX ESC="/tmp/rsdd-budget-esc-$$" FHOME B
  FIX="$(mktemp -d "$TMP/fix.XXXXXX")"; cp -a "$FIXSRC/." "$FIX/"
  FHOME="$FIX/home"; mkdir -p "$FHOME"
  # --- typed input states that need no sandbox ---------------------------------------------------------------
  run "$S" "$FIX/empty"
  has "$OUT" 'state: empty-input' && ok "18 no SessionStart hooks -> empty-input" || no "18 empty state wrong: [$OUT]"
  run "$S" "$FIX/absent"
  has "$OUT" 'state: absent-input' && ok "19 missing settings -> absent-input" || no "19 absent state wrong: [$OUT]"
  run "$S" "$TMP/no-such-dir"
  [ "$RC" = 2 ] && ok "20 nonexistent target dir is a usage error (exit 2)" || no "20 exit $RC want 2"
  run "$S"
  [ "$RC" = 2 ] && ok "21 no argument is a usage error (exit 2)" || no "21 exit $RC want 2"
  run "$S" "$FIX/badjson"
  has "$OUT" 'state: degraded \(settings.json is not a readable JSON object' && [ "$RC" = 0 ] && ok "22 invalid settings JSON -> typed degraded, exit 0" || no "22 badjson wrong: rc=$RC [$OUT]"
  B="$TMP/bin-nojq"; rm -rf "$B"; mkbin "$B" jq
  OUT="$(PATH="$B" "$BASH_BIN" "$S" "$FIX/mixed" 2>&1)"; RC=$?
  has "$OUT" 'state: degraded \(jq unavailable' && [ "$RC" = 0 ] && ok "23 jq missing -> typed degraded, no hook run" || no "23 no-jq wrong: rc=$RC [$OUT]"
  B="$TMP/bin-nobwrap"; rm -rf "$B"; mkbin "$B" bwrap
  snap "$FIX/mixed" > "$TMP/b2"
  OUT="$(PATH="$B" "$BASH_BIN" "$S" "$FIX/mixed" 2>&1)"; RC=$?
  snap "$FIX/mixed" > "$TMP/a2"
  has "$OUT" 'hook\[1\] chars=n/a status=degraded\(no-sandbox: bwrap not installed\)' && has "$OUT" 'state: degraded' && [ "$RC" = 0 ] \
    && ok "24 bwrap missing -> every hook degraded(no-sandbox: bwrap not installed)" || no "24 no-bwrap wrong: rc=$RC [$OUT]"
  cmp -s "$TMP/b2" "$TMP/a2" && [ ! -e "$FIX/mixed/.claude/.hook-wrote-this" ] && ok "25 nothing was run unprotected without a sandbox" || no "25 target changed without a sandbox"
  B="$TMP/bin-badbwrap"; rm -rf "$B"; mkbin "$B" bwrap
  printf '#!/bin/sh\necho "bwrap: No permissions to create new namespace" >&2\nexit 1\n' > "$B/bwrap"; chmod +x "$B/bwrap"
  OUT="$(PATH="$B" "$BASH_BIN" "$S" "$FIX/mixed" 2>&1)"; RC=$?
  has "$OUT" 'status=degraded\(no-sandbox: bwrap cannot start: bwrap: No permissions' && ! has "$OUT" 'degraded\(exit 1\)' \
    && ok "26 bwrap present but cannot start -> degraded(no-sandbox: <reason>), not degraded(exit 1)" || no "26 unusable-bwrap wrong: [$OUT]"

  if [ "$BW_OK" != 1 ]; then
    sk "27-60 sandbox cases (per-hook numbers, TRUNCATED, matchers, newline, timeouts, containment, copy, locale)"
    return
  fi

  # --- mixed: per-hook numbers, TRUNCATED, JSON, no mutation -------------------------------------------------
  snap "$FIX/mixed" > "$TMP/before"
  run "$S" "$FIX/mixed"
  snap "$FIX/mixed" > "$TMP/after"
  has "$OUT" 'hook\[1\] chars=500 status=ok' && ok "1 plain 500-char hook measured as 500 ok" || no "1 plain500 line missing: [$OUT]"
  has "$OUT" 'hook\[2\] chars=10500 status=TRUNCATED' && ok "2 10,500-char hook is TRUNCATED" || no "2 TRUNCATED line missing: [$OUT]"
  has "$OUT" 'hook\[3\] chars=500 status=ok' && ok "3 JSON additionalContext+systemMessage counted (300+200)" || no "3 json line missing: [$OUT]"
  has "$OUT" 'hook\[4\] chars=5 status=ok' && ok "4 writing hook still measured (5 chars)" || no "4 writer line missing: [$OUT]"
  has "$OUT" 'aggregate: 11505 chars .*OVER BUDGET' && ok "5 aggregate 11505 flagged OVER BUDGET" || no "5 aggregate line wrong: [$OUT]"
  [ "$RC" = 0 ] && ok "6 findings are WARN-only (exit 0)" || no "6 exit $RC want 0"
  cmp -s "$TMP/before" "$TMP/after" && ok "7 target byte-identical (content+mtime) after run" || no "7 target CHANGED: $(diff "$TMP/before" "$TMP/after" | head -5)"
  [ ! -e "$FIX/mixed/.claude/.hook-wrote-this" ] && [ ! -e "$FIX/mixed/stray-root-file" ] && ok "8 hook writes never reached the target" || no "8 hook write leaked into the target"
  # --- degraded ------------------------------------------------------------------------------------------------
  HOOK_TO=1 run "$S" "$FIX/degraded"
  has "$OUT" 'hook\[1\] chars=100 status=ok' && ok "9 healthy hook still measured beside degraded ones" || no "9 ok100 missing: [$OUT]"
  has "$OUT" 'hook\[2\] .*status=degraded\(timeout' && ok "10 hanging hook is degraded(timeout)" || no "10 hang not degraded: [$OUT]"
  has "$OUT" 'hook\[3\] .*status=degraded\(exit 1' && ok "11 failing hook is degraded(exit 1), partial output not counted" || no "11 fail not degraded: [$OUT]"
  has "$OUT" 'hook\[4\] .*status=degraded\(' && ok "12 unresolvable hook is degraded" || no "12 missing not degraded: [$OUT]"
  has "$OUT" 'hook\[2\] chars=0' && no "13 degraded hook reported as chars=0" || ok "13 degraded hook is never counted as 0 chars"
  has "$OUT" 'aggregate: 100 chars .*partial: 3 degraded' && ok "14 aggregate is marked partial with the degraded count" || no "14 aggregate partial wrong: [$OUT]"
  [ "$RC" = 0 ] && ok "15 degraded is WARN-only (exit 0)" || no "15 exit $RC want 0"
  # --- over: aggregate only ----------------------------------------------------------------------------------
  run "$S" "$FIX/over"
  has "$OUT" 'TRUNCATED' && no "16 no single hook should be TRUNCATED: [$OUT]" || ok "16 no TRUNCATED when every hook is under 10,000"
  has "$OUT" 'aggregate: 9000 chars .*OVER BUDGET' && ok "17 aggregate 9000 (3x3000) OVER BUDGET" || no "17 aggregate wrong: [$OUT]"
  # --- per-source matcher filtering + dedupe -------------------------------------------------------------------
  run "$S" "$FIX/sources"
  has "$OUT" 'aggregate\[startup\]: 500 chars .* OK' && has "$OUT" 'aggregate\[resume\]: 5500 chars .* OK' \
    && has "$OUT" 'aggregate\[clear\]: 500 chars .* OK' && has "$OUT" 'aggregate\[compact\]: 9100 chars .*OVER BUDGET' \
    && ok "27 per-source totals follow the matchers (startup 500, resume 5500, clear 500, compact 9100)" || no "27 per-source totals wrong: [$OUT]"
  has "$OUT" 'aggregate: 9100 chars .*OVER BUDGET worst-source=compact' && ok "28 the worst source (compact-only hook) decides the verdict" || no "28 worst source wrong: [$OUT]"
  [ "$(block "$OUT" startup | grep -c '^hook\[')" = 2 ] && ok "29 identical command under two entries runs once within a source" || no "29 dedupe wrong: [$(block "$OUT" startup)]"
  # --- multi-line command is ONE hook ----------------------------------------------------------------------------
  run "$S" "$FIX/newline"
  [ "$(block "$OUT" startup | grep -c '^hook\[')" = 1 ] && has "$OUT" 'aggregate\[startup\]: 10 chars' && ok "30 a command with embedded newlines is one hook (10 chars)" || no "30 newline command split: [$(block "$OUT" startup)]"
  # --- the hook's own timeout --------------------------------------------------------------------------------------
  run "$S" "$FIX/timeouts"
  has "$OUT" 'hook\[1\] chars=0 status=timed-out\(hook timeout 1s\)' && has "$OUT" 'state: ok' && ok "31 a hook outliving its own timeout counts 0 with a typed timed-out note" || no "31 own-timeout wrong: [$OUT]"
  # --- characters, not bytes -----------------------------------------------------------------------------------------
  run "$S" "$FIX/utf8"
  has "$OUT" 'hook\[1\] chars=3 status=ok' && ok "32 three accented characters count as 3 (code points)" || no "32 utf8 wrong: [$OUT]"
  B="$TMP/bin-nowc"; rm -rf "$B"; mkbin "$B"; rm -f "$B/wc"
  printf '#!/bin/sh\necho 2\n' > "$B/wc"; chmod +x "$B/wc"
  OUT="$(PATH="$B" RSDD_BUDGET_HOOK_TIMEOUT=10 "$BASH_BIN" "$S" "$FIX/utf8" 2>&1)"; RC=$?
  has "$OUT" 'status=degraded\(no-utf8-locale' && has "$OUT" 'state: degraded' && ok "33 a wc that counts bytes -> typed degraded(no-utf8-locale)" || no "33 locale probe wrong: [$OUT]"
  # --- incomplete sandbox copy -----------------------------------------------------------------------------------------
  if [ "$(id -u)" != 0 ]; then
    : > "$FIX/utf8/.claude/unreadable"; chmod 000 "$FIX/utf8/.claude/unreadable"
    run "$S" "$FIX/utf8"
    has "$OUT" 'status=degraded\(incomplete-sandbox-copy' && ok "34 a .claude entry that cannot be copied -> degraded(incomplete-sandbox-copy)" || no "34 copy failure wrong: [$OUT]"
    chmod 600 "$FIX/utf8/.claude/unreadable"
  else
    sk "34 unreadable-entry copy case (running as root)"
  fi
  # --- containment: no write to HOME or /tmp, no network, no agent-socket variables -----------------------------------
  rm -f "$ESC"
  OUT="$(HOME="$FHOME" RSDD_ESCAPE_TMP="$ESC" SSH_AUTH_SOCK=/tmp/agent.sock SSH_AGENT_PID=4242 DBUS_SESSION_BUS_ADDRESS=unix:path=/x \
         RSDD_BUDGET_HOOK_TIMEOUT=10 "$BASH_BIN" "$S" "$FIX/escape" 2>&1)"
  has "$OUT" 'hook\[1\] chars=23 status=ok' && [ ! -e "$FHOME/rsdd-budget-escape" ] && [ ! -e "$ESC" ] \
    && ok "35 writes to \$HOME and to /tmp outside TMPDIR are blocked" || no "35 containment write leak: [$OUT] home=$(ls "$FHOME") esc=$(ls "$ESC" 2>&1)"
  has "$OUT" 'hook\[2\] chars=1 status=ok' && ok "36 only the loopback interface is visible (no network)" || no "36 network namespace not isolated: [$OUT]"
  has "$OUT" 'hook\[3\] chars=0 status=ok' && ok "37 SSH_AUTH_SOCK / SSH_AGENT_PID / DBUS variables are not inherited" || no "37 agent variables leaked: [$OUT]"
  rm -f "$ESC"
}

check_suite "$SUT"

# ---- Teeth ------------------------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  echo "-- teeth: each mutant must turn at least one case RED --"
  tooth() { # tooth NEEDS_SANDBOX LABEL SED_EXPR
    local needs="$1" label="$2" expr="$3" m="$TMP/mut-$RANDOM.sh" before_fail p0 sk0 mf
    if [ "$needs" = sb ] && [ "$BW_OK" != 1 ]; then sk "teeth: $label"; return 0; fi
    rm -f -- "$m"
    mutant_chain_or_count fail "$label" "$SUT" "$m" "$expr" || return 0
    rm -rf "$TMP/mutkit"; mkdir -p "$TMP/mutkit/lib"; cp "$m" "$TMP/mutkit/verify-session-budget.sh"; chmod +x "$TMP/mutkit/verify-session-budget.sh"
    before_fail=$fail; p0=$pass; sk0=$skipped
    check_suite "$TMP/mutkit/verify-session-budget.sh" >"$TMP/mut.log" 2>&1
    # check_suite bumps the counters for the mutant; roll them back and judge by the log.
    mf="$(grep -c '^  FAIL  ' "$TMP/mut.log")"
    pass=$p0; fail=$before_fail; skipped=$sk0
    if [ "$mf" -gt 0 ]; then ok "teeth: $label -> $mf case(s) went RED"; else no "teeth: $label stayed fully GREEN (no bite)"; fi
  }
  tooth sb "truncation threshold 10000 -> 20000" 's/^cap=10000/cap=20000/'
  tooth sb "budget 8000 -> 80000" 's/^budget=8000/budget=80000/'
  tooth sb "non-zero exit not degraded" 's/elif \[ "\$rc" != 0 \]/elif false/'
  tooth sb "script-cap timeout not degraded" 's/H_LINE="degraded(timeout /H_LINE="ok(timeout /'
  tooth sb "hook-own timeout reported degraded" 's/H_LINE="timed-out(hook timeout \${decl}s)"; H_KIND=zero/H_LINE="degraded(hook-timeout)"; H_KIND=deg/'
  tooth sb "sandbox bind dropped (hooks write to the real target)" 's/--bind "\$_sb_dotclaude" "\$target\/.claude"/--bind "$target\/.claude" "$target\/.claude"/'
  tooth sb "json systemMessage ignored" 's/(\.systemMessage \/\/ "")/("")/'
  tooth sb "root filesystem writable (--ro-bind / / -> --bind / /)" 's/bwrap --ro-bind \/ \/ --dev/bwrap --bind \/ \/ --dev/'
  tooth sb "network namespace not unshared" 's/ --unshare-net//'
  tooth sb "SSH_AUTH_SOCK inherited" 's/--unsetenv SSH_AUTH_SOCK //'
  tooth sb "matcher ignored (every entry counts for every source)" 's/(\$src | test("^(?:" + \$m + ")\$"))/true/'
  tooth sb "dedupe removed" 's/\[ "\$dup" = 1 \] && continue/:/'
  tooth sb "records split on newline instead of NUL" 's/"\\u0000"/"\\n"/'
  tooth sb "copy failure ignored" 's/|| copy_fail=.*$/|| true/'
  tooth sb "utf8 probe always passes" 's/|| utf8_ok=0/|| utf8_ok=1/'
  tooth any "bwrap start probe removed" 's/elif ! perr="\$(bwrap --ro-bind \/ \/ true 2>&1)"; then/elif false; then/'
  tooth any "bwrap-missing reason blanked" 's/sandbox_reason="bwrap not installed"/sandbox_reason=""/'
  tooth any "jq-missing guard removed" 's/if ! command -v jq >\/dev\/null 2>&1; then echo "state: degraded (jq unavailable/if false; then echo "state: degraded (jq unavailable/'
  tooth any "invalid-JSON guard removed" 's/^if ! jq -e .type == "object". "\$settings" >\/dev\/null 2>&1; then/if false; then/'
fi

echo "== $pass passed · $fail failed =="
[ "$skipped" -eq 0 ] || echo "($skipped sandbox-dependent case group(s) skipped: no usable bwrap)"
[ "$fail" -eq 0 ] || exit 1
