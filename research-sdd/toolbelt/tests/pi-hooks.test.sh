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
  { grep -q 'setTimeout(() => { timedOut = true; killGroup(); }, o\.timeoutMs)' "$f" && grep -q 'process\.kill(-(child\.pid as number), "SIGKILL")' "$f" && grep -q 'detached: true' "$f"; } || echo "run-has-timeout-killing-the-process-group"
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

# --- behavior (needs Node's built-in TypeScript type stripping) -----------------------------------------
HAVE_TS=0
if command -v node >/dev/null 2>&1 && [ "$(node -p 'process.features.typescript ? 1 : 0' 2>/dev/null)" = 1 ]; then HAVE_TS=1; fi
if [ "$HAVE_TS" = 1 ]; then
  beh_out="$(node "$BEHAVIOR" 2>&1)"; beh_rc=$?
  beh_sum="$(grep -E '^[0-9]+ passed' <<<"$beh_out" | tail -1)"
  if [ "$beh_rc" = 0 ] && [ -n "$beh_sum" ]; then ok "behavior: pi-hooks-behavior.test.mjs against the real extension ($beh_sum)"
  else no "behavior: pi-hooks-behavior.test.mjs failed (rc=$beh_rc): $(grep -E '^  FAIL' <<<"$beh_out" | head -5 | tr '\n' ';')"; fi
else
  sk "behavior: this Node has no built-in TypeScript type stripping ($(node --version 2>/dev/null || echo 'node absent')); the handlers were not executed here"
fi

# --- teeth -----------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: a mutant of the extension must turn the structural check or the behavior suite red --"
  M="$TMP/mt"; mkdir -p "$M"
  # tooth NAME KIND EXPECT EXPR... — KIND "struct": the structural checks must report a label starting with EXPECT
  # (a different label would mean the mutant tripped something else); KIND "behavior": the behavior suite must exit 1
  # with a FAIL line (a crash is not a bite) when run on the mutant as RSDD_PI_HOOKS_SRC; skipped when this Node
  # cannot strip types.
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
      RSDD_PI_HOOKS_SRC="$M/$name.ts" node "$BEHAVIOR" >"$M/$name.out" 2>&1; r=$?
      if [ "$r" = 1 ] && grep -q '^  FAIL' "$M/$name.out"; then ok "teeth $name: behavior suite goes red ($(grep -m1 '^  FAIL' "$M/$name.out" | cut -c8-90))"
      else no "teeth $name: behavior suite exit $r on the mutant — THEATER"; fi
    fi
  }
  tooth child-guard-removed   struct   child-guard-first 's/^  if (process\.env\.GENTLE_PI_AGENTS_CHILD === "1") return;.*$//'
  tooth outcome-gate-removed  struct   settle-gated-on-outcome-and-continue 's/event\.outcome !== "completed" || event\.continue/false/'
  tooth injection-notified    struct   context-injected-every-run-not-notified 's/event\.systemPromptOptions\.sections\[SECTION_KEY\] = text;/ctx.ui.notify(text);/'
  tooth injected-flag         struct   context-injected-every-run-not-notified 's/event\.systemPromptOptions\.sections\[SECTION_KEY\] = text;/event.systemPromptOptions.sections[SECTION_KEY] = text; cur.injected = true;/' 's/^interface HookState {/let injected = false;\ninterface HookState {/'
  tooth run-without-timeout   struct   run-has-timeout-killing-the-process-group 's/setTimeout(() => { timedOut = true; killGroup(); }, o\.timeoutMs)/setTimeout(() => { timedOut = true; killGroup(); }, 600000)/'
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
  # behavior-only mutants: invariants a grep cannot see
  tooth child-guard-behavior  behavior - 's/^  if (process\.env\.GENTLE_PI_AGENTS_CHILD === "1") return;.*$//'
  tooth outcome-gate-behavior behavior - 's/event\.outcome !== "completed" || event\.continue/false/'
  tooth timeout-behavior      behavior - 's/setTimeout(() => { timedOut = true; killGroup(); }, o\.timeoutMs)/setTimeout(() => { timedOut = true; killGroup(); }, 600000)/'
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
  tooth inject-once           behavior - 's/event\.systemPromptOptions\.sections\[SECTION_KEY\] = text;.*$/if (!st.noticed.has("inj")) { st.noticed.add("inj"); event.systemPromptOptions.sections[SECTION_KEY] = text; }/'
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
fi

echo "== $pass passed · $fail failed · $skipped skipped =="
[ "$fail" -eq 0 ]
