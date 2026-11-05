#!/usr/bin/env bash
# migrate-backlogs.test.sh — shim contract of migrate-backlogs.sh (kit issue #2684, originally kit #1543).
#
# migrate-backlogs.sh is a compatibility shim over `rsdd corpus migrate-backlogs` (Go). The tool is PROPOSE-ONLY: it
# prints the mechanical §8b migration as a unified diff per file and a typed MANUAL line for everything else, and
# never writes to the target. Every transform, every MANUAL reason, the typed absent/empty states, the diff hunks and
# the read-only invariant are covered by the Go tests in research-sdd/rsdd/internal/corpus/migratebacklogs: recorded
# goldens from the frozen pre-port script, a live differential against it, and the divergence tests for the defects
# the port fixes. This suite checks only what the shim itself owns: it forwards arguments, the exit code, stdout and
# stderr unchanged, degrades through rsdd-exec (typed, exit 2) when rsdd cannot run, and, when the runner hands it a
# built binary (RSDD_BIN), reaches the real command end to end on a throwaway corpus: the target stays byte-identical,
# the proposal applies cleanly with patch(1) and leaves nothing mechanical to propose, and the typed states and exit
# codes reach the caller. Mutation controls under --prove-teeth.
#
# The mutation controls of the retired bash suite mutated the awk programs of the old script body (the escape masks,
# the diff status guard, the helper guards); that body is gone. Their Go replacements are named in the SKIP lines below.
#
# Usage: migrate-backlogs.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout (kit issue #1024 round 5)
TOOLBELT="$(cd "$HERE/.." && pwd -P)"
SUT="$TOOLBELT/migrate-backlogs.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== migrate-backlogs.test.sh =="

[ -f "$SUT" ] && [ -x "$SUT" ] && [ -f "$TOOLBELT/lib/rsdd-exec.sh" ] || { echo "FATAL: absent-input: shim or lib/rsdd-exec.sh" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A stand-in rsdd: prints one argument per line, says something on both streams and exits with a chosen code.
STUB="$TMP/rsdd-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
echo "stub-stderr" >&2
exit "${STUB_RC:-7}"
EOF
chmod +x "$STUB"

# shim_run SHIM ARGS... -> runs SHIM against the stub rsdd; sets SOUT SERR SRC
shim_run() { SOUT="$(RSDD_BIN="$STUB" STUB_RC="${STUB_RC:-7}" bash "$1" "${@:2}" 2>"$TMP/serr")"; SRC=$?; SERR="$(cat "$TMP/serr")"; }

check_forward() {
  local shim="$1" tag="$2" want
  shim_run "$shim" 'a b' ''
  want=$'ARG[corpus]\nARG[migrate-backlogs]\nARG[a b]\nARG[]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'corpus migrate-backlogs' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" "$TMP" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && ! grep -q 'file(s) inspected' <<< "$out"; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, no closing summary (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/migrate-backlogs.sh"
out="$(bash "$TMP/nolib/migrate-backlogs.sh" "$TMP" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no awk, diff, find or sourced state-file helper left behind.
code="$(grep -v '^[[:space:]]*#' "$SUT")"
if grep -qF 'rsdd_exec corpus migrate-backlogs "$@"' "$SUT" && ! grep -qE 'awk |diff |find |mktemp|state-files|list_state_files|BACKLOG_AWK' <<< "$code"; then
  ok "4 shim body is 'rsdd_exec corpus migrate-backlogs \"\$@\"' with no awk / diff / find / sourced-helper logic left"
else no "4 shim body"; fi

# 5. End to end through the real binary (the runner builds one and exports RSDD_BIN; without it the shim would build
# bin/rsdd inside the tree, which the kit-tree hermeticity check forbids).
SHATOOL=""
for _c in sha1sum shasum sha256sum; do command -v "$_c" >/dev/null 2>&1 && { SHATOOL="$_c"; break; }; done
# tree_sum DIR — path + content digest of every file under DIR: the target must be byte-identical after a run
tree_sum() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 "$SHATOOL"; find . -print | sort); }

