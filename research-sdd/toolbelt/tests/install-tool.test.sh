#!/usr/bin/env bash
# install-tool.test.sh — regression/characterization harness for install-tool.sh.
#
# WHY THIS SHAPE. install-tool.sh had NO test suite. This harness pins its
# observable contract (exit codes + the CALLS argv log + INSTALLED-TOOLS.md
# status) so a future edit that breaks idempotency, the install/fail split, or
# --check/--list is caught. Every case here is GREEN against the current script
# — it characterizes correct behavior; the teeth (below) are what stop it from
# being characterization theater.
#
# HERMETIC SANDBOX. Each case runs the SUT under a FULLY CONTROLLED PATH that
# contains ONLY "$box/bin" — never the host PATH. That box holds (a) argv-logging
# stubs for the external managers a case exercises (dotnet/brew/apt-get/sudo, …),
# and (b) symlinks to the REAL coreutils install-tool.sh actually invokes on the
# covered paths (dirname for HERE=, date for ts()/log(), grep+sort for --list).
# A tool is PRESENT only because its stub is dropped in the box; a tool a case
# wants ABSENT is guaranteed absent because nothing of that name exists in the
# controlled PATH — determinism comes from the box, NOT from what the host does
# or doesn't have installed. GOTCHA baked in: `PATH=x cmd` makes bash resolve
# `cmd` itself via the assigned PATH, so we invoke bash by ABSOLUTE path
# ($BASH_BIN) — otherwise `bash` would not be found in the hermetic PATH and the
# SUT would never run. HOME is redirected to "$box/home" so the
# `$HOME/.dotnet/tools/ilspycmd` presence check stays controlled too. A real
# installer is NEVER executed.
#
# PHANTOM-BUG NOTE (read before "fixing" line 106). An earlier review believed
# the ilspycmd recipe reinstalled a present tool, reading the guard
#     have ilspycmd || have "$HOME/.dotnet/tools/ilspycmd" && { log …already; exit 0; }
# as  have X || ( have Y && { … } )  — i.e. assuming && binds tighter than ||.
# In bash, && and || have EQUAL precedence and are LEFT-associative, so it
# actually parses  ( have X || have Y ) && { log …already; exit 0; } , which is
# exactly the intended idempotent guard: if EITHER check is present, log
# `already` and exit 0; only when BOTH are absent does it fall through to
# `dotnet tool install`. The line is CORRECT and is left UNCHANGED. Case 1
# proves it stays idempotent; the teeth mutation reconstructs the buggy grouped
# form the review imagined and proves that form WOULD reinstall — so the
# idempotency assertion genuinely depends on the real (A||B)&&C grouping.
#
# Out of scope for this first suite (deliberately not covered): blutter and pycdc
# (git-clone + cmake/venv heavy builds), apktool (install-tool.sh:96) and
# uncompyle6 (:104), and the *) generic fallthrough.
#
# Usage: install-tool.test.sh                (run the suite)
#        install-tool.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error (SUT or a
#       required tool missing).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../install-tool.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }

# --- resolve the real binaries ONCE, in the UNRESTRICTED env, before we restrict.
#     bash by absolute path (so the hermetic PATH can't hide it); coreutils that the
#     covered dispatch paths actually invoke.  type -P skips functions/aliases.
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not found on PATH" >&2; exit 2; }
CORE_UTILS=(dirname date grep sort mktemp mkdir mv rm cp)   # dirname:HERE=  date:ts()/log()  grep,sort:--list  mktemp/mkdir/mv/rm/cp:java recipes; cp:stub_download materialise
CORE_PATHS=()
for u in "${CORE_UTILS[@]}"; do
  p="$(type -P "$u")"; [ -n "$p" ] || { echo "FATAL: required coreutil '$u' not on PATH" >&2; exit 2; }
  CORE_PATHS+=("$p")
done

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0

