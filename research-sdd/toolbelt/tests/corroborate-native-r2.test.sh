#!/usr/bin/env bash
# tests/corroborate-native-r2.test.sh — shim contract of corroborate-native.sh.
#
# corroborate-native.sh is a compatibility shim over `rsdd corroborate native` (Go). The adapter's behaviour -
# staging and identity, the radare2 sandbox argv, every cap, the manifest, the evidence schema, each refusal and
# the staged-bytes guarantees - is covered by the Go tests in research-sdd/rsdd/internal/corroborate/native
# (fake radare2 and Bubblewrap through the real process runner, plus a real-tool test that skips where the tools
# are absent). This suite checks what the shim itself owns: it forwards arguments, the exit code and stderr
# unchanged, and it degrades through rsdd-exec (typed, exit 2) when rsdd cannot run. It also keeps a few
# end-to-end cases through the real binary and, under --prove-teeth, mutation controls on the shim.
#
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/corroborate-native.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== corroborate-native-r2.test.sh =="

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

# shim_run SHIM [args...] -> SOUT SERR SRC
shim_run() { SOUT="$(RSDD_BIN="$STUB" STUB_RC="${STUB_RC:-7}" bash "$1" "${@:2}" 2>"$TMP/serr")"; SRC=$?; SERR="$(cat "$TMP/serr")"; }

