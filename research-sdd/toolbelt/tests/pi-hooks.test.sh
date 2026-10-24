#!/usr/bin/env bash
# pi-hooks.test.sh — structural + mutation suite for research-sdd/install/pi/research-sdd-hooks.ts (kit issue #2123).
#
# The extension is TypeScript run by pi; its behavior is exercised headlessly by pi-hooks-behavior.test.mjs (a
# fake `pi` object and a stub kit, needs Node's built-in type stripping). THIS suite is the part that runs on every
# Node: it pins the source-level invariants that the niagara-research extension got wrong (kit issue #2128) and
# the parity of the sweep list with sweep-all.sh, and it runs the behavior suite when the Node can.
#
#   structural  child guard first · Stop-equivalent gated on outcome/continue · context injected via the system
#               prompt sections on every run (not a UI notification) · every external call bounded by a timeout ·
#               no hardcoded path · no module-level mutable state · erasable TypeScript only · transcript handed to
#               return-token-gate · pkill delegated to the kit script · SessionStart budget < 8,000 chars · sweep
#               list equal to sweep-all.sh's scripts (each one's -hook.sh wrapper).
#   behavior    pi-hooks-behavior.test.mjs against the real extension (SKIP: typed, when this Node cannot strip types).
#   --prove-teeth  every invariant has a mutant of the extension built by lib/mutant.sh; the structural check or
#               the behavior suite must go red on it.
#
# Usage: pi-hooks.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"
SUT="$KIT/install/pi/research-sdd-hooks.ts"
BEHAVIOR="$HERE/pi-hooks-behavior.test.mjs"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$BEHAVIOR" ] || { echo "FATAL: behavior suite not found: $BEHAVIOR" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || { echo "FATAL: mutant helper missing" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; skipped=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
sk(){ printf '  SKIP  %s\n' "$1"; skipped=$((skipped+1)); }

echo "== pi-hooks.test.sh =="

# checks FILE — prints one LABEL per FAILED invariant (silent = every invariant holds).
checks() {
  local f="$1" first_on guard_line n_run n_run_t hooks_src hooks_all s code
  code="$(grep -vE '^[[:space:]]*//' "$f")" # negative checks look at code, not at the comments that explain the rules
  first_on="$(grep -n 'pi\.on(' "$f" | head -1 | cut -d: -f1)"
  guard_line="$(grep -n 'process\.env\.GENTLE_PI_AGENTS_CHILD === "1"' "$f" | head -1 | cut -d: -f1)"
  { [ -n "$guard_line" ] && [ -n "$first_on" ] && [ "$guard_line" -lt "$first_on" ]; } || echo "child-guard-first"
  grep -q 'event\.outcome !== "completed" || event\.continue' "$f" || echo "settle-gated-on-outcome-and-continue"
  { grep -q 'sections\[SECTION_KEY\] = text' "$f" && ! grep -qE '(let|var) [a-zA-Z]*[iI]njected|[iI]njected = true' <<<"$code" && ! grep -q 'notify(' <<<"$code"; } || echo "context-injected-every-run-not-notified"
  { grep -q 'setTimeout(() => { timedOut = true; killGroup(); forceFinish({}); }, o\.timeoutMs)' "$f" && grep -q 'process\.kill(-(child\.pid as number), "SIGKILL")' "$f" && grep -q 'detached: true' "$f"; } || echo "run-has-timeout-killing-the-process-group"
  n_run="$(grep -c 'await run(' "$f")"; n_run_t="$(grep 'await run(' "$f" | grep -c 'timeoutMs')"
  { [ "$n_run" -ge 5 ] && [ "$n_run" = "$n_run_t" ]; } || echo "every-call-bounded-by-timeout ($n_run_t of $n_run)"
  ! grep -nE '/home/|/Users/|investigacion|niagara' <<<"$code" >/dev/null || echo "no-hardcoded-path"
  ! grep -nE '^(let|var) ' <<<"$code" >/dev/null || echo "no-module-level-mutable-state"
  for s in session_start before_agent_start agent_before_settle tool_call; do
    grep -q "pi\\.on(\"$s\"" "$f" || echo "registers-$s"
  done
  ! grep -nE '(^|[;{}] *)(export )?(const )?enum |^\s*(export )?namespace |constructor\s*\([^)]*(private|public|readonly)' <<<"$code" >/dev/null || echo "erasable-typescript-only"
  { grep -q 'transcript_path: tr\.file' "$f" && grep -q 'return-token-gate\.sh' "$f"; } || echo "transcript-handed-to-return-token-gate"
  grep -q 'hook-pretool-pkill-guard\.sh' "$f" || echo "pkill-delegated-to-kit-script"
  { grep -q '"bash_background"' "$f" && grep -q '"monitor"' "$f" && grep -q 'SHELL_TOOLS\.has(event\.toolName)' "$f"; } || echo "pkill-covers-every-shell-tool"
  grep -q 'entries: \[\.\.\.base, \.\.\.mine\]' "$f" || echo "settle-keeps-other-extensions-entries"
  grep -q 'ctx?\.mode === "print"' "$f" || echo "settle-print-mode-aware"
  { grep -q 'mkdtempSync(' "$f" && grep -q 'flag: "wx"' "$f"; } || echo "transcript-private-and-exclusive"
  { grep -qE 'MAX_INJECT_CHARS = [0-9]+;' "$f" && [ "$(grep -oE 'MAX_INJECT_CHARS = [0-9]+' "$f" | grep -oE '[0-9]+')" -lt 8000 ]; } || echo "context-budget-under-8000"
  grep -q 'const next = freshState();' "$f" || echo "state-recomputed-every-session-start"
  grep -q 'if (!cur\.corpus) return done(false);' "$f" || echo "gates-only-on-corpus-target"
  # sweep-all.sh's scripts (X.sh) <-> this file's SWEEP_HOOKS (X-hook.sh), both directions, each wrapper present
  hooks_src="$(grep -oE '"[a-z-]+-hook"' "$f" | tr -d '"' | LC_ALL=C sort -u)"
  hooks_all="$(grep -oE '\$TOOLBELT/[a-z-]+\.sh' "$KIT/toolbelt/sweep-all.sh" | sed 's|.*/||; s|\.sh$|-hook|' | LC_ALL=C sort -u)"
  { [ -n "$hooks_all" ] && [ "$hooks_src" = "$hooks_all" ]; } || echo "sweep-list-matches-sweep-all"
  for s in $hooks_src; do [ -f "$KIT/toolbelt/$s.sh" ] || echo "sweep-hook-exists-$s"; done
}