# Shared fixture for java recipe download stubs — a small placeholder file.
# sha256sum is always STUBBED per-case, so the actual content is irrelevant.
FIXTURE_JAR="$ROOT/fixture.jar"
printf 'RSDD_TEST_FIXTURE_JAR\n' > "$FIXTURE_JAR"
ok() { printf '  PASS  %-46s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-46s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# --- sandbox + stub helpers ------------------------------------------------
# mkbox <name> : fresh isolated case dir. bin/ gets the real-coreutil symlinks so
#   the SUT can start and run --list hermetically; home/ is the redirected HOME; a
#   copy of the SUT lives inside so INSTALLED-TOOLS.md is written into tmp. Echoes dir.
mkbox() {
  local box="$ROOT/$1" i
  mkdir -p "$box/bin" "$box/home"
  cp "$SUT" "$box/install-tool.sh"
  : > "$box/calls.log"
  for i in "${!CORE_UTILS[@]}"; do ln -s "${CORE_PATHS[$i]}" "$box/bin/${CORE_UTILS[$i]}"; done
  printf '%s' "$box"
}

# stub <box> <name> <exit> : PATH-front executable named <name> that appends its
#   argv to the box CALLS log and exits <exit>. Doubles as a presence stub for
#   `have <name>` (which uses `command -v`, so the stub records nothing unless a
#   recipe actually executes it).
stub() {
  local box="$1" name="$2" code="$3"
  {
    # Absolute-bash shebang: the hermetic PATH has no `env`, so `#!/usr/bin/env bash`
    # would fail to exec the stub (and silently look like an install failure).
    printf '#!%s\n' "$BASH_BIN"
    printf 'echo "%s $*" >> "%s/calls.log"\n' "$name" "$box"
    printf 'exit %s\n' "$code"
  } > "$box/bin/$name"
  chmod +x "$box/bin/$name"
}

# stub_download <box> <name> <exit> [fixture]: like stub(), but if <fixture> is given
#   the stub also copies <fixture> to the path found after -o or -O in its argv.
#   This lets curl/wget fakes materialise a downloaded file without hitting the network.
#   When fixture is omitted no file is written — use that to simulate a failed download.
stub_download() {
  local box="$1" name="$2" code="$3" fixture="${4:-}"
  {
    printf '#!%s\n' "$BASH_BIN"
    printf 'echo "%s $*" >> "%s/calls.log"\n' "$name" "$box"
    if [ -n "$fixture" ]; then
      printf 'fixture=%s\n' "$(printf '%q' "$fixture")"
      printf 'prev=""\n'
      printf 'for arg; do\n'
      printf '  if [ "$prev" = "-o" ] || [ "$prev" = "-O" ]; then cp "$fixture" "$arg"; break; fi\n'
      printf '  prev="$arg"\n'
      printf 'done\n'
    fi
    printf 'exit %s\n' "$code"
  } > "$box/bin/$name"
  chmod +x "$box/bin/$name"
}

# run <box> <args...> : invoke the SUT copy with a HERMETIC PATH ("$box/bin" ONLY)
#   and HOME redirected into the box. bash is called by ABSOLUTE path so the empty
#   host PATH cannot hide the interpreter. Captures combined output in OUT, exit in RC.
run() {
  local box="$1"; shift
  # RESEARCH_SDD_TOOL_HOME is explicitly forced to the sandbox path so any exported
  # value in the caller's environment cannot escape the hermetic box (defect 3 guard).
  OUT="$(PATH="$box/bin" HOME="$box/home" RESEARCH_SDD_TOOL_HOME="$box/home/.local/share/research-sdd-tools" "$BASH_BIN" "$box/install-tool.sh" "$@" 2>&1)"; RC=$?
}

calls()     { cat "$1/calls.log" 2>/dev/null; }
logstatus() { grep -o 'already\|installed\|failed\|needs-approval\|incompatible' "$1/INSTALLED-TOOLS.md" 2>/dev/null | tail -1; }

# assert_present <box> <label> <want_exit> <want_status> : a "was-already-present"
#   outcome — expected exit, NO installer invoked (CALLS has no `install`), status recorded.
assert_present() {
  local box="$1" label="$2" wexit="$3" wstatus="$4"
  if [ "$RC" = "$wexit" ] && ! grep -q 'install' "$box/calls.log" && [ "$(logstatus "$box")" = "$wstatus" ]; then
    ok "$label" "(exit $RC · no install · $wstatus)"
  else
    no "$label" "exit=$RC(want $wexit) calls=[$(calls "$box")] status=$(logstatus "$box")(want $wstatus)"
  fi
}

# assert_installed <box> <label> <want_exit> <want_status> <needle> : an install was
#   attempted — CALLS contains <needle>, with the expected exit and status.
assert_installed() {
  local box="$1" label="$2" wexit="$3" wstatus="$4" needle="$5"
  if [ "$RC" = "$wexit" ] && grep -q "$needle" "$box/calls.log" && [ "$(logstatus "$box")" = "$wstatus" ]; then
    ok "$label" "(exit $RC · $needle · $wstatus)"
  else
    no "$label" "exit=$RC(want $wexit) calls=[$(calls "$box")] status=$(logstatus "$box")(want $wstatus)"
  fi
}

# assert_exit <label> <want_exit> : bare exit-code assertion (invalid-input / --check).
assert_exit() {
  local label="$1" wexit="$2"
  if [ "$RC" = "$wexit" ]; then ok "$label" "(exit $RC)"; else no "$label" "exit=$RC(want $wexit)"; fi
}

echo "== install-tool.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — IDEMPOTENCY (flagship). ilspycmd already on PATH → have ilspycmd TRUE →
#     the (A||B)&&C guard logs `already` and exits 0; `dotnet tool install` is
#     NEVER run. This is the exact case the phantom review thought reinstalled.
box="$(mkbox c1-ilspycmd-present)"
stub "$box" ilspycmd 0
stub "$box" dotnet 0
run "$box" ilspycmd
assert_present "$box" "1 idempotency: ilspycmd on PATH" 0 already

# 2 — IDEMPOTENCY via the SECOND check. ilspycmd NOT on PATH, but
#     $HOME/.dotnet/tools/ilspycmd exists → have Y TRUE → still `already`, no install.
#     dotnet is stubbed so a regression that fell through would RECORD a reinstall.
box="$(mkbox c2-ilspycmd-dotnet-tools)"
mkdir -p "$box/home/.dotnet/tools"
printf '#!%s\nexit 0\n' "$BASH_BIN" > "$box/home/.dotnet/tools/ilspycmd"   # only `have`-probed, never exec'd
chmod +x "$box/home/.dotnet/tools/ilspycmd"
stub "$box" dotnet 0
run "$box" ilspycmd
assert_present "$box" "2 idempotency: \$HOME/.dotnet/tools path" 0 already

# 3 — INSTALL success. ilspycmd absent everywhere (hermetic PATH guarantees it),
#     `dotnet` stub exits 0 → both guard checks FALSE → `dotnet tool install` runs, `installed`.
box="$(mkbox c3-install-ok)"
stub "$box" dotnet 0
run "$box" ilspycmd
assert_installed "$box" "3 install: dotnet ok → installed" 0 installed "tool install"

# 4 — INSTALL failure. Same, but `dotnet` stub exits non-zero → exit 4, `failed`.
box="$(mkbox c4-install-fail)"
stub "$box" dotnet 1
run "$box" ilspycmd
assert_installed "$box" "4 install: dotnet fails → exit 4" 4 failed "tool install"

# 5 — brew_install SUCCESS path (install-tool.sh:50). brew present, yara ABSENT,
#     `brew` stub exits 0 for install → `brew install yara` runs, exit 0, `installed`.
#     This is the common real-world outcome that cases 8/9 do not exercise.
box="$(mkbox c5-brew-install-ok)"
stub "$box" brew 0
run "$box" yara
assert_installed "$box" "5 brew_install: yara absent → installed" 0 installed "brew install yara"

# 6 — --check probe. present cmd → 0 ; absent cmd → 1 (no install path at all).
box="$(mkbox c6-check)"
stub "$box" some_present_cmd 0
run "$box" --check some_present_cmd
assert_exit "6a --check <present> → 0" 0
run "$box" --check zzz_absent_tool_9f3k
assert_exit "6b --check <absent> → 1" 1

# 7 — --list. exit 0 and the known recipe names are present (ilspycmd + yara).
box="$(mkbox c7-list)"
run "$box" --list
if [ "$RC" = 0 ] && grep -qx 'ilspycmd' <<<"$OUT" && grep -qx 'yara' <<<"$OUT" && grep -qx 'frida' <<<"$OUT"; then
  ok "7 --list → 0, names ilspycmd + yara + frida" "(exit $RC)"
else
  no "7 --list → 0, names ilspycmd + yara + frida" "exit=$RC out=[$OUT]"
fi

# 8 — IDEMPOTENCY on a brew recipe. brew present + yara present → brew_install
#     short-circuits on `have yara` → `already`, exit 0, NO `brew install`.
box="$(mkbox c8-yara-present)"
stub "$box" brew 0
stub "$box" yara 0
run "$box" yara
assert_present "$box" "8 idempotency: yara present (brew)" 0 already

# 9 — NEEDS-APPROVAL. jadx with brew install failing → falls to sudo_n apt-get;
#     `sudo -n true` FAILS → sudo_n returns 100 → the recipe records needs-approval
#     and exits 3 (empirically pinned). apt-get is stubbed but never reached.
box="$(mkbox c9-jadx-approval)"
stub "$box" brew 1
stub "$box" sudo 1
stub "$box" apt-get 0
run "$box" jadx
if [ "$RC" = 3 ] && [ "$(logstatus "$box")" = needs-approval ]; then
  ok "9 needs-approval: jadx sudo -n fails → 3" "(exit $RC · needs-approval)"
else
  no "9 needs-approval: jadx sudo -n fails → 3" "exit=$RC status=$(logstatus "$box")"
fi

# 10 — INVALID INPUT. Exit codes empirically pinned against the real script.
#      (a) no args → falls past the option case, hits RECIPE="${1:?…}" → exit 1.
#      (b) --check with no cmd → have "${1:?cmd}" with $1 unset → exit 1.
box="$(mkbox c10-invalid)"
run "$box"
assert_exit "10a no args → 1 (\${1:?})" 1
run "$box" --check
assert_exit "10b --check no cmd → 1 (\${1:?})" 1

# 11 — frida recipe INSTALL success (analogous to yara/case 5). frida + frida-trace
#      absent (hermetic PATH guarantees it), `pipx` stub present and `pipx install
#      frida-tools` exits 0 → recipe records `installed`, exit 0. python3/pip is
#      never reached because `have pipx` short-circuits the pipx-bootstrap.
box="$(mkbox c11-frida-install-ok)"
stub "$box" pipx 0
run "$box" frida
assert_installed "$box" "11 frida: pipx install → installed" 0 installed "install frida-tools"

# 12 — frida recipe INSTALL failure. `pipx` present but `pipx install` exits non-zero →
#      the if-guard's else runs → `failed`, exit 4.
box="$(mkbox c12-frida-install-fail)"
stub "$box" pipx 1
run "$box" frida
assert_installed "$box" "12 frida: pipx install fails → exit 4" 4 failed "install frida-tools"

# 13 — frida recipe IDEMPOTENCY. Both CLIs present → the `have frida && have frida-trace`
#      guard logs `already` and exits 0; `pipx` is stubbed but NEVER invoked (no install).
box="$(mkbox c13-frida-present)"
stub "$box" frida 0
stub "$box" frida-trace 0
stub "$box" pipx 0
run "$box" frida
assert_present "$box" "13 frida idempotency: both CLIs present" 0 already

# 14 — --help → exit 0, usage printed, NO ledger write.
#      The SUT currently has no --help handler; the flag falls through as a
#      recipe name, reaches the *) branch, and brew install --help exits 0,
#      writing a bogus "installed" row. These cases are RED until the guard lands.
box="$(mkbox c14-help)"
stub "$box" brew 0   # sentinel: if the flag leaks to *), brew exits 0 and log() fires
run "$box" --help
_no_ledger=$([ ! -f "$box/INSTALLED-TOOLS.md" ] && echo yes || echo no)
_has_usage=$(printf '%s' "$OUT" | grep -qi 'install-tool' && echo yes || echo no)
if [ "$RC" = 0 ] && [ "$_no_ledger" = yes ] && [ "$_has_usage" = yes ]; then
  ok "14 --help → exit 0, usage, no ledger" "(exit $RC)"
else
  no "14 --help → exit 0, usage, no ledger" "exit=$RC no_ledger=$_no_ledger has_usage=$_has_usage"
fi

# 15 — -h → exit 0, usage printed, NO ledger write (same guard, short alias).
box="$(mkbox c15-h)"
stub "$box" brew 0
run "$box" -h
_no_ledger=$([ ! -f "$box/INSTALLED-TOOLS.md" ] && echo yes || echo no)
_has_usage=$(printf '%s' "$OUT" | grep -qi 'install-tool' && echo yes || echo no)
if [ "$RC" = 0 ] && [ "$_no_ledger" = yes ] && [ "$_has_usage" = yes ]; then
  ok "15 -h → exit 0, usage, no ledger" "(exit $RC)"
else
  no "15 -h → exit 0, usage, no ledger" "exit=$RC no_ledger=$_no_ledger has_usage=$_has_usage"
fi

# 16 — unknown leading-dash flag → exit 2, NO ledger write.
#      brew stubbed exit 0: reaching *) would let brew install --foo succeed and
#      write a bogus "installed" row — that is the regression this case guards.
box="$(mkbox c16-unknown-flag)"
stub "$box" brew 0
run "$box" --foo
_no_ledger=$([ ! -f "$box/INSTALLED-TOOLS.md" ] && echo yes || echo no)
if [ "$RC" = 2 ] && [ "$_no_ledger" = yes ]; then
  ok "16 unknown flag → exit 2, no ledger" "(exit $RC)"
else
  no "16 unknown flag → exit 2, no ledger" "exit=$RC no_ledger=$_no_ledger out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# Java download recipes (vineflower, cfr, procyon) — cases 17-25.
#
# HARNESS EXTENSION: stub_download (defined above) creates a curl/wget stub that
# writes a fixture file to the -o/-O destination so the recipe's filesystem ops run
# for real without hitting the network. sha256sum is STUBBED per-case (exit 0 =
# hash matches; exit 1 = mismatch). mktemp/mkdir/mv/rm are real coreutils (CORE_UTILS).

# 17 — vineflower: fresh install → curl downloads, sha256 ok → installed, DEST created.
box="$(mkbox c17-vf-fresh)"
stub_download "$box" curl 0 "$FIXTURE_JAR"
stub "$box" wget 1
stub "$box" sha256sum 0
DEST_VF="$box/home/.local/share/research-sdd-tools/java/vineflower.jar"
run "$box" vineflower
if [ "$RC" = 0 ] && grep -q "curl" "$box/calls.log" && [ "$(logstatus "$box")" = installed ] && [ -f "$DEST_VF" ] && [ -s "$DEST_VF" ] && cmp -s "$DEST_VF" "$FIXTURE_JAR"; then
  ok "17 vineflower: fresh install → downloaded, installed" "(exit $RC · curl · installed · DEST non-empty · matches fixture)"
else
  no "17 vineflower: fresh install" "exit=$RC curl=$(grep -c curl "$box/calls.log" 2>/dev/null || echo 0) status=$(logstatus "$box") dest=$([ -f "$DEST_VF" ] && echo yes || echo no) nonempty=$([ -s "$DEST_VF" ] && echo yes || echo no) match=$(cmp -s "$DEST_VF" "$FIXTURE_JAR" && echo yes || echo no)"
fi

# 18 — vineflower: sha256 mismatch → abort, no DEST, exit non-zero.
box="$(mkbox c18-vf-mismatch)"
stub_download "$box" curl 0 "$FIXTURE_JAR"
stub "$box" wget 1
stub "$box" sha256sum 1   # always fails = mismatch
DEST_VF="$box/home/.local/share/research-sdd-tools/java/vineflower.jar"
run "$box" vineflower
if [ "$RC" -ne 0 ] && [ ! -f "$DEST_VF" ]; then
  ok "18 vineflower: sha256 mismatch → exit non-zero, no DEST" "(exit $RC)"
else
  no "18 vineflower: sha256 mismatch" "exit=$RC dest=$([ -f "$DEST_VF" ] && echo yes || echo no)"
fi

# 19 — vineflower: idempotency → DEST present, hash ok → already, no download.
box="$(mkbox c19-vf-idem)"
stub "$box" sha256sum 0
stub_download "$box" curl 0 "$FIXTURE_JAR"
stub "$box" wget 1
DEST_VF="$box/home/.local/share/research-sdd-tools/java/vineflower.jar"
mkdir -p "$(dirname "$DEST_VF")"; cp "$FIXTURE_JAR" "$DEST_VF"
run "$box" vineflower
if [ "$RC" = 0 ] && ! grep -q "curl" "$box/calls.log" && [ "$(logstatus "$box")" = already ]; then
  ok "19 vineflower: idempotency → already, no download" "(exit $RC · no curl · already)"
else
  no "19 vineflower: idempotency" "exit=$RC curl=$(grep -c curl "$box/calls.log" 2>/dev/null || echo 0) status=$(logstatus "$box")"
fi

# 20 — vineflower: download failure → curl + wget both fail → exit non-zero, no DEST.
box="$(mkbox c20-vf-dl-fail)"
stub "$box" curl 1
stub "$box" wget 1
stub "$box" sha256sum 0
DEST_VF="$box/home/.local/share/research-sdd-tools/java/vineflower.jar"
run "$box" vineflower
if [ "$RC" -ne 0 ] && [ ! -f "$DEST_VF" ]; then
  ok "20 vineflower: download fail → exit non-zero, no DEST" "(exit $RC)"
else
  no "20 vineflower: download fail" "exit=$RC dest=$([ -f "$DEST_VF" ] && echo yes || echo no)"
fi

# 21 — cfr: fresh install.
box="$(mkbox c21-cfr-fresh)"
stub_download "$box" curl 0 "$FIXTURE_JAR"
stub "$box" wget 1
stub "$box" sha256sum 0
DEST_CFR="$box/home/.local/share/research-sdd-tools/java/cfr.jar"
run "$box" cfr
if [ "$RC" = 0 ] && grep -q "curl" "$box/calls.log" && [ "$(logstatus "$box")" = installed ] && [ -f "$DEST_CFR" ] && [ -s "$DEST_CFR" ] && cmp -s "$DEST_CFR" "$FIXTURE_JAR"; then
  ok "21 cfr: fresh install → installed" "(exit $RC · curl · installed · DEST non-empty · matches fixture)"
else
  no "21 cfr: fresh install" "exit=$RC curl=$(grep -c curl "$box/calls.log" 2>/dev/null || echo 0) status=$(logstatus "$box") dest=$([ -f "$DEST_CFR" ] && echo yes || echo no) nonempty=$([ -s "$DEST_CFR" ] && echo yes || echo no) match=$(cmp -s "$DEST_CFR" "$FIXTURE_JAR" && echo yes || echo no)"
fi

# 22 — cfr: idempotency.
box="$(mkbox c22-cfr-idem)"
stub "$box" sha256sum 0
stub_download "$box" curl 0 "$FIXTURE_JAR"
stub "$box" wget 1
DEST_CFR="$box/home/.local/share/research-sdd-tools/java/cfr.jar"
mkdir -p "$(dirname "$DEST_CFR")"; cp "$FIXTURE_JAR" "$DEST_CFR"
run "$box" cfr
if [ "$RC" = 0 ] && ! grep -q "curl" "$box/calls.log" && [ "$(logstatus "$box")" = already ]; then
  ok "22 cfr: idempotency → already, no download" "(exit $RC · no curl · already)"
else
  no "22 cfr: idempotency" "exit=$RC curl=$(grep -c curl "$box/calls.log" 2>/dev/null || echo 0) status=$(logstatus "$box")"
fi

# 23 — procyon: fresh install.
box="$(mkbox c23-procyon-fresh)"
stub_download "$box" curl 0 "$FIXTURE_JAR"
stub "$box" wget 1
stub "$box" sha256sum 0
DEST_PROCYON="$box/home/.local/share/research-sdd-tools/java/procyon.jar"
run "$box" procyon
if [ "$RC" = 0 ] && grep -q "curl" "$box/calls.log" && [ "$(logstatus "$box")" = installed ] && [ -f "$DEST_PROCYON" ] && [ -s "$DEST_PROCYON" ] && cmp -s "$DEST_PROCYON" "$FIXTURE_JAR"; then
  ok "23 procyon: fresh install → installed" "(exit $RC · curl · installed · DEST non-empty · matches fixture)"
else
  no "23 procyon: fresh install" "exit=$RC curl=$(grep -c curl "$box/calls.log" 2>/dev/null || echo 0) status=$(logstatus "$box") dest=$([ -f "$DEST_PROCYON" ] && echo yes || echo no) nonempty=$([ -s "$DEST_PROCYON" ] && echo yes || echo no) match=$(cmp -s "$DEST_PROCYON" "$FIXTURE_JAR" && echo yes || echo no)"
fi

# 24 — procyon: idempotency.
box="$(mkbox c24-procyon-idem)"
stub "$box" sha256sum 0
stub_download "$box" curl 0 "$FIXTURE_JAR"
stub "$box" wget 1
DEST_PROCYON="$box/home/.local/share/research-sdd-tools/java/procyon.jar"
mkdir -p "$(dirname "$DEST_PROCYON")"; cp "$FIXTURE_JAR" "$DEST_PROCYON"
run "$box" procyon
if [ "$RC" = 0 ] && ! grep -q "curl" "$box/calls.log" && [ "$(logstatus "$box")" = already ]; then
  ok "24 procyon: idempotency → already, no download" "(exit $RC · no curl · already)"
else
  no "24 procyon: idempotency" "exit=$RC curl=$(grep -c curl "$box/calls.log" 2>/dev/null || echo 0) status=$(logstatus "$box")"
fi

# 25 — --list includes vineflower, cfr, procyon.
box="$(mkbox c25-list-java)"
run "$box" --list
if [ "$RC" = 0 ] && grep -qx 'vineflower' <<<"$OUT" && grep -qx 'cfr' <<<"$OUT" && grep -qx 'procyon' <<<"$OUT"; then
  ok "25 --list → includes vineflower, cfr, procyon" "(exit $RC)"
else
  no "25 --list → includes vineflower, cfr, procyon" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative control). Mutate a throwaway copy of the ilspycmd guard into
