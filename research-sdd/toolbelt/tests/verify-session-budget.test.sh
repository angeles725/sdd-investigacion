#!/usr/bin/env bash
# verify-session-budget.test.sh — harness for verify-session-budget.sh (kit issue #2129).
# Fixture targets live under tests/fixtures/verify-session-budget/ (stub SessionStart hooks that emit
# known character counts). Pins: per-hook chars, TRUNCATED (> 10,000), OVER BUDGET (aggregate >= 8,000),
# JSON-shaped output, per-source matcher filtering and dedupe, multi-line commands, hook-own timeouts,
# typed degraded / absent-input / empty-input states (jq missing, invalid settings JSON, no bwrap, bwrap
# that cannot start, no UTF-8 locale, incomplete sandbox copy), sandbox containment (no write to $HOME or
# /tmp, no network, no agent-socket variables) and that the target is byte-identical after the run.
# Sandbox-dependent cases need a USABLE unprivileged bwrap (probed once with `bwrap --ro-bind / / true`);
# without it each assertion prints ONE typed `  SKIP  ... (no usable bwrap)` line and is NOT counted as passed or failed.
# Containment is nevertheless ALWAYS asserted: a recording bwrap shim (first on PATH) checks the exact argv.
# Usage: verify-session-budget.test.sh [--prove-teeth]
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-session-budget.sh"
FIXSRC="$HERE/fixtures/verify-session-budget"
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
pass=0; fail=0; skipped=0
SKIPMODE=0   # 1 inside the sandbox-dependent section when bwrap is unusable: every assertion becomes ONE typed SKIP line
sk() { local l="${1%%$'\n'*}"; l="${l%%: \[*}"; printf '  SKIP  %s (no usable bwrap)\n' "$l"; skipped=$((skipped+1)); }
ok() { if [ "$SKIPMODE" = 1 ]; then sk "$1"; else printf '  PASS  %s\n' "$1"; pass=$((pass+1)); fi; }
no() { if [ "$SKIPMODE" = 1 ]; then sk "$1"; else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
echo "== verify-session-budget.test.sh =="

[ -f "$SUT" ] || { no "0 SUT not found: $SUT"; echo "== $pass passed · $fail failed =="; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"
BW_OK=0
if command -v bwrap >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && bwrap --ro-bind / / true >/dev/null 2>&1; then BW_OK=1; fi
# Kit issue #2138: CI sets RSDD_REQUIRE_BWRAP=1 so an unusable bwrap FAILS instead of silently skipping the sandbox cases.
if [ "$BW_OK" != 1 ] && [ "${RSDD_REQUIRE_BWRAP:-}" = 1 ]; then no "0 RSDD_REQUIRE_BWRAP=1 but no usable unprivileged bwrap (sandbox cases would SKIP)"; fi
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

# shim_cases <SUT> <FIX> : bwrap is replaced by a shim that records its argv and runs nothing; every required
# containment flag must be on EVERY run invocation. Runs where bwrap itself cannot (CI images without user namespaces).
shim_cases() {
  local S="$1" FIX="$2" SH="$TMP/shim-bin" LOG="$TMP/shim.log" T miss i n rd="$TMP/shim-recs"
  rm -rf "$SH" "$rd"; mkdir -p "$SH" "$rd"; : > "$LOG"
  printf '#!/bin/sh\nif [ "$*" = "--ro-bind / / true" ]; then exit 0; fi\ncat >/dev/null\n{ for a in "$@"; do printf "%%s\\n" "$a"; done; echo "--END--"; } >> "$RSDD_SHIM_LOG"\nexit 0\n' > "$SH/bwrap"
  chmod +x "$SH/bwrap"
  T="$(cd "$FIX/mixed" && pwd -P)"
  OUT="$(PATH="$SH:$PATH" RSDD_SHIM_LOG="$LOG" RSDD_BUDGET_HOOK_TIMEOUT=10 "$BASH_BIN" "$S" "$FIX/mixed" 2>&1)"; RC=$?
  awk -v dir="$rd" 'BEGIN{n=1} /^--END--$/{n++; next} {print > (dir "/rec." n)}' "$LOG"
  n="$(find "$rd" -name 'rec.*' | wc -l | tr -d ' ')"
  [ "$n" = 4 ] && ok "40 the shim saw one bwrap run per hook (4); zero runs would fail closed" || no "40 expected 4 recorded bwrap runs, saw $n: [$OUT]"
  miss=""
  for ((i=1; i<=n; i++)); do miss="$miss$(shim_missing "$rd/rec.$i" "$T")"; done
  [ -z "$miss" ] && [ "$n" -gt 0 ] && ok "41 every bwrap run carries the full containment argv (ro-bind /, .claude copy bind, unshare pid/net/ipc, new-session, die-with-parent, unsetenv x5)" \
    || no "41 containment argv incomplete, missing:$miss"
}

# shim_missing <record-file> <target> : prints " name" for each required argument absent from one recorded argv.
shim_missing() {
  local rec=() i out="" nm found=0
  mapfile -t rec < "$1"
  [ "${#rec[@]}" -gt 0 ] || { printf ' empty-record'; return; }
  seq_in() { local want=("$@") a b ok; for ((a=0; a<=${#rec[@]}-${#want[@]}; a++)); do ok=1; for ((b=0; b<${#want[@]}; b++)); do [ "${rec[a+b]}" = "${want[b]}" ] || { ok=0; break; }; done; [ "$ok" = 1 ] && return 0; done; return 1; }
  seq_in --ro-bind / / || out="$out ro-bind-root"
  for nm in --unshare-pid --unshare-net --unshare-ipc --new-session --die-with-parent; do seq_in "$nm" || out="$out $nm"; done
  for nm in SSH_AUTH_SOCK SSH_AGENT_PID GPG_AGENT_INFO DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR; do seq_in --unsetenv "$nm" || out="$out unsetenv-$nm"; done
  seq_in --setenv CLAUDE_PROJECT_DIR "$2" || out="$out setenv-CLAUDE_PROJECT_DIR"
  for ((i=0; i<${#rec[@]}-2; i++)); do
    if [ "${rec[i]}" = --bind ] && [ "${rec[i+2]}" = "$2/.claude" ] && [ "${rec[i+1]}" != "${rec[i+2]}" ]; then found=1; fi
  done
  [ "$found" = 1 ] || out="$out dotclaude-copy-bind"
  printf '%s' "$out"
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

  # --- containment argv, asserted in EVERY environment through a recording bwrap shim -------------------------------
  shim_cases "$S" "$FIX"

  SKIPMODE=0; [ "$BW_OK" = 1 ] || SKIPMODE=1

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
  has "$OUT" 'hook\[1\] chars=0 status=timed-out\(hook timeout 1s\)' && has "$OUT" 'state: ok \(1 hook runs, 0 truncated, 1 timed-out\)' && ok "31 a hook outliving its own timeout counts 0, typed timed-out note, counted on the state line" || no "31 own-timeout wrong: [$OUT]"
  # --- Claude Code's documented matcher rule + the fork source ------------------------------------------------------
  run "$S" "$FIX/matchers"
  has "$OUT" 'aggregate\[startup\]: 500 chars' && has "$OUT" 'aggregate\[resume\]: 300 chars' && has "$OUT" 'aggregate\[fork\]: 50 chars' \
    && ok "42 regex '^start' (unanchored) and list 'startup, resume' (comma, spaces) select startup/resume; exact 'fork' selects fork" || no "42 matcher rule wrong: [$OUT]"
  has "$OUT" 'source clear: \(no matching' && has "$OUT" 'source compact: \(no matching' && ! has "$OUT" 'exact7000|chars=7000' \
    && ok "43 exact 'start' does NOT match 'startup' (its 7000-char hook never runs)" || no "43 exact-vs-prefix wrong: [$OUT]"
  # --- degraded in ANY source marks the final aggregate partial; capped commands are not re-run ----------------------
  run "$S" "$FIX/partialmix"
  has "$OUT" 'aggregate: 9000 chars .*OVER BUDGET \(partial: 1 degraded in startup\) worst-source=compact' \
    && ok "44 the final aggregate is partial even when the WORST source is clean (names the degraded source)" || no "44 partial marker wrong: [$OUT]"
  HOOK_TO=1 run "$S" "$FIX/capped"
  [ "$(grep -c 'not re-run' <<<"$OUT")" = 4 ] && has "$OUT" 'aggregate\[startup\].*partial' && has "$OUT" 'partial: 5 degraded in startup,resume,clear,compact,fork' \
    && ok "45 a command that hit the script cap is run once; later sources say 'not re-run'" || no "45 cap re-run wrong: [$OUT]"
  # --- every source gets a pristine sandbox copy ------------------------------------------------------------------------
  run "$S" "$FIX/fresh"
  [ "$(grep -c 'chars=5 status=ok' <<<"$OUT")" = 5 ] && ok "46 each of the five sources sees a fresh .claude copy (order-independent)" || no "46 sandbox state leaked between sources: [$OUT]"
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
  pi_cases "$S" "$FIX"
  SKIPMODE=0
}

# --- pi / gentle-shell harness (kit issue #2174) --------------------------------------------------------------------------
# A stub kit (eight sweep hooks printing RSDD_STUB_N characters) feeds the REAL kit extension (install/pi/research-sdd-hooks.ts);
# fixture targets add .pi/extensions sections of known size. The instrument must print one aggregate[pi] naming the harness.
PI_EXT_REAL="$HERE/../../install/pi/research-sdd-hooks.ts"
PI_NODE_OK=0; [ "$(node -p 'String(process.features.typescript)' 2>/dev/null || echo false)" != false ] && PI_NODE_OK=1
mkstubkit() { # $1 = dir ; eight sweep hooks, each printing a JSON additionalContext of $RSDD_STUB_N characters
  local d="$1" h
  mkdir -p "$d/toolbelt"
  for h in sweep-retros-hook sweep-audits-hook sweep-breakthroughs-hook verify-registry-hook verify-kit-clean-hook sweep-tools-hook verify-tool-catalog-hook verify-skill-drift-hook; do
    printf '#!/usr/bin/env bash\nprintf '"'"'{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%%s"}}'"'"' "$(sleep "${RSDD_STUB_SLEEP:-0}"; head -c "${RSDD_STUB_N:-100}" /dev/zero | tr "\\0" k)"\n' > "$d/toolbelt/$h.sh"
    chmod +x "$d/toolbelt/$h.sh"
  done
}
runpi() { # runpi SUT TARGET [extra env assignments via PIENV array]; sets OUT, RC
  OUT="$(env RSDD_BUDGET_KIT="$PI_KIT" RSDD_BUDGET_PI_HOOKS="$PI_EXT_REAL" RSDD_BUDGET_HOOK_TIMEOUT="${HOOK_TO:-20}" ${PIENV[@]+"${PIENV[@]}"} "$BASH_BIN" "$1" --harness pi "$2" 2>&1)"; RC=$?
}
pisum() { sed -n 's/^section\[[^]]*\] .* chars=\([0-9]*\) status=.*/\1/p' <<<"$1" | awk '{n+=$1} END{print n+0}'; }
pi_cases() {
  local S="$1" FIX="$2" B bef aft T sum agg
  PI_KIT="$TMP/pi-stubkit"; rm -rf "$PI_KIT"; mkstubkit "$PI_KIT"; PIENV=()
  # --- typed states that need no sandbox ----------------------------------------------------------------------------------
  OUT="$("$BASH_BIN" "$S" --harness nope "$FIX/pi-card" 2>&1)"; RC=$?
  [ "$RC" = 2 ] && ok "50 an unknown --harness value is a usage error (exit 2)" || no "50 exit $RC want 2: [$OUT]"
  B="$TMP/bin-nonode"; rm -rf "$B"; mkbin "$B"
  OUT="$(PATH="$B" RSDD_BUDGET_KIT="$PI_KIT" RSDD_BUDGET_PI_HOOKS="$PI_EXT_REAL" "$BASH_BIN" "$S" --harness pi "$FIX/pi-card" 2>&1)"; RC=$?
  has "$OUT" 'pi: DEGRADED — node unavailable' && has "$OUT" 'state: degraded' && ! has "$OUT" 'aggregate\[pi\]' && [ "$RC" = 0 ] \
    && ok "51 node missing -> 'pi: DEGRADED — node unavailable', no aggregate[pi] (never a silent 0)" || no "51 no-node wrong: rc=$RC [$OUT]"
  B="$TMP/bin-nots"; rm -rf "$B"; mkbin "$B"; printf '#!/bin/sh\necho false\n' > "$B/node"; chmod +x "$B/node"
  OUT="$(PATH="$B" RSDD_BUDGET_KIT="$PI_KIT" RSDD_BUDGET_PI_HOOKS="$PI_EXT_REAL" "$BASH_BIN" "$S" --harness pi "$FIX/pi-card" 2>&1)"; RC=$?
  has "$OUT" 'pi: DEGRADED — node .*no built-in TypeScript type stripping' && ! has "$OUT" 'aggregate\[pi\]' \
    && ok "52 node without TypeScript type stripping -> typed DEGRADED, no aggregate[pi]" || no "52 no-ts wrong: [$OUT]"
  B="$TMP/bin-pinobwrap"; rm -rf "$B"; mkbin "$B" bwrap; ln -sf "$(type -P node)" "$B/node"
  OUT="$(PATH="$B" RSDD_BUDGET_KIT="$PI_KIT" RSDD_BUDGET_PI_HOOKS="$PI_EXT_REAL" "$BASH_BIN" "$S" --harness pi "$FIX/pi-card" 2>&1)"; RC=$?
  has "$OUT" 'pi: DEGRADED — no-sandbox: bwrap not installed' && ! has "$OUT" 'aggregate\[pi\]' \
    && ok "53 bwrap missing -> pi: DEGRADED — no-sandbox (nothing is run unprotected)" || no "53 pi no-bwrap wrong: [$OUT]"
  # --- containment argv through the recording shim (no node run) ------------------------------------------------------------
  local SH="$TMP/pishim-bin" LOG="$TMP/pishim.log" rd="$TMP/pishim-recs" miss n
  rm -rf "$SH" "$rd"; mkdir -p "$SH" "$rd"; : > "$LOG"
  printf '#!/bin/sh\nif [ "$*" = "--ro-bind / / true" ]; then exit 0; fi\n{ for a in "$@"; do printf "%%s\\n" "$a"; done; echo "--END--"; } >> "$RSDD_SHIM_LOG"\nexit 0\n' > "$SH/bwrap"; chmod +x "$SH/bwrap"
  T="$(cd "$FIX/pi-card" && pwd -P)"
  OUT="$(PATH="$SH:$PATH" RSDD_SHIM_LOG="$LOG" RSDD_BUDGET_KIT="$PI_KIT" RSDD_BUDGET_PI_HOOKS="$PI_EXT_REAL" "$BASH_BIN" "$S" --harness pi "$FIX/pi-card" 2>&1)"; RC=$?
  awk -v dir="$rd" 'BEGIN{n=1} /^--END--$/{n++; next} {print > (dir "/rec." n)}' "$LOG"
  n="$(find "$rd" -name 'rec.*' | wc -l | tr -d ' ')"
  miss=""; [ "$n" = 1 ] && miss="$(shim_missing "$rd/rec.1" "$T")"
  if [ "$n" = 1 ] && [ -z "$miss" ]; then ok "54 the pi run is ONE bwrap invocation with the full containment argv (ro-bind /, .claude copy bind, unshare pid/net/ipc, new-session, die-with-parent, unsetenv x5)"
  else no "54 pi containment argv: runs=$n missing:$miss"; fi
  has "$OUT" 'pi: DEGRADED — extension harness produced no records' && ! has "$OUT" 'aggregate\[pi\]' \
    && ok "55 a harness that prints nothing is a typed DEGRADED, not 0 chars" || no "55 empty harness output wrong: [$OUT]"
  # --- real measurement (needs bwrap, node with type stripping) --------------------------------------------------------------
  if [ "$PI_NODE_OK" != 1 ]; then sk "56-62 pi measurement cases (node has no TypeScript type stripping)"; return; fi
  bef="$TMP/pi-before"; aft="$TMP/pi-after"
  snap "$FIX/pi-card" > "$bef"
  PIENV=(RSDD_STUB_N=100); runpi "$S" "$FIX/pi-card"
  snap "$FIX/pi-card" > "$aft"
  has "$OUT" '^harness: pi ' && ok "56 the report names the harness it measured" || no "56 harness line missing: [$OUT]"
  has "$OUT" '^section\[card.ts\] card-section chars=2500 status=ok' && ok "57 a target .pi extension section is measured at its decoded length (2500)" || no "57 card section wrong: [$OUT]"
  has "$OUT" '^section\[research-sdd-hooks.ts\] research-sdd-session chars=[1-9][0-9]* status=ok' && ok "58 the kit extension's research-sdd-session section is measured (non-zero)" || no "58 kit section wrong: [$OUT]"
  [ "$(grep -c '^section\[' <<<"$OUT")" = 2 ] && ok "59a exactly two sections are attributed (kit + card): a section is reported once, under the extension that added it" || no "59a section attribution wrong: [$OUT]"
  sum="$(pisum "$OUT")"; agg="$(sed -n 's/^aggregate\[pi\]: \([0-9]*\) chars.*/\1/p' <<<"$OUT")"
  [ -n "$agg" ] && [ "$agg" = "$sum" ] && [ "$agg" -gt 2500 ] && has "$OUT" '^aggregate\[pi\]: [0-9]+ chars \(budget < 8000\) OK$' && has "$OUT" '^state: ok' \
    && ok "59 aggregate[pi] equals the sum of the section lines and is under budget" || no "59 aggregate wrong: agg=$agg sum=$sum [$OUT]"
  cmp -s "$bef" "$aft" && ok "60 the target is byte-identical after the pi run (writes land in the sandbox copy)" || no "60 target CHANGED: $(diff "$bef" "$aft" | head -3)"
  local LT="$TMP/pi-leak"; rm -rf "$LT"; mkdir -p "$LT"
  PIENV=(RSDD_STUB_N=100 TMPDIR="$LT"); runpi "$S" "$FIX/pi-card"
  [ -z "$(ls -A "$LT")" ] && ! has "$OUT" 'unbound|not found|No such' && has "$OUT" '^aggregate\[pi\]: ' \
    && ok "60a the pi run removes its temp dir on exit and prints no shell error" || no "60a temp leak or shell error: ls=[$(ls -A "$LT")] [$OUT]"
  PIENV=(RSDD_STUB_N=1200); runpi "$S" "$FIX/pi-big"
  has "$OUT" '^aggregate\[pi\]: [0-9]+ chars \(budget < 8000\) OVER BUDGET$' && has "$OUT" 'section\[big.ts\] big-section chars=6000' \
    && ok "61 kit sweeps (8 x 1200 chars, capped) + a 6000-char target section -> OVER BUDGET" || no "61 over-budget wrong: [$OUT]"
  PIENV=(RSDD_STUB_N=100); runpi "$S" "$FIX/pi-none"
  has "$OUT" '^section\[research-sdd-hooks.ts\]' && ! has "$OUT" 'ext\[|section\[card' && has "$OUT" '^state: ok' \
    && ok "62 a target without .pi/extensions measures the kit section alone" || no "62 no-ext target wrong: [$OUT]"
  runpi "$S" "$FIX/pi-broken"
  has "$OUT" 'ext\[broken.ts\] status=degraded\(load failed: .*boom at import' && has "$OUT" 'aggregate\[pi\]: [0-9]+ chars .*\(partial: 1 degraded\)' && has "$OUT" '^state: degraded' \
    && ok "63 an extension that fails to load is degraded and marks the aggregate partial (not 0 chars)" || no "63 broken ext wrong: [$OUT]"
  PIENV=(RSDD_STUB_N=100 RSDD_BUDGET_KIT="$TMP/no-such-kit"); runpi "$S" "$FIX/pi-none"
  has "$OUT" 'section\[research-sdd-hooks.ts\].*status=degraded\(section text reports DEGRADED\)' && has "$OUT" 'partial: 1 degraded' \
    && ok "64 an unresolvable kit (the extension's own DEGRADED text) is measured but marked partial" || no "64 degraded kit wrong: [$OUT]"
  PIENV=(RSDD_STUB_N=100 RSDD_STUB_SLEEP=4); HOOK_TO=1 runpi "$S" "$FIX/pi-none"
  has "$OUT" 'section\[research-sdd-hooks.ts\].*status=degraded\(section text reports DEGRADED\)' && has "$OUT" 'partial: 1 degraded' \
    && ok "64a sweeps that outlive the cap (the kit extension reports them DEGRADED) are measured but marked partial" || no "64a slow sweeps wrong: [$OUT]"
  PIENV=(RSDD_STUB_N=100); OUT="$(RSDD_BUDGET_KIT="$PI_KIT" RSDD_BUDGET_PI_HOOKS="$PI_EXT_REAL" RSDD_BUDGET_HOOK_TIMEOUT=20 GENTLE_PI_AGENTS_CHILD=1 RSDD_PI_HOOKS=off "$BASH_BIN" "$S" --harness pi "$FIX/pi-card" 2>&1)"
  has "$OUT" 'section\[card.ts\] card-section chars=2500' && has "$OUT" 'section\[research-sdd-hooks.ts\] research-sdd-session chars=[1-9]' \
    && ok "65 the caller's GENTLE_PI_AGENTS_CHILD / RSDD_PI_HOOKS do not turn the kit extension off inside the probe" || no "65 ambient env leaked: [$OUT]"
  PIENV=(RSDD_STUB_N=100); OUT="$(RSDD_BUDGET_KIT="$PI_KIT" RSDD_BUDGET_PI_HOOKS="$PI_EXT_REAL" RSDD_BUDGET_HOOK_TIMEOUT=20 "$BASH_BIN" "$S" --harness both "$FIX/pi-card" 2>&1)"
  has "$OUT" '^state: absent-input' && has "$OUT" '^aggregate\[pi\]: ' && ok "66 --harness both prints the Claude report (absent-input here) and then aggregate[pi]" || no "66 both wrong: [$OUT]"
  PIENV=()
  # --- the helper alone: code points, status flags, handler failures --------------------------------------------------------
  local HX="$TMP/pi-helper" H="$HERE/../lib/session-budget-pi.mjs" r
  [ -n "${RSDD_PI_HELPER:-}" ] && H="$RSDD_PI_HELPER"
  rm -rf "$HX"; mkdir -p "$HX"
  printf 'export default (pi: any) => pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["emoji"] = "\\u{1F600}".repeat(10); });\n' > "$HX/a-emoji.ts"
  printf 'export default (pi: any) => pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["p"] = "x sweeps pending (started now)"; });\n' > "$HX/b-pending.ts"
  printf 'export default (pi: any) => pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["d"] = "hook DEGRADED: gone"; });\n' > "$HX/c-degraded.ts"
  printf 'export default (pi: any) => pi.on("before_agent_start", async () => {});\n' > "$HX/d-silent.ts"
  printf 'export default (pi: any) => pi.on("before_agent_start", async () => { throw new Error("handler boom"); });\n' > "$HX/e-throws.ts"
  r="$(node "$H" "$HX" "$HX/a-emoji.ts" "$HX/b-pending.ts" "$HX/c-degraded.ts" "$HX/d-silent.ts" "$HX/e-throws.ts" 2>/dev/null)"
  has "$r" '^S.a-emoji.ts.emoji.10.ok$' && ok "67 the helper counts code points (10 emoji = 10, not 20 UTF-16 units)" || no "67 emoji length wrong: [$r]"
  has "$r" '^S.b-pending.ts.p.[0-9]+.pending$' && has "$r" '^S.c-degraded.ts.d.[0-9]+.degraded-text$' && ok "68 the helper flags 'sweeps pending' and DEGRADED section text" || no "68 flags wrong: [$r]"
  has "$r" '^T.d-silent.ts.0$' && has "$r" '^E.e-throws.ts.before_agent_start failed: handler boom' && ok "69 a silent extension is T 0; a throwing handler is an E record, not a zero" || no "69 silent/throw wrong: [$r]"
}

check_suite "$SUT"

# Gate self-test (kit issue #2138): re-run this suite with a failing bwrap shim first on PATH. With RSDD_REQUIRE_BWRAP=1
# it must print the typed FAIL line and exit 1; without the flag it must SKIP and exit 0.
if [ -z "${RSDD_SB_SELFTEST:-}" ]; then
  SHB="$TMP/shim-bw"; mkdir -p "$SHB"; printf '#!/bin/sh\nexit 1\n' > "$SHB/bwrap"; chmod +x "$SHB/bwrap"
  OUTR="$(PATH="$SHB:$PATH" RSDD_SB_SELFTEST=1 RSDD_REQUIRE_BWRAP=1 "$BASH_BIN" "$HERE/verify-session-budget.test.sh" 2>&1)"; RCR=$?
  has "$OUTR" '  FAIL  0 RSDD_REQUIRE_BWRAP=1' && [ "$RCR" = 1 ] && ok "42 gate: RSDD_REQUIRE_BWRAP=1 + unusable bwrap -> typed FAIL, exit 1" || no "42 require-flag gate: rc=$RCR"
  OUTR="$(PATH="$SHB:$PATH" RSDD_SB_SELFTEST=1 RSDD_REQUIRE_BWRAP=0 "$BASH_BIN" "$HERE/verify-session-budget.test.sh" 2>&1)"; RCR=$?
  has "$OUTR" '  SKIP  ' && ! has "$OUTR" '  FAIL  ' && [ "$RCR" = 0 ] && ok "43 gate: unusable bwrap without the flag -> SKIP, exit 0" || no "43 skip path: rc=$RCR"
fi

# ---- Teeth ------------------------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  echo "-- teeth: each mutant must turn at least one case RED --"
  tooth() { # tooth NEEDS_SANDBOX LABEL SED_EXPR
    local needs="$1" label="$2" expr="$3" m="$TMP/mut-$RANDOM.sh" before_fail p0 sk0 mf
    if [ "$needs" = sb ] && [ "$BW_OK" != 1 ]; then sk "teeth: $label"; return 0; fi
    if [ "$needs" = pi ] && { [ "$BW_OK" != 1 ] || [ "$PI_NODE_OK" != 1 ]; }; then sk "teeth: $label"; return 0; fi
    rm -f -- "$m"
    mutant_chain_or_count fail "$label" "$SUT" "$m" "$expr" || return 0
    rm -rf "$TMP/mutkit"; mkdir -p "$TMP/mutkit/lib"; cp "$m" "$TMP/mutkit/verify-session-budget.sh"; chmod +x "$TMP/mutkit/verify-session-budget.sh"
    cp "$HERE/../lib/session-budget-pi.mjs" "$TMP/mutkit/lib/"
    before_fail=$fail; p0=$pass; sk0=$skipped
    check_suite "$TMP/mutkit/verify-session-budget.sh" >"$TMP/mut.log" 2>&1
    # check_suite bumps the counters for the mutant; roll them back and judge by the log.
    mf="$(grep -c '^  FAIL  ' "$TMP/mut.log")"
    pass=$p0; fail=$before_fail; skipped=$sk0
    if [ "$mf" -gt 0 ]; then ok "teeth: $label -> $mf case(s) went RED"; else no "teeth: $label stayed fully GREEN (no bite)"; fi
  }
  tooth_mjs() { # tooth_mjs LABEL SED_EXPR : mutate lib/session-budget-pi.mjs, run the suite against the real script + that mutant
    local label="$1" expr="$2" mm="$TMP/mutmjs.mjs" bf p0 sk0 mf
    if [ "$BW_OK" != 1 ] || [ "$PI_NODE_OK" != 1 ]; then sk "teeth: $label"; return 0; fi
    rm -f -- "$mm"
    MUTANT_SYNTAX=none mutant_chain_or_count fail "$label" "$HERE/../lib/session-budget-pi.mjs" "$mm" "$expr" || return 0
    node --check "$mm" >/dev/null 2>&1 || { no "teeth: $label: mutant is not valid JavaScript"; return 0; }
    rm -rf "$TMP/mutkit"; mkdir -p "$TMP/mutkit/lib"; cp "$SUT" "$TMP/mutkit/verify-session-budget.sh"; cp "$mm" "$TMP/mutkit/lib/session-budget-pi.mjs"
    bf=$fail; p0=$pass; sk0=$skipped
    RSDD_PI_HELPER="$TMP/mutkit/lib/session-budget-pi.mjs" check_suite "$TMP/mutkit/verify-session-budget.sh" >"$TMP/mut.log" 2>&1
    mf="$(grep -c '^  FAIL  ' "$TMP/mut.log")"
    pass=$p0; fail=$bf; skipped=$sk0
    if [ "$mf" -gt 0 ]; then ok "teeth: $label -> $mf case(s) went RED"; else no "teeth: $label stayed fully GREEN (no bite)"; fi
  }
  tooth sb "truncation threshold 10000 -> 20000" 's/^cap=10000/cap=20000/'
  tooth sb "budget 8000 -> 80000" 's/^budget=8000/budget=80000/'
  tooth sb "non-zero exit not degraded" 's/elif \[ "\$rc" != 0 \]/elif false/'
  tooth sb "script-cap timeout not degraded" 's/H_LINE="degraded(timeout /H_LINE="ok(timeout /'
  tooth sb "hook-own timeout reported degraded" 's/H_LINE="timed-out(hook timeout \${decl}s)"; H_KIND=zero/H_LINE="degraded(hook-timeout)"; H_KIND=deg/'
  tooth sb "sandbox bind dropped (hooks write to the real target)" 's/--bind "\$_sb_dotclaude" "\$target\/.claude"/--bind "$target\/.claude" "$target\/.claude"/'
  tooth sb "json systemMessage ignored" 's/(\.systemMessage \/\/ "")/("")/'
  tooth any "root filesystem writable (--ro-bind / / -> --bind / /)" 's/bwrap --ro-bind \/ \/ --dev/bwrap --bind \/ \/ --dev/'
  tooth any "network namespace not unshared" 's/ --unshare-net//'
  tooth any "SSH_AUTH_SOCK inherited" 's/--unsetenv SSH_AUTH_SOCK //'
  tooth any "SSH_AGENT_PID inherited" 's/ --unsetenv SSH_AGENT_PID//'
  tooth any "GPG_AGENT_INFO inherited" 's/ --unsetenv GPG_AGENT_INFO//'
  tooth any "DBUS_SESSION_BUS_ADDRESS inherited" 's/--unsetenv DBUS_SESSION_BUS_ADDRESS //'
  tooth any "XDG_RUNTIME_DIR inherited" 's/ --unsetenv XDG_RUNTIME_DIR//'
  tooth any "IPC namespace shared" 's/ --unshare-ipc//'
  tooth any "controlling terminal inherited (--new-session dropped)" 's/ --new-session//'
  tooth any "sandbox outlives the parent (--die-with-parent dropped)" 's/ --die-with-parent//'
  tooth any "PID namespace shared" 's/--unshare-pid //'
  tooth any ".claude copy bind replaced by the live target" 's/--bind "\$_sb_dotclaude" "\$target\/.claude"/--bind "$target\/.claude" "$target\/.claude"/'
  tooth sb "exact matcher treated as prefix" 's/elif (\$m | test("\^\[A-Za-z0-9_ ,|-\]+\$")) then/elif false then/'
  tooth sb "fork source dropped" 's/^sources="startup resume clear compact fork"/sources="startup resume clear compact"/'
  tooth sb "final aggregate never partial" 's/&& partial=" (partial: \$ndeg_all degraded in \$degsrcs)"/\&\& partial=""/'
  tooth sb "capped command re-run in every source" 's/if \[ "\$c" = "\$cmd" \]; then H_LINE=/if false; then H_LINE=/'
  tooth sb "sandbox copy made once, not per source" 's/^  prep_sandbox$/  [ -n "${_prepped:-}" ] || prep_sandbox; _prepped=1/'
  tooth sb "timed-out hooks not counted" 's/\[ "\$H_KIND" = zero \] \&\& nto_all=\$((nto_all+1))/:/'
  tooth sb "matcher ignored (every entry counts for every source)" 's/select(mm((\.matcher \/\/ "" | tostring); \$src))/select(true)/'
  tooth sb "regex matcher anchored (^start no longer matches startup)" 's/else (\$s | test(\$m)) end;/else (\$s | test("^(?:" + \$m + ")\$")) end;/'
  tooth sb "dedupe removed" 's/\[ "\$dup" = 1 \] && continue/:/'
  tooth sb "records split on newline instead of NUL" 's/"\\u0000"/"\\n"/'
  tooth sb "copy failure ignored" 's/|| copy_fail=.*$/|| true/'
  tooth sb "utf8 probe always passes" 's/|| utf8_ok=0/|| utf8_ok=1/'
  tooth any "bwrap start probe removed" 's/elif ! perr="\$(bwrap --ro-bind \/ \/ true 2>&1)"; then/elif false; then/'
  tooth any "bwrap-missing reason blanked" 's/sandbox_reason="bwrap not installed"/sandbox_reason=""/'
  # pi harness (kit issue #2174): shell-side mutants (sandbox arguments scoped to pi_section only)
  tooth pi "pi: temp dir never removed" "s/^  trap 'rm -rf \"\$pw\"' EXIT/  :/"
  tooth pi "pi aggregate ignores the section lengths" 's/nsec=$((nsec+1)); st=ok/nsec=$((nsec+1)); st=ok; c=0/'
  tooth pi "pi budget verdict never OVER" 's/\[ "$total" -ge "$budget" \] \&\& echo "OVER BUDGET" || echo OK/echo OK/'
  tooth pi "pi load failure not degraded" 's/E) nrec=$((nrec+1)); ndeg=$((ndeg+1)); echo/E) nrec=$((nrec+1)); echo/'
  tooth pi "pi DEGRADED section text not partial" 's/degraded-text) st="degraded(section text reports DEGRADED)"; ndeg=$((ndeg+1));;/degraded-text) st="degraded(section text reports DEGRADED)";;/'
  tooth any "pi empty harness output accepted as a measurement" 's/if \[ ! -s "$recs" \]; then pi_degraded/if false; then pi_degraded/'
  tooth any "pi sandbox: network shared" '/^pi_section/,/^}/s/ --unshare-net//'
  tooth any "pi sandbox: live .claude bound" '/^pi_section/,/^}/s/--bind "$sbclaude" "$target\/.claude"/--bind "$target\/.claude" "$target\/.claude"/'
  tooth any "pi sandbox: root filesystem writable" '/^pi_section/,/^}/s/bargs=(--ro-bind \/ \/ /bargs=(--bind \/ \/ /'
  tooth any "pi sandbox: SSH_AUTH_SOCK inherited" '/^pi_section/,/^}/s/--unsetenv SSH_AUTH_SOCK //'
  tooth pi "pi: caller GENTLE_PI_AGENTS_CHILD inherited" 's/--unsetenv GENTLE_PI_AGENTS_CHILD //'
  tooth pi "pi: caller RSDD_PI_HOOKS inherited" 's/ --unsetenv RSDD_PI_HOOKS//'
  tooth pi "pi: kit extension not linked into the agent home" 's/^  ln -s "$ext" "$pihome\/extensions\/research-sdd-hooks.ts"/  :/'
  tooth pi "pi: target extensions never discovered" 's/^  if \[ -d "$target\/.pi\/extensions" \]; then/  if false; then/'
  tooth pi "pi: --harness both skips the pi report" 's/; bash "$self\/verify-session-budget.sh" --harness pi "$target"; exit 0; fi/; exit 0; fi/'
  tooth any "pi: node TypeScript probe removed" "s/case \"\$ts\" in ''|false|undefined) pi_degraded/case \"\$ts\" in zzz) pi_degraded/"
  tooth_mjs "helper counts UTF-16 units, not code points" 's/\[\.\.\.text\]\.length/text.length/'
  tooth_mjs "helper ignores the pending flag" 's/\/sweeps pending\/\.test/\/zzzz\/.test/'
  tooth_mjs "helper ignores DEGRADED text" 's/\/\\bDEGRADED\\b\/\.test/\/zzzz\/.test/'
  tooth_mjs "helper reports every section for every extension (no diff)" 's/!before\.has(k)/true/'
  tooth_mjs "helper swallows load failures" "s/console.log(\['E', basename(file), one('load failed: '/void ([ 'E', basename(file), one('load failed: '/"
  tooth_mjs "helper swallows before_agent_start failures" "s/console.log(\['E', basename(x.file), one('before_agent_start failed: '/void (['E', basename(x.file), one('before_agent_start failed: '/"
  tooth any "jq-missing guard removed" 's/if ! command -v jq >\/dev\/null 2>&1; then echo "state: degraded (jq unavailable/if false; then echo "state: degraded (jq unavailable/'
  tooth any "invalid-JSON guard removed" 's/^if ! jq -e .type == "object". "\$settings" >\/dev\/null 2>&1; then/if false; then/'
fi

echo "== $pass passed · $fail failed =="
[ "$skipped" -eq 0 ] || echo "($skipped sandbox-dependent case(s) skipped: no usable bwrap)"
[ "$fail" -eq 0 ] || exit 1