out="$(checks "$SUT")"
if [ -z "$out" ]; then ok "structural: every invariant holds on research-sdd-hooks.ts"
else no "structural: invariants broken: $(printf '%s' "$out" | tr '\n' ';')"; fi

# positive control: the sweep-all parity extraction must actually see eight scripts (a silent zero would pass trivially)
n_all="$(grep -oE '\$TOOLBELT/[a-z-]+\.sh' "$KIT/toolbelt/sweep-all.sh" | sort -u | wc -l)"
n_src="$(grep -oE '"[a-z-]+-hook"' "$SUT" | sort -u | wc -l)"
if [ "$n_all" -ge 8 ] && [ "$n_src" = "$n_all" ]; then ok "structural: parity extraction saw $n_all sweep scripts and $n_src hook wrappers (not a silent zero)"
else no "structural: parity extraction saw $n_all scripts / $n_src wrappers"; fi

# the extension file must not carry a name the gentle-ai bundle owns
case "$(basename "$SUT")" in review-*|jd-*|gentle-ai-*) no "structural: extension file name collides with a reserved prefix" ;; *) ok "structural: file name is kit-unique (research-sdd-hooks.ts)" ;; esac

# --- installer agent home (kit issue #2139 item 2) -----------------------------------------------------
# pi honours GENTLE_PI_AGENT_HOME, then PI_CODING_AGENT_DIR, then ~/.pi/agent; the extension resolves its agent home that
# way, so the installer must deploy to the same place or the skill, prompts and extension land where pi does not load them.
ADAPTERS="$KIT/install/adapters.sh"
INSTALLER="$KIT/install/research-sdd-install.sh"
# home_checks ADAPTERS-FILE — one LABEL per FAILED expectation of rsdd_field config_root (silent = all hold).
home_checks() {
  local f="$1" h="$TMP/hc-home"
  mkdir -p "$h"
  # rf FIELD HARNESS HOME [VAR=value...] — rsdd_field FIELD in a subshell with only the given pi variables set
  rf() {
    (
      set +u; export HOME="$h"; unset GENTLE_PI_AGENT_HOME PI_CODING_AGENT_DIR
      for kv in "${@:4}"; do export "${kv?}"; done
      # shellcheck source=/dev/null
      . "$f" || exit 9
      rsdd_field "$2" "$1" "${3:-$h}"
    )
  }
  r() { rf config_root "$@"; }
  rcof() { local o; o="$(rf "$@" 2>&1)"; echo "rc=$? $o"; }
  [[ "$(rcof config_root pi "$h" PI_CODING_AGENT_DIR=rel/dir)" == "rc=2 "*PI_CODING_AGENT_DIR*absolute* ]] || echo "home-relative-override-rejected"
  [[ "$(rcof config_root pi "$h" GENTLE_PI_AGENT_HOME=/)" == "rc=2 "*GENTLE_PI_AGENT_HOME*absolute* ]] || echo "home-root-override-rejected"
  [[ "$(rcof config_root pi "$h" PI_CODING_AGENT_DIR=//)" == "rc=2 "* ]] || echo "home-slashes-only-rejected"
  [ "$(rf config_root_source pi "$h" GENTLE_PI_AGENT_HOME=/x/g PI_CODING_AGENT_DIR=/x/p)" = GENTLE_PI_AGENT_HOME ] || echo "home-source-gentle"
  [ "$(rf config_root_source pi "$h" PI_CODING_AGENT_DIR=/x/p)" = PI_CODING_AGENT_DIR ] || echo "home-source-pi-coding-agent-dir"
  [ "$(rf config_root_source pi "$h")" = default ] || echo "home-source-default"
  [ "$(rf config_root_source gentle-shell "$h" PI_CODING_AGENT_DIR=/x/p)" = default ] || echo "home-source-gentle-shell-default"
  [ "$(r pi "$h")" = "$h/.pi/agent" ] || echo "home-default-unchanged"
  [ "$(r pi "$h" PI_CODING_AGENT_DIR=/x/pi-dir)" = "/x/pi-dir" ] || echo "home-pi-coding-agent-dir"
  [ "$(r pi "$h" GENTLE_PI_AGENT_HOME=/x/g PI_CODING_AGENT_DIR=/x/pi-dir)" = "/x/g" ] || echo "home-gentle-pi-agent-home-first"
  [ "$(r pi "$h" GENTLE_PI_AGENT_HOME= PI_CODING_AGENT_DIR=/x/pi-dir)" = "/x/pi-dir" ] || echo "home-empty-gentle-falls-through"
  [ "$(r pi "$h" PI_CODING_AGENT_DIR=/x/pi-dir/)" = "/x/pi-dir" ] || echo "home-trailing-slash-trimmed"
  [ "$(r gentle-shell "$h" PI_CODING_AGENT_DIR=/x/pi-dir GENTLE_PI_AGENT_HOME=/x/g)" = "$h/.gentle-shell/agent" ] || echo "home-gentle-shell-isolated"
  [ "$(r claude "$h" PI_CODING_AGENT_DIR=/x/pi-dir)" = "$h/.claude" ] || echo "home-claude-untouched"
  [ "$(r pi "$TMP/other" PI_CODING_AGENT_DIR=/x/pi-dir)" = "$TMP/other/.pi/agent" ] || echo "home-explicit-home-wins"
}
out="$(home_checks "$ADAPTERS")"
if [ -z "$out" ]; then ok "installer home: pi resolves GENTLE_PI_AGENT_HOME -> PI_CODING_AGENT_DIR -> ~/.pi/agent; gentle-shell, claude and an explicit home are unaffected"
else no "installer home: $(printf '%s' "$out" | tr '\n' ';')"; fi
# the extension and the installer must agree on the order
if grep -q 'process\.env\.GENTLE_PI_AGENT_HOME || process\.env\.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent")' "$SUT"; then
  ok "installer home: the extension's agentHome() uses the same order the installer does"