# the ACTUALLY-buggy grouped form the phantom review imagined —
#     have ilspycmd || { have "$HOME/.dotnet/tools/ilspycmd" && { … exit 0; }; }
# where the braces force `A || (B && C)`. Against the mutant, a PRESENT ilspycmd
# makes `A || {…}` short-circuit PAST the block and fall through to reinstall.
# If the mutant reinstalls (CALLS gains `tool install`), the case-1 idempotency
# assertion demonstrably depends on the real grouping → it has teeth. If it did
# NOT reinstall, case 1 would pass on a broken script → theater.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutate guard to grouped 'A || { B && exit }', expect a PRESENT tool to REINSTALL --"
  box="$(mkbox teeth-grouped-mutant)"
  orig='have ilspycmd || have "$HOME/.dotnet/tools/ilspycmd" && { log ilspycmd "dotnet tool (present)" already; exit 0; }'
  new='have ilspycmd || { have "$HOME/.dotnet/tools/ilspycmd" && { log ilspycmd "dotnet tool (present)" already; exit 0; }; }'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$orig"* ]]; then
    no "teeth: build grouped mutant" "guard anchor not found — SUT drifted?"
  else
    printf '%s\n' "${content//"$orig"/"$new"}" > "$box/install-tool.sh"
    stub "$box" ilspycmd 0   # present — a correct guard must NOT reinstall this
    stub "$box" dotnet 0     # records the reinstall the mutant wrongly performs
    run "$box" ilspycmd
    if grep -q 'tool install' "$box/calls.log"; then
      ok "teeth: grouped mutant reinstalls present tool" "(case 1 has teeth)"
    else
      no "teeth: grouped mutant reinstalls present tool" "mutant did NOT reinstall — case 1 is THEATER; calls=[$(calls "$box")]"
    fi
  fi

  echo "-- teeth: remove -*) guard, expect --foo to reach brew install and corrupt ledger --"
  box="$(mkbox teeth-flag-guard-mutant)"
  orig='  -*)        usage >&2; exit 2 ;;'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$orig"* ]]; then
    no "teeth: build flag-guard mutant" "guard anchor not found — SUT drifted?"
  else
    printf '%s\n' "${content//"$orig"/}" > "$box/install-tool.sh"
    stub "$box" brew 0   # brew exits 0 → log() fires → ledger created
    run "$box" --foo
    if [ -f "$box/INSTALLED-TOOLS.md" ] && grep -q 'installed' "$box/INSTALLED-TOOLS.md"; then
      ok "teeth: flag-guard mutant writes ledger (cases 14-16 have teeth)" "(brew install --foo wrote log)"
    else
      no "teeth: flag-guard mutant writes ledger (cases 14-16 have teeth)" "ledger not written — exit=$RC out=[$OUT]"
    fi
  fi
  echo "-- teeth: skip vineflower sha256 gate; mismatch test (18) must detect the missing guard --"
  box="$(mkbox teeth-java-skip-sha256)"
  orig='    if ! echo "$VF_PIN  $TMP" | sha256sum -c --status -; then  # vineflower sha256 gate'
  new='    if false; then  # MUTANT: sha256 gate bypassed'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$orig"* ]]; then
    no "teeth: build sha256-skip mutant" "anchor not found — SUT drifted?"
  else
    printf '%s\n' "${content/"$orig"/"$new"}" > "$box/install-tool.sh"
    stub_download "$box" curl 0 "$FIXTURE_JAR"
    stub "$box" wget 1
    stub "$box" sha256sum 1   # fails: correct gate would reject; mutant does not
    DEST_VF="$box/home/.local/share/research-sdd-tools/java/vineflower.jar"
    run "$box" vineflower
    if [ "$RC" = 0 ] && [ -f "$DEST_VF" ]; then
      ok "teeth: sha256-skip mutant installs despite mismatch" "(case 18 has teeth)"
    else
      no "teeth: sha256-skip mutant installs despite mismatch" "exit=$RC dest=$([ -f "$DEST_VF" ] && echo yes || echo no) — case 18 is THEATER"
    fi
  fi

  echo "-- teeth: drop -o from vineflower curl; case 17 non-empty check must go RED --"
  box="$(mkbox teeth-curl-no-dest)"
  orig='curl -fsSL "$VF_URL" -o "$TMP"'
  new_curl='curl -fsSL "$VF_URL"'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$orig"* ]]; then
    no "teeth: build curl-no-dest mutant" "anchor not found — SUT drifted?"
  else
    printf '%s\n' "${content/"$orig"/"$new_curl"}" > "$box/install-tool.sh"
    stub_download "$box" curl 0 "$FIXTURE_JAR"
    stub "$box" wget 1
    stub "$box" sha256sum 0
    DEST_VF_T="$box/home/.local/share/research-sdd-tools/java/vineflower.jar"
    run "$box" vineflower
    # Mutant exits 0 and moves the EMPTY mktemp file to DEST — DEST exists but is empty.
    # The strengthened case 17 assertion (non-empty + cmp) would catch this; the tooth
    # passes when the mutant produces that empty-DEST outcome.
    if [ "$RC" = 0 ] && [ -f "$DEST_VF_T" ] && ! [ -s "$DEST_VF_T" ]; then
      ok "teeth: curl-no-dest mutant: DEST empty (case 17 materialization check has teeth)" "(non-empty assertion bites)"
    else
      no "teeth: curl-no-dest mutant: expected exit 0 + empty DEST" "exit=$RC dest=$([ -f "$DEST_VF_T" ] && echo yes || echo no) size=$([ -s "$DEST_VF_T" ] && echo nonempty || echo empty)"
    fi
  fi

  echo "-- teeth: move-before-verify mutant; mismatch test (18) must catch DEST created early --"
  box="$(mkbox teeth-java-move-before-verify)"
  orig=$'    if ! echo "$VF_PIN  $TMP" | sha256sum -c --status -; then  # vineflower sha256 gate\n      rm -f "$TMP"; log vineflower "$VF_URL" failed "sha256 mismatch"; exit 4\n    fi\n    if ! mv "$TMP" "$DEST"; then  # vineflower: verified\n      rm -f "$TMP"; log vineflower "$VF_URL" failed "mv to DEST failed"; exit 4\n    fi'
  new=$'    if ! mv "$TMP" "$DEST"; then  # MUTANT: moved before verify\n      rm -f "$TMP"; log vineflower "$VF_URL" failed "mv to DEST failed"; exit 4\n    fi\n    if ! echo "$VF_PIN  $TMP" | sha256sum -c --status -; then  # vineflower sha256 gate\n      rm -f "$TMP"; log vineflower "$VF_URL" failed "sha256 mismatch"; exit 4\n    fi'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$orig"* ]]; then
    no "teeth: build move-before-verify mutant" "anchor not found — SUT drifted?"
  else
    printf '%s\n' "${content/"$orig"/"$new"}" > "$box/install-tool.sh"
    stub_download "$box" curl 0 "$FIXTURE_JAR"
    stub "$box" wget 1
    stub "$box" sha256sum 1   # fails: with mutant, DEST was already moved before the check
    DEST_VF="$box/home/.local/share/research-sdd-tools/java/vineflower.jar"
    run "$box" vineflower
    if [ -f "$DEST_VF" ]; then
      ok "teeth: move-before-verify mutant leaves corrupt file at DEST" "(case 18 has teeth for DEST check)"
    else
      no "teeth: move-before-verify mutant leaves corrupt file at DEST" "dest not created — case 18's DEST assertion is THEATER"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
