#!/usr/bin/env bash
# qnx6-read.test.sh — shim contract of qnx6-read.sh (kit issue #2417).
#
# qnx6-read.sh is a compatibility shim over `rsdd formats qnx6-read` (Go). The reader's behavior - every refusal,
# the three anti-silent-zero states, the depth cap, the cycle guard, the bounded reads, the evidence schema - is
# covered by the Go tests in research-sdd/rsdd/internal/formats (qnx6_test.go carries the guard-to-test table; a
# differential against the frozen pre-port script runs over the fixtures and over 560 seeded corruptions of real
# images). This suite checks what the shim itself owns: it forwards arguments, the exit code and stderr
# unchanged, and it degrades through rsdd-exec (typed, exit 2) when rsdd cannot run. It also keeps a few
# end-to-end cases through the real binary and, under --prove-teeth, mutation controls on the shim.
#
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/qnx6-read.sh"
FIX="$TOOLBELT/../rsdd/internal/formats/testdata/qnx6"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== qnx6-read.test.sh =="

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
  shim_run "$shim" list --input 'a b.img' --partition-offset 5 --output ''
  want=$'ARG[formats]\nARG[qnx6-read]\nARG[list]\nARG[--input]\nARG[a b.img]\nARG[--partition-offset]\nARG[5]\nARG[--output]\nARG[]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd verbatim after 'formats qnx6-read' (spaces and an empty argument kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" list --input x --output "$TMP/degraded.json" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && [ ! -e "$TMP/degraded.json" ]; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, no evidence written (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/qnx6-read.sh"
out="$(bash "$TMP/nolib/qnx6-read.sh" list --input x --output y 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no Python, no reader logic left behind.
if grep -qF 'rsdd_exec formats qnx6-read "$@"' "$SUT" && ! grep -qE 'python3|qnx6_read|struct' "$SUT"; then
  ok "4 shim body is 'rsdd_exec formats qnx6-read \"\$@\"' with no python3 / qnx6_read.py left"
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
  W="$TMP/e2e"; mkdir -m 700 "$W"

  # 5. list of a valid image: exit 0 and a complete evidence document with the one file
  rc=0; q list --input "$FIX/valid.img" --output "$W/t5.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && python3 - "$W/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'qnx6-evidence.v1' and d['status'] == 'complete' and d['errors'] == []
assert [e['path'] for e in d['entries']] == ['/file'] and d['summary']['total_entries'] == 1
PY
  then ok "5 list valid image: exit 0, status complete, entry '/file'"; else no "5 list valid image (rc=$rc)"; fi

  # 6. bad magic: exit 1 and a failed document (never a clean 0)
  rc=0; q list --input "$FIX/bad_magic.img" --output "$W/t6.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 1 ] && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['status']=='failed' and d['errors']" "$W/t6.json" 2>/dev/null; then
    ok "6 bad magic: exit 1, status failed, errors non-empty"; else no "6 bad magic (rc=$rc)"; fi

  # 7. absent input: exit 2 and no evidence
  rc=0; q list --input "$W/no-such.img" --output "$W/t7.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/t7.json" ]; then ok "7 absent input: exit 2, no evidence"; else no "7 absent input (rc=$rc)"; fi

  # 8. extract: exit 0 and the exact bytes
  rc=0; q extract --input "$FIX/valid.img" --fs-path /file --output "$W/t8" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$W/t8")" = "hello-world" ]; then ok "8 extract: exit 0, exact content"; else no "8 extract (rc=$rc)"; fi

  # 9. an output symlink is never followed: exit 2 and the victim is intact
  echo victim-content > "$W/victim.txt"; ln -s "$W/victim.txt" "$W/out_sym.json"
  rc=0; q list --input "$FIX/valid.img" --output "$W/out_sym.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ "$(cat "$W/victim.txt")" = "victim-content" ]; then ok "9 output symlink: exit 2, victim intact"; else no "9 output symlink (rc=$rc)"; fi

  # 10. a FIFO input is refused without blocking
  mkfifo "$W/fifo.img"
  rc=0; timeout 10 bash -c 'RSDD_BIN="$1" bash "$2" list --input "$3" --output "$4"' _ "$real_rsdd" "$SUT" "$W/fifo.img" "$W/t10.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/t10.json" ]; then ok "10 FIFO input: exit 2, no evidence, no hang"; else no "10 FIFO input (rc=$rc)"; fi
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for qnx6-read.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/qnx6-read.sh" "$2" 2>/dev/null; then MS="$d/qnx6-read.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec formats qnx6-read "\$@"#rsdd_exec formats qnx6-read#'; then
    shim_run "$MS" list --input x
    [ "$SOUT" != $'ARG[formats]\nARG[qnx6-read]\nARG[list]\nARG[--input]\nARG[x]' ] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec formats qnx6-read#rsdd_exec formats qnx6-rea#'; then
    shim_run "$MS" list
    [ "$SOUT" != $'ARG[formats]\nARG[qnx6-read]\nARG[list]' ] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by exit 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/qnx6-read.sh"
    out="$(bash "$TMP/mt/C-nolib/qnx6-read.sh" list --input x --output y 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec formats qnx6-read "\$@"#( rsdd_exec formats qnx6-read "$@" ); exit 0#'; then
    shim_run "$MS" list
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the end-to-end group is real: a shim pointed at the other command fails case 5
  if [ -n "$real_rsdd" ] && mk E 's#^rsdd_exec formats qnx6-read#rsdd_exec formats squashfs-extract#'; then
    if RSDD_BIN="$real_rsdd" bash "$MS" list --input "$FIX/valid.img" --output "$TMP/e2e/t_e.json" >/dev/null 2>&1; then no "teeth E: the wrong command still listed — THEATER"
    else ok "teeth E: wrong command -> the end-to-end listing goes red"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