else no "installer home: the extension's agentHome() order changed - keep it equal to rsdd_field's"; fi
# end to end through the real installer (dry run): the plan names the custom agent home
e2e_home="$TMP/e2e-home"; mkdir -p "$e2e_home"
e2e="$(HOME="$e2e_home" PI_CODING_AGENT_DIR="$TMP/custom-pi" bash "$INSTALLER" --harness pi --dry-run 2>&1)"
if grep -q "INSTALL  *$TMP/custom-pi/skills/research-sdd/SKILL.md" <<<"$e2e" && ! grep -q "$e2e_home/.pi/agent" <<<"$e2e"; then
  ok "installer home: a dry-run pi install under PI_CODING_AGENT_DIR targets that directory only"
else no "installer home: dry-run did not target PI_CODING_AGENT_DIR: $(grep -m2 -E 'INSTALL|SPLICE' <<<"$e2e" | tr '\n' ';')"; fi

# --- behavior (needs Node's built-in TypeScript type stripping) -----------------------------------------
HAVE_TS=0
if command -v node >/dev/null 2>&1 && [ "$(node -p 'process.features.typescript ? 1 : 0' 2>/dev/null)" = 1 ]; then HAVE_TS=1; fi
if [ "$HAVE_TS" = 1 ]; then
  beh_out="$(node "$BEHAVIOR" 2>&1)"; beh_rc=$?
  beh_sum="$(grep -E '^== [0-9]+ passed · [0-9]+ failed ==$' <<<"$beh_out" | tail -1)"
  if [ "$beh_rc" = 0 ] && [ -n "$beh_sum" ]; then ok "behavior: pi-hooks-behavior.test.mjs against the real extension ($beh_sum)"
  else
    # name the failing case(s); a crash prints no FAIL line, so the output tail is always included (kit issue #2158: a
    # failure whose case was never captured cannot be told from a load-sensitive one)
    no "behavior: pi-hooks-behavior.test.mjs failed (rc=$beh_rc): $(grep -E '^  FAIL' <<<"$beh_out" | head -5 | tr '\n' ';') tail: $(tail -3 <<<"$beh_out" | cut -c1-200 | tr '\n' ';')"
  fi