check_forward() {
  local shim="$1" tag="$2" want
  shim_run "$shim" --input 'a b.elf' --output '' --max-functions 3
  want=$'ARG[corroborate]\nARG[native]\nARG[--input]\nARG[a b.elf]\nARG[--output]\nARG[]\nARG[--max-functions]\nARG[3]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'corroborate native' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" --input x --output "$TMP/degraded" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && [ ! -e "$TMP/degraded" ]; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, no evidence written (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/corroborate-native.sh"
out="$(bash "$TMP/nolib/corroborate-native.sh" --input x --output y 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no Python, no adapter logic left behind.
if grep -qF 'rsdd_exec corroborate native "$@"' "$SUT" && ! grep -qE 'python3|corroborate_native|analysis_manifest' "$SUT" \
   && [ ! -e "$TOOLBELT/corroborate_native.py" ]; then
  ok "4 shim body is 'rsdd_exec corroborate native \"\$@\"' with no python3 / corroborate_native.py left"
else no "4 shim body"; fi

# ---- End to end through the real binary --------------------------------------
# $RSDD_BIN wins; otherwise one binary is built into the suite temp dir (never into the tree). Without Go the
# end-to-end group is a typed SKIP (FAIL under RSDD_REQUIRE_GO=1): the shim checks above never need it.
real_rsdd=""
if [ -n "${RSDD_BIN:-}" ] && [ -x "${RSDD_BIN:-}" ]; then real_rsdd="$RSDD_BIN"
elif command -v go >/dev/null 2>&1; then
  if ( cd "$TOOLBELT/../rsdd" && CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS='' GOWORK=off go build -o "$TMP/rsdd" ./cmd/rsdd ) >"$TMP/build.log" 2>&1; then real_rsdd="$TMP/rsdd"
  else echo "FATAL: cannot build rsdd" >&2; tail -n 20 "$TMP/build.log" >&2; exit 2; fi
fi
if [ -z "$real_rsdd" ]; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then no "e2e: rsdd-unavailable: go not in PATH and no executable RSDD_BIN (RSDD_REQUIRE_GO=1)"
  else echo "SKIP e2e (rsdd-unavailable: go not in PATH and no executable RSDD_BIN; set RSDD_REQUIRE_GO=1 to fail instead)"; fi
else
  q() { RSDD_BIN="$real_rsdd" bash "$SUT" "$@"; }
  W="$TMP/e2e"; mkdir -m 700 "$W"; printf '\177ELF fake\n' > "$W/in.elf"

  # 5. an input symlink is refused: exit 2, the typed message, no evidence
  ln -s "$W/in.elf" "$W/link.elf"
  rc=0; q --input "$W/link.elf" --output "$W/t5" 2>"$W/t5.err" || rc=$?
  if [ "$rc" -eq 2 ] && grep -qF "corroborate-native: cannot open regular non-symlink file: $W/link.elf" "$W/t5.err" && [ ! -e "$W/t5" ]; then
    ok "5 input symlink: exit 2, typed message, no evidence"; else no "5 input symlink (rc=$rc)"; fi

  # 6. an existing output is never replaced
  mkdir "$W/taken"; echo keep > "$W/taken/keep"
  rc=0; q --input "$W/in.elf" --output "$W/taken" 2>"$W/t6.err" || rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'output must be a new non-colliding path' "$W/t6.err" && [ "$(cat "$W/taken/keep")" = keep ]; then
    ok "6 output collision: exit 2, nothing replaced"; else no "6 output collision (rc=$rc)"; fi

  # 7. a usage error is exit 2 with usage on stderr and nothing on stdout; --help is exit 0
  rc=0; so="$(q --bogus 2>"$W/t7.err")" || rc=$?
  if [ "$rc" -eq 2 ] && [ -z "$so" ] && grep -qF 'usage: rsdd corroborate native' "$W/t7.err"; then ok "7 usage error: exit 2, usage on stderr"; else no "7 usage error (rc=$rc)"; fi
  rc=0; so="$(q --help 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && grep -qF 'usage: rsdd corroborate native' <<< "$so"; then ok "8 --help: exit 0, usage on stdout"; else no "8 --help (rc=$rc)"; fi

  # 9. the real tools (radare2 + Bubblewrap with namespaces), when this host has them: a complete, verifiable report
  if command -v r2 >/dev/null 2>&1 && command -v bwrap >/dev/null 2>&1 && bwrap --unshare-net --ro-bind / / /bin/true 2>/dev/null; then
    rc=0; q --input "$(type -P true)" --output "$W/t9" 2>"$W/t9.err" || rc=$?
    if [ "$rc" -eq 0 ] && python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["schema"]=="native-static.v1" and d["status"]=="complete" and d["counts"]["functions_emitted"]>0' "$W/t9/native-static.v1.json" 2>/dev/null; then
      ok "9 real radare2 under Bubblewrap: exit 0, complete native-static.v1"; else no "9 real tools (rc=$rc err=$(head -c 300 "$W/t9.err"))"; fi
  else echo "SKIP 9 real tools (r2 / bwrap with namespaces not available on this host)"; fi
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for corroborate-native.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/corroborate-native.sh" "$2" 2>/dev/null; then MS="$d/corroborate-native.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  want_args=$'ARG[corroborate]\nARG[native]\nARG[--input]\nARG[x]'
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec corroborate native "\$@"#rsdd_exec corroborate native#'; then
    shim_run "$MS" --input x
    [ "$SOUT" != "$want_args" ] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec corroborate native#rsdd_exec corroborate natve#'; then
    shim_run "$MS" --input x
    [ "$SOUT" != "$want_args" ] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by exit 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/corroborate-native.sh"
    out="$(bash "$TMP/mt/C-nolib/corroborate-native.sh" --input x --output y 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec corroborate native "\$@"#( rsdd_exec corroborate native "$@" ); exit 0#'; then
    shim_run "$MS" --input x
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the end-to-end group is real: a shim pointed at the other command fails case 5
  if [ -n "$real_rsdd" ] && mk E 's#^rsdd_exec corroborate native#rsdd_exec corroborate java-fidelity#'; then
    out="$(RSDD_BIN="$real_rsdd" bash "$MS" --input "$TMP/e2e/link.elf" --output "$TMP/e2e/t_e" 2>&1)"
    if grep -qF "cannot open regular non-symlink file" <<< "$out"; then no "teeth E: the wrong command still refused the symlink — THEATER"
    else ok "teeth E: wrong command -> the end-to-end symlink refusal goes red"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