mkcorpus() {
  local d="$1"; mkdir -p "$d"
  cat > "$d/FOCUSES.md" <<'E'
# Focuses

| Focus | Status | State |
|---|---|---|
| alpha | closed (4/4) | RESEARCH-STATE-alpha.md |
| beta | active | RESEARCH-STATE-beta.md |
| gamma | weirdo | RESEARCH-STATE-gamma.md |
| delta | document | RESEARCH-STATE-delta.md |
E
  cat > "$d/RESEARCH-STATE-alpha.md" <<'E'
# Alpha — Research State

## Gap backlog

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| critical | G1 | web | open |
| MED | G2 | web | queued (note) |
| low (deferred) | G3 | web | pending |
| high (cross-vibra) | G4 | web | pending |
| SES2 | G5 | web | pending |
| — | G6 | web | open |
| high | G7 | web | covered B1 |
| **HIGH** | G8 | web | **open** |
| high | G9 | web | folded |
| high | G10 | web | pending |

## Stop control

- done
E
  printf '# Beta — Research State\n\n## Gap-backlog (prioritized)\n\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n| high | B1 | web | pending |\n| low | B2 | web | ✅ B3 |\n' > "$d/RESEARCH-STATE-beta.md"
  printf '# Gamma — Research State\n\nno backlog here\n' > "$d/RESEARCH-STATE-gamma.md"
  printf '# Delta — Research State\n\noutline only\n' > "$d/RESEARCH-STATE-delta.md"
}

if [ -n "${RSDD_BIN:-}" ] && [ -x "$RSDD_BIN" ] && [ -n "$SHATOOL" ] && command -v patch >/dev/null 2>&1; then
  e2e_run() { E2E_OUT="$(env -i PATH="$PATH" HOME="$TMP" RSDD_BIN="$RSDD_BIN" bash "$1" "${@:2}" 2>"$TMP/e2e.err")"; E2E_RC=$?; E2E_ERR="$(cat "$TMP/e2e.err")"; }
  corpus="$TMP/corpus"; mkcorpus "$corpus"
  before="$(tree_sum "$corpus")"
  e2e_run "$SUT" "$corpus"
  after="$(tree_sum "$corpus")"
  if [ "$E2E_RC" -eq 0 ] && grep -qF '+## Gap-backlog' <<< "$E2E_OUT" && grep -qF '+| high | G1 | web | pending |' <<< "$E2E_OUT" \
     && grep -qF '+| alpha | stopped (4/4) | RESEARCH-STATE-alpha.md |' <<< "$E2E_OUT" && grep -q '^MANUAL alpha unknown-priority rows=1 ' <<< "$E2E_OUT" \
     && grep -q '^migrate-backlogs: 5 file(s) inspected · 3 with a mechanical proposal · ' <<< "$E2E_OUT"; then
    ok "5a corpus through the real binary -> exit 0, heading / priority / status / FOCUSES proposals, a MANUAL line and the closing summary"
  else no "5a corpus (rc=$E2E_RC out=[$(head -c 400 <<< "$E2E_OUT")] err=[$E2E_ERR])"; fi
  [ "$before" = "$after" ] && ok "5b the target tree is byte-identical after the run (propose-never-apply)" || no "5b the target was modified"

  # 5c idempotence: the diff applies cleanly with patch(1) to a COPY and leaves nothing mechanical to propose
  cp -r "$corpus" "$TMP/applied"
  ( cd "$TMP/applied" && grep -v '^PROPOSE\|^MANUAL\|^ok \|^migrate-backlogs:' <<< "$E2E_OUT" | sed "s#^--- a/#--- #; s#^+++ b/#+++ #" | patch -p0 -s ) >/dev/null 2>&1
  e2e_run "$SUT" "$TMP/applied"
  resid="$(grep '^PROPOSE' <<< "$E2E_OUT" | tr '\n' ' ')"
  if [ -z "$resid" ] && grep -q '^## Gap-backlog' "$TMP/applied/RESEARCH-STATE-alpha.md" && grep -q '| high | G1 | web | pending |' "$TMP/applied/RESEARCH-STATE-alpha.md" \
     && grep -q '^MANUAL alpha unknown-priority' <<< "$E2E_OUT"; then
    ok "5c the diff applies cleanly to a copy, leaves nothing mechanical to propose, and the MANUAL items survive"
  else no "5c residual proposals: [$resid]"; fi

  # 5d the typed states and the exit codes reach the caller
  mkdir -p "$TMP/emptydir"
  e2e_run "$SUT" "$TMP/emptydir"
  if [ "$E2E_RC" -eq 0 ] && grep -q '^absent-input: no RESEARCH-STATE' <<< "$E2E_OUT" && grep -q '^migrate-backlogs: 0 file(s) inspected' <<< "$E2E_OUT"; then ok "5d corpus without state files -> typed absent-input + 0-file summary, exit 0"
  else no "5d absent-input (rc=$E2E_RC out=[$E2E_OUT])"; fi
  mkdir -p "$TMP/emptyfile"; : > "$TMP/emptyfile/RESEARCH-STATE-x.md"
  e2e_run "$SUT" "$TMP/emptyfile"
  grep -q '^empty-input: x ' <<< "$E2E_OUT" && ok "5e 0-byte state file -> typed empty-input" || no "5e empty-input [$E2E_OUT]"
  e2e_run "$SUT" "$TMP/nonexistent"; r1=$E2E_RC; e2e_run "$SUT"; r2=$E2E_RC; e2e_run "$SUT" a b; r3=$E2E_RC
  if [ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ]; then ok "5f absent target / no argument / extra argument -> exit 2"; else no "5f rc: $r1 $r2 $r3"; fi
  out="$(env -i PATH="$PATH" HOME="$TMP" RSDD_BIN="$RSDD_BIN" "$SUT" "$corpus" 2>/dev/null)"; r=$?
  [ "$r" = 0 ] && grep -q '^migrate-backlogs: 5 file(s) inspected' <<< "$out" && ok "5g runs when invoked directly (executable bit), not via bash" || no "5g direct invocation rc=$r"