elif [ "${RSDD_REQUIRE_NODE_TS:-}" = 1 ]; then
  no "behavior: RSDD_REQUIRE_NODE_TS=1 but this Node ($(node --version 2>/dev/null || echo 'node absent')) has no built-in TypeScript type stripping: the extension handlers were not executed (typed refusal, not a skip)"
else
  sk "behavior: this Node has no built-in TypeScript type stripping ($(node --version 2>/dev/null || echo 'node absent')); the handlers were not executed here"
fi

# --- self-invocation: RSDD_REQUIRE_NODE_TS turns the missing capability from SKIP into a typed FAIL ----------------
# A fake `node` that reports no type stripping goes first on PATH; this suite runs itself against it. A child run
# (RSDD_PI_HOOKS_SELFTEST=1) never recurses.
if [ "${RSDD_PI_HOOKS_SELFTEST:-}" != 1 ]; then
  SHIM="$TMP/shim"; mkdir -p "$SHIM"
  printf '#!/usr/bin/env bash\ncase "$*" in *typescript*) echo 0 ;; *--version*) echo v20.0.0 ;; esac\nexit 0\n' > "$SHIM/node"
  chmod +x "$SHIM/node"
  st_out="$(PATH="$SHIM:$PATH" RSDD_PI_HOOKS_SELFTEST=1 RSDD_REQUIRE_NODE_TS=1 bash "${BASH_SOURCE[0]}" 2>&1)"; st_rc=$?
  if [ "$st_rc" = 1 ] && grep -q '^  FAIL  behavior: RSDD_REQUIRE_NODE_TS=1 but this Node (v20.0.0)' <<<"$st_out" && grep -qE '^== [0-9]+ passed · [1-9][0-9]* failed ==$' <<<"$st_out"; then
    ok "require-node-ts: flag set + a Node without type stripping -> typed FAIL line, exit 1"
  else no "require-node-ts: flag set did not fail typed (rc=$st_rc): $(tail -3 <<<"$st_out" | tr '\n' ';')"; fi
  st_out="$(PATH="$SHIM:$PATH" RSDD_PI_HOOKS_SELFTEST=1 RSDD_REQUIRE_NODE_TS='' bash "${BASH_SOURCE[0]}" 2>&1)"; st_rc=$?
  if [ "$st_rc" = 0 ] && grep -q '^  SKIP  behavior: this Node has no built-in TypeScript type stripping' <<<"$st_out"; then
    ok "require-node-ts: flag unset + a Node without type stripping -> SKIP, exit 0"
  else no "require-node-ts: flag unset did not skip (rc=$st_rc): $(tail -3 <<<"$st_out" | tr '\n' ';')"; fi
  if [ "$HAVE_TS" = 1 ]; then
    # the behavior suite itself, run on this Node with type stripping switched off
    m_out="$(RSDD_REQUIRE_NODE_TS=1 node --no-experimental-strip-types "$BEHAVIOR" 2>&1)"; m_rc=$?
    if [ "$m_rc" = 1 ] && grep -q '^  FAIL  RSDD_REQUIRE_NODE_TS=1 but Node' <<<"$m_out"; then ok "require-node-ts: the .mjs suite fails typed when the flag is set and stripping is off"
    else no "require-node-ts: the .mjs suite did not fail typed (rc=$m_rc): $(tail -2 <<<"$m_out" | tr '\n' ';')"; fi
    m_out="$(RSDD_REQUIRE_NODE_TS='' node --no-experimental-strip-types "$BEHAVIOR" 2>&1)"; m_rc=$?
    if [ "$m_rc" = 0 ] && grep -q '^SKIP: this Node' <<<"$m_out"; then ok "require-node-ts: the .mjs suite still SKIPs when the flag is unset"
    else no "require-node-ts: the .mjs suite did not skip (rc=$m_rc)"; fi
  else
    sk "require-node-ts: the .mjs self-invocation needs a Node with type stripping to switch it off"
  fi
