#!/usr/bin/env bash
# stage-retro-issues.test.sh — shim contract of stage-retro-issues.sh (kit issue #2435).
#
# stage-retro-issues.sh is a compatibility shim over `rsdd retro stage-issues` (Go). The stager's behaviour (the
# review-status gate, every delta form, the unclassifiable tracker, the scrub, the kit-repo resolution, the --apply
# dedup / occurrence / create / read-back machinery and every typed state) is covered by the Go tests in
# research-sdd/rsdd/internal/retro/stageissues: recorded goldens from the frozen pre-port script, a live
# differential against it, and unit tests. This suite checks only what the shim itself owns: it passes its own
# directory as `--toolbelt <dir>` before the caller's arguments, forwards arguments, the exit code and stderr
# unchanged, and degrades through rsdd-exec (typed, exit 2) when rsdd cannot run. Mutation controls under
# --prove-teeth.
#
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd -P)"
SUT="$TOOLBELT/stage-retro-issues.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== stage-retro-issues.test.sh =="

[ -f "$SUT" ] && [ -x "$SUT" ] && [ -f "$TOOLBELT/lib/rsdd-exec.sh" ] || { echo "FATAL: absent-input: shim or lib/rsdd-exec.sh" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A stand-in rsdd: prints one argument per line, says something on stderr and exits with a chosen code.
STUB="$TMP/rsdd-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
echo "stub-stderr" >&2
exit "${STUB_RC:-7}"
EOF
chmod +x "$STUB"

# check SHIM -> runs the forwarding checks against SHIM (the real shim, or a mutant of it)
shim_run() { SOUT="$(RSDD_BIN="$STUB" STUB_RC="${STUB_RC:-7}" bash "$1" "${@:2}" 2>"$TMP/serr")"; SRC=$?; SERR="$(cat "$TMP/serr")"; }

check_forward() {
  local shim="$1" tag="$2" want
  shim_run "$shim" 'a b.md' --apply ''
  want=$'ARG[retro]\nARG[stage-issues]\nARG[--toolbelt]\nARG['"$(dirname "$shim")"$']\nARG[a b.md]\nARG[--apply]\nARG[]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'retro stage-issues --toolbelt <own dir>' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" x.md --apply 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && ! grep -q 'planned-issue' <<< "$out"; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, nothing staged (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/stage-retro-issues.sh"
out="$(bash "$TMP/nolib/stage-retro-issues.sh" x.md 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no Python, no listing, no rule logic left behind.
if grep -qF 'rsdd_exec retro stage-issues --toolbelt "$_RSDD_SELF" "$@"' "$SUT" && ! grep -qE 'awk|gh issue|python3|scrub_issue_text|retro_grammar' "$SUT"; then
  ok "4 shim body is 'rsdd_exec retro stage-issues --toolbelt \"\$_RSDD_SELF\" \"\$@\"' with no awk / gh / scrub / grammar logic left"
else no "4 shim body"; fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for stage-retro-issues.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/stage-retro-issues.sh" "$2" 2>/dev/null; then MS="$d/stage-retro-issues.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec retro stage-issues --toolbelt "\$_RSDD_SELF" "\$@"#rsdd_exec retro stage-issues --toolbelt "\$_RSDD_SELF"#'; then
    shim_run "$MS" x.md
    [[ "$SOUT" != *'ARG[x.md]'* ]] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec retro stage-issues#rsdd_exec retro stage-issuez#'; then
    shim_run "$MS" x.md
    [[ "$SOUT" != *'ARG[stage-issues]'* ]] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by a bare true)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/stage-retro-issues.sh"
    out="$(bash "$TMP/mt/C-nolib/stage-retro-issues.sh" x.md 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered (exec replaced by a call that returns 0)
  if mk D 's#^rsdd_exec retro stage-issues --toolbelt "\$_RSDD_SELF" "\$@"#( rsdd_exec retro stage-issues --toolbelt "$_RSDD_SELF" "$@" ); exit 0#'; then
    shim_run "$MS" x.md
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the shim's own directory is no longer handed over (the Go command would have no kit root)
  if mk E 's#--toolbelt "\$_RSDD_SELF" ##'; then
    shim_run "$MS" x.md
    [[ "$SOUT" != *'ARG[--toolbelt]'* ]] && ok "teeth E: --toolbelt dropped -> forwarding check goes red" || no "teeth E: mutant still passes --toolbelt — THEATER"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