else
  printf '  SKIP  5 end to end: RSDD_BIN not set to an executable (run it through run-all.sh, which builds the binary once), or sha1sum/patch missing\n'
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for migrate-backlogs.sh (shim) --"
  # The retired controls mutated the awk programs and guards of the old script body, which is gone: each is a typed SKIP
  # naming the Go test that replaces it (research-sdd/rsdd/internal/corpus/migratebacklogs).
  printf '  SKIP  teeth (old GFM-EP-MIG-CELLS / GFM-EP-MIG-DOC masks): the escaped-pipe rows of cases focuses-escaped-pipes-kept and doc-escaped-pipe-* of TestGoldenReplay and TestDifferential\n'
  printf '  SKIP  teeth (old helper / tool / mktemp / awk guards): no helper or external tool is left; TestUnlistableCorpusIsDegradedNotAbsent, TestUnreadableStateFileStopsTheRun\n'
  printf '  SKIP  teeth (old diff status guard): the unified diff is computed in process; TestUnifiedDiffShapes, TestUnifiedDiffBodyRebuildsBothFiles and the hunk-* cases of TestGoldenReplay\n'
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/migrate-backlogs.sh" "$2" 2>/dev/null; then MS="$d/migrate-backlogs.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec corpus migrate-backlogs "\$@"#rsdd_exec corpus migrate-backlogs#'; then
    shim_run "$MS" x
    [[ "$SOUT" != *'ARG[x]'* ]] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec corpus migrate-backlogs#rsdd_exec corpus migrate-backlog#'; then
    shim_run "$MS" x
    [[ "$SOUT" != *'ARG[migrate-backlogs]'* ]] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard exits 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/migrate-backlogs.sh"
    out="$(bash "$TMP/mt/C-nolib/migrate-backlogs.sh" x 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec corpus migrate-backlogs "\$@"#( rsdd_exec corpus migrate-backlogs "$@" ); exit 0#'; then
    shim_run "$MS" x
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: stderr is dropped
  if mk E 's#^rsdd_exec corpus migrate-backlogs "\$@"#rsdd_exec corpus migrate-backlogs "$@" 2>/dev/null#'; then
    shim_run "$MS" x
    [ "$SERR" != "stub-stderr" ] && ok "teeth E: stderr swallowed -> stderr check goes red" || no "teeth E: mutant still forwards stderr — THEATER"
  fi
  # F: end to end, a shim that runs another subcommand reports no corpus: the real-binary case (5a) goes red
  if [ -n "${RSDD_BIN:-}" ] && [ -x "$RSDD_BIN" ] && [ -n "$SHATOOL" ] && type e2e_run >/dev/null 2>&1; then
    mk F 's#^rsdd_exec corpus migrate-backlogs "\$@"#rsdd_exec corpus catalog "$@"#' && {
      cp -r "$corpus" "$TMP/mt/F-corpus"
      e2e_run "$MS" "$TMP/mt/F-corpus"
      grep -q 'file(s) inspected' <<< "$E2E_OUT" && no "teeth F: mutant still prints the migrate summary — THEATER" || ok "teeth F: another subcommand -> the end-to-end case (5a) goes red"
    }
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