fi

# --- teeth -----------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: a mutant of the extension must turn the structural check or the behavior suite red --"
  M="$TMP/mt"; mkdir -p "$M"
  # tooth NAME KIND EXPECT EXPR... — KIND "struct": the structural checks must report a label starting with EXPECT
  # (a different label would mean the mutant tripped something else); KIND "behavior": the behavior suite must exit 1
  # with a FAIL line (a crash is not a bite) when run on the mutant as RSDD_PI_HOOKS_SRC; skipped when this Node
  # cannot strip types.
  # bite_line OUT RC — prints the first FAIL case when a behavior run on a mutant genuinely BIT: exit 1 and a FAIL line
  # that is not the suite's own "uncaught exception" line. A crash is not a bite (CLAUDE.md §4: a wrong-reason failure).
  bite_line() { [ "$2" = 1 ] && grep '^  FAIL' "$1" | grep -v 'uncaught exception' | head -1; }
  # controls for the predicate itself
  printf '  PASS  a\n  FAIL  uncaught exception, remaining cases not run — Error: x\n' > "$M/ctl-crash.out"
  printf '  FAIL  uncaught exception, remaining cases not run — Error: x\n  FAIL  a real case — detail\n' > "$M/ctl-both.out"
  if [ -z "$(bite_line "$M/ctl-crash.out" 1)" ]; then ok "teeth predicate: a crash-only run (uncaught-exception FAIL line) is not a bite"
  else no "teeth predicate: an uncaught-exception FAIL line counted as a bite - a crashing mutant would pass as caught"; fi
  if [ -n "$(bite_line "$M/ctl-both.out" 1)" ] && [ -z "$(bite_line "$M/ctl-both.out" 0)" ]; then ok "teeth predicate: a real FAIL line with exit 1 is a bite; exit 0 never is"
  else no "teeth predicate: a real FAIL line / exit code was not honoured"; fi
  # Behavior runs are wait-dominated (~28 s wall for ~3 s CPU each: the suite drives real process timeouts), so the ~40
  # behavior teeth run serially took longer than the flake hunt's 900 s per-suite bound and every --prove-teeth run
  # timed out (kit issue #2248). They run through the shared lib/mutant.sh job batch (MUTANT_JOBS at a time, kit issue
  # #2331); each is judged by behavior_verdict after all of them finished, in declaration order. A struct tooth is
  # still judged at once.
  mutant_bootstrap mutant_sed mutant_jobs_begin mutant_job mutant_jobs_end || exit 2
  mkdir "$M/jobs" && mutant_jobs_begin "$M/jobs" || exit 2
  # behavior_verdict NAME RC OUT — PASS/FAIL for one finished behavior tooth from its output and exit code.
  behavior_verdict() {
    local name="$1" r="$2" out="$3"
    if [ -n "$(bite_line "$out" "$r")" ]; then ok "teeth $name: behavior suite goes red ($(bite_line "$out" "$r" | cut -c8-90))"
    else no "teeth $name: behavior suite exit $r on the mutant — THEATER (tail: $(tail -2 "$out" | cut -c1-160 | tr '\n' ';'))"; fi
  }
  tooth() {
    local name="$1" kind="$2" expect="$3" a=() e r
    shift 3
    for e in "$@"; do a+=(-e "$e"); done
    if ! MUTANT_SYNTAX=none mutant_sed "$SUT" "$M/$name.ts" "${a[@]}" >/dev/null 2>&1; then no "teeth $name: mutant could not be built (pattern absent / refused)"; return; fi
    if [ "$kind" = struct ]; then
      r="$(checks "$M/$name.ts")"
      if grep -q "^$expect" <<<"$r"; then ok "teeth $name: structural check '$expect' goes red"
      else no "teeth $name: expected structural label '$expect', got [$(printf '%s' "$r" | tr '\n' ';')] — THEATER"; fi
    else
      if [ "$HAVE_TS" != 1 ]; then sk "teeth $name: needs Node type stripping to run the behavior suite on the mutant"; return; fi
      mutant_job "$name" env RSDD_PI_HOOKS_SRC="$M/$name.ts" node "$BEHAVIOR" || exit 2
    fi
  }
  tooth child-guard-removed   struct   child-guard-first 's/^  if (process\.env\.GENTLE_PI_AGENTS_CHILD === "1") return;.*$//'
  tooth outcome-gate-removed  struct   settle-gated-on-outcome-and-continue 's/event\.outcome !== "completed" || event\.continue/false/'
  tooth injection-notified    struct   context-injected-every-run-not-notified 's/event\.systemPromptOptions\.sections\[SECTION_KEY\] = text;/ctx.ui.notify(text);/'
  tooth injected-flag         struct   context-injected-every-run-not-notified 's/event\.systemPromptOptions\.sections\[SECTION_KEY\] = text;/event.systemPromptOptions.sections[SECTION_KEY] = text; cur.injected = true;/' 's/^interface HookState {/let injected = false;\ninterface HookState {/'
  tooth run-without-timeout   struct   run-has-timeout-killing-the-process-group 's/setTimeout(() => { timedOut = true; killGroup(); forceFinish({}); }, o\.timeoutMs)/setTimeout(() => { timedOut = true; killGroup(); forceFinish({}); }, 600000)/'
  tooth call-without-timeout  struct   every-call-bounded-by-timeout 's/{ cwd: st\.target, timeoutMs }/{ cwd: st.target }/'
  tooth hardcoded-path        struct   no-hardcoded-path 's|^const SECTION_KEY = |const KIT_HARD = "/home/cristian/investigacion"; const SECTION_KEY = |'
  tooth module-state          struct   no-module-level-mutable-state 's|^const SECTION_KEY = |let retroBlockedOnce = false; const SECTION_KEY = |'
  tooth settle-unregistered   struct   registers-agent_before_settle 's/pi\.on("agent_before_settle"/pi.on("agent_settled"/'
  tooth enum-introduced       struct   erasable-typescript-only 's|^const SECTION_KEY = |enum Mode { A } const SECTION_KEY = |'
  tooth transcript-dropped    struct   transcript-handed-to-return-token-gate 's/transcript_path: tr\.file/transcript_pathX: tr.file/'
  tooth pkill-inline          struct   pkill-delegated-to-kit-script 's/hook-pretool-pkill-guard\.sh/inline-guard.sh/'
  tooth budget-raised         struct   context-budget-under-8000 's/MAX_INJECT_CHARS = 7900/MAX_INJECT_CHARS = 9000/'
  tooth state-kept            struct   state-recomputed-every-session-start 's/const next = freshState();/const next = st;/'
  tooth corpus-gate-removed   struct   gates-only-on-corpus-target 's/if (!cur\.corpus) return done(false);//'
  tooth sweep-hook-dropped    struct   sweep-list-matches-sweep-all 's/"sweep-tools-hook", //'
  tooth group-kill-dropped    struct   run-has-timeout-killing-the-process-group 's/detached: true/detached: false/'
  tooth entries-replaced      struct   settle-keeps-other-extensions-entries 's/entries: \[\.\.\.base, \.\.\.mine\]/entries: [...mine]/'
  tooth shell-tools-narrowed  struct   pkill-covers-every-shell-tool 's/SHELL_TOOLS\.has(event\.toolName)/event.toolName === "bash"/'
  tooth transcript-predictable struct  transcript-private-and-exclusive 's/flag: "wx"/flag: "w"/'
  # installer-home mutants (adapters.sh): home_checks must name the label that broke
  htooth() {
    local name="$1" expect="$2" r; shift 2
    local a=() e; for e in "$@"; do a+=(-e "$e"); done
    if ! MUTANT_SYNTAX=none mutant_sed "$ADAPTERS" "$M/$name.sh" "${a[@]}" >/dev/null 2>&1; then no "teeth $name: mutant could not be built (pattern absent / refused)"; return; fi
    r="$(home_checks "$M/$name.sh")"
    if grep -q "^$expect" <<<"$r"; then ok "teeth $name: installer-home check '$expect' goes red"
    else no "teeth $name: expected installer-home label '$expect', got [$(printf '%s' "$r" | tr '\n' ';')] - THEATER"; fi
  }
  htooth home-override-dropped  home-pi-coding-agent-dir     's/if \[ "\$harness" = pi \] \&\& \[ "\$home" = "\${HOME:-}" \]; then/if false; then/'
  htooth home-order-swapped     home-gentle-pi-agent-home-first 's/src=GENTLE_PI_AGENT_HOME; override="\$GENTLE_PI_AGENT_HOME"/src=PI_CODING_AGENT_DIR; override="$PI_CODING_AGENT_DIR"/'
  htooth home-leaks-to-gentle   home-gentle-shell-isolated   's/if \[ "\$harness" = pi \] \&\& \[ "\$home" = "\${HOME:-}" \]; then/if [ "$harness" != claude ] \&\& [ "$home" = "${HOME:-}" ]; then/'
  htooth home-ignores-explicit  home-explicit-home-wins      's/ \&\& \[ "\$home" = "\${HOME:-}" \]; then/; then/'
  htooth home-relative-accepted home-relative-override-rejected 's/\/?\*) root="\$trimmed" ;;/*) root="$trimmed" ;;/'
  htooth home-source-lies       home-source-gentle            's/src=GENTLE_PI_AGENT_HOME; override=/src=default; override=/'
  htooth home-slash-kept        home-trailing-slash-trimmed  's/local trimmed=.*$/local trimmed="$override"/'
  # behavior-only mutants: invariants a grep cannot see
  tooth child-guard-behavior  behavior - 's/^  if (process\.env\.GENTLE_PI_AGENTS_CHILD === "1") return;.*$//'
  tooth outcome-gate-behavior behavior - 's/event\.outcome !== "completed" || event\.continue/false/'
  tooth timeout-behavior      behavior - 's/setTimeout(() => { timedOut = true; killGroup(); forceFinish({}); }, o\.timeoutMs)/setTimeout(() => { timedOut = true; killGroup(); forceFinish({}); }, 600000)/'
  tooth group-kill-behavior   behavior - 's/process\.kill(-(child\.pid as number), "SIGKILL")/process.kill(child.pid as number, "SIGKILL")/'
  tooth entries-behavior      behavior - 's/entries: \[\.\.\.base, \.\.\.mine\]/entries: [...mine]/'
  tooth gate-exit-ignored     behavior - 's/if (r\.code !== 0) {$/if (false) {/'
  tooth gate-stderr-ignored   behavior - 's/const deg = r\.stderr\.split("\\n")\.find((l) => \/branch=degraded\/\.test(l));/const deg = "";/'
  tooth guard-crash-allowed   behavior - 's/if (r\.code !== 0) return degraded(/if (false) return degraded(/'
  tooth guard-unknown-allowed behavior - 's/return degraded("unrecognised guard output");/return undefined;/'
  tooth missing-script-unnoticed behavior - 's/if (!existsSync(script)) mine\.push(\.\.\.noticeOnce("token-missing"/if (false) mine.push(...noticeOnce("token-missing"/'
  tooth transcript-not-removed behavior - 's/} finally { if (tr) rmSync(tr\.dir, { recursive: true, force: true }); }/} finally { void 0; }/'
  tooth final-cap-removed     behavior - 's/const body = sweep\.length > room ?/const body = false ?/'
  tooth notice-cap-removed    behavior - 's/if (st\.notices\.length < MAX_NOTICES) st\.notices\.push(msg\.slice(0, MAX_NOTICE_CHARS));/st.notices.push(msg);/' 's/\.slice(0, MAX_NOTICES)\.join/.join/'
  tooth tried-unbounded       behavior - 's/const shown = st\.tried\.slice(0, 4)/const shown = st.tried.slice(0, 400)/'
  tooth failure-not-surfaced  behavior - 's/try { ctx?\.ui?\.notify?\.(msg, "error"); } catch { \/\* no UI in this mode \*\/ }//' 's/if (st\.surface\.length < 3) st\.surface\.push(msg);//'
  tooth first-run-blocks      behavior - 's/envMs("RSDD_PI_SWEEP_WAIT_MS", 3000)/600000/'
  tooth monitor-unguarded     behavior - 's/new Set(\["bash", "bash_background", "monitor"\])/new Set(["bash"])/'
  tooth no-forced-resolve     behavior - 's/FORCE_RESOLVE_MS = 500;/FORCE_RESOLVE_MS = 600000;/'
  tooth ask-always-blocks     behavior - 's/verdict\.permissionDecision === "ask" \&\& ctx?\.hasUI/false \&\& ctx?.hasUI/'
  tooth inject-once           behavior - 's/event\.systemPromptOptions\.sections\[SECTION_KEY\] = text;.*$/if (!st.noticed.has("inj")) { st.noticed.add("inj"); event.systemPromptOptions.sections[SECTION_KEY] = text; }/'
  tooth start-sha-ignored     behavior - 's/await recordSessionSha(cur, cur\.startSha);/await recordSessionSha(cur);/'
  tooth fallback-sha-silent   behavior - 's/^  if (!cur\.startSha) pushNotice.*$//'
  tooth corpus-late-ignored   behavior - 's/if (cur\.corpus || !cur\.target || !isCorpus(cur\.target)) return;/return;/'
  tooth block-once-removed    behavior - 's/cur\.retroBlocked = true;//'
  tooth token-block-once      behavior - 's/cur\.tokenBlocked = true;//'
  tooth silent-missing-script behavior - 's/degraded: `script missing at \${script}`/degraded: ""/'
  tooth no-truncation         behavior - 's/total > budget \&\& body\.length > slice/false/' 's/if (out\.length > MAX_CONTEXT_CHARS)/if (false)/' 's/const body = sweep\.length > room ?/const body = false ?/'
  tooth silent-no-kit         behavior - 's/if (!st\.kit) return degradedKitText(st);/if (!st.kit) return "";/'
  tooth handler-rethrows      behavior - 's/^      const msg = `Research-SDD hooks DEGRADED: \${name} failed/      throw e; const msg = `Research-SDD hooks DEGRADED: ${name} failed/'
  tooth pkill-fails-open      behavior - 's/if (!script || !existsSync(script)) return degraded(/if (false) return degraded(/' 's/if (r\.code !== 0) return degraded(/if (false) return degraded(/'
  tooth sha-overwritten       behavior - 's/try { if (existsSync(file) \&\& statSync(file)\.size > 0) return; } catch { \/\* fall through and rewrite \*\/ }//'
  tooth no-launcher-lookup    behavior - 's/for (const key of \["Kit checkout", "Kit path"\])/for (const key of [])/'
  tooth token-no-notice       behavior - 's/mine\.push(\.\.\.noticeOnce("token-transcript",[^;]*;/void 0;/'
  tooth ask-not-blocked       behavior - 's/verdict\.permissionDecision === "deny" || verdict\.permissionDecision === "ask"/verdict.permissionDecision === "deny"/'
  tooth print-mode-blind      behavior - 's/ctx?\.mode === "print"/ctx?.mode === "pr1nt"/'
  tooth print-gates-run       behavior - 's/^      if (isPrint(ctx)) {$/      if (false) {/'
  tooth print-guard-silent    behavior - 's/if (isPrint(ctx)) printNotice(msg);//'
  tooth print-surface-dropped behavior - 's/for (const m of cur\.surface\.splice(0)) printNotice(m);//'
  tooth print-notice-silent   behavior - 's/try { process\.stderr\.write(`research-sdd-hooks: \${msg}\\n`); }/try { void msg; }/'
  tooth print-not-evaluated-unsaid behavior - 's/printNotice("retro\/return-token gates NOT evaluated/void ("retro\/return-token gates NOT evaluated/'
  mutant_jobs_end fail behavior_verdict "teeth "
fi

echo "skipped: $skipped"
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
