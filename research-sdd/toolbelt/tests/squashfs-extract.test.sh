#!/usr/bin/env bash
# squashfs-extract.test.sh — shim contract of squashfs-extract.sh (kit issue #2417).
#
# squashfs-extract.sh is a compatibility shim over `rsdd formats squashfs-extract` (Go). Every guard of the old
# Python script (root refusal, caps, output path rules, private filesystem, tool lookups, input staging, the
# superblock check, timeout, size watchdog, tree validation, the closed-tree check, atomic publication) and the
# whole behavior - differential against the frozen script with the real bwrap and unsquashfs - are covered by the
# Go tests in research-sdd/rsdd/internal/formats (squashfs_test.go carries the guard-to-test table).
# This suite checks what the shim itself owns: it forwards arguments (adding the sibling analysis_manifest.py as
# --manifest-cli), the exit code and stderr unchanged, and it degrades through rsdd-exec (typed, exit 2) when
# rsdd cannot run. It also keeps a few end-to-end cases through the real binary and, under --prove-teeth,
# mutation controls on the shim.
#
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/squashfs-extract.sh"
FIX="$TOOLBELT/../rsdd/internal/formats/testdata/squashfs"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== squashfs-extract.test.sh =="

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
  local shim="$1" tag="$2" want dir
  dir="$(cd "$(dirname "$shim")" && pwd -P)"  # LINT-CD-PHYSICAL-OK: as above, for a mutant's own directory
  shim_run "$shim" --input 'a b.sqfs' --output out --max-entries 5
  want=$'ARG[formats]\nARG[squashfs-extract]\nARG[--manifest-cli]\nARG['"$dir"$'/analysis_manifest.py]\nARG[--input]\nARG[a b.sqfs]\nARG[--output]\nARG[out]\nARG[--max-entries]\nARG[5]'
  if [ "$SOUT" = "$want" ]; then ok "$tag arguments reach rsdd after 'formats squashfs-extract --manifest-cli <toolbelt>/analysis_manifest.py' (spaces kept)"
  else no "$tag arguments (out=[$SOUT])"; fi
  if [ "$SRC" -eq 7 ]; then ok "$tag exit code of rsdd is the shim's exit code"; else no "$tag exit code (rc=$SRC)"; fi
  if [ "$SERR" = "stub-stderr" ]; then ok "$tag stderr of rsdd passes through"; else no "$tag stderr (err=[$SERR])"; fi
}

check_degrade() {
  local shim="$1" tag="$2" out rc
  out="$(RSDD_BIN="$TMP/does-not-exist" bash "$shim" --input x --output y 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out"; then
    ok "$tag rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, nothing extracted (never a clean 0)"
  else no "$tag degrade (rc=$rc out=[$out])"; fi
}

check_forward "$SUT" "1"
check_degrade "$SUT" "2"

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/squashfs-extract.sh"
out="$(bash "$TMP/nolib/squashfs-extract.sh" --input x --output y 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no Python, no extraction logic left behind.
if grep -qF 'rsdd_exec formats squashfs-extract --manifest-cli' "$SUT" && ! grep -qE 'python3|squashfs_extract|unsquashfs |bwrap' "$SUT"; then
  ok "4 shim body is 'rsdd_exec formats squashfs-extract --manifest-cli ... \"\$@\"' with no python3 / squashfs_extract.py left"
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
e2e_skip=""
if [ -z "$real_rsdd" ]; then e2e_skip="rsdd-unavailable: go not in PATH and no executable RSDD_BIN"
elif ! command -v bwrap >/dev/null 2>&1 || ! command -v unsquashfs >/dev/null 2>&1; then e2e_skip="tool-missing: bwrap and unsquashfs are required"
elif ! bwrap --ro-bind / / true >/dev/null 2>&1; then e2e_skip="tool-missing: bubblewrap cannot create an unprivileged sandbox here"
fi
if [ -n "$e2e_skip" ]; then
  if [ -z "$real_rsdd" ] && [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then no "e2e: $e2e_skip (RSDD_REQUIRE_GO=1)"
  elif [ -n "$real_rsdd" ] && [ "${RSDD_REQUIRE_BWRAP:-}" = "1" ]; then no "e2e: $e2e_skip (RSDD_REQUIRE_BWRAP=1)"
  else echo "SKIP e2e ($e2e_skip; set RSDD_REQUIRE_GO=1 / RSDD_REQUIRE_BWRAP=1 to fail instead)"; fi
else
  run() { RSDD_BIN="$real_rsdd" bash "$SUT" --input "$1" --output "$2" "${@:3}"; }
  W="$TMP/e2e"; mkdir -m 700 "$W"

  # 5. two extractions of the same image publish byte-identical evidence, a closed read-only tree, and a manifest that verifies
  if run "$FIX/good.sqfs" "$W/a" && run "$FIX/good.sqfs" "$W/b" \
     && cmp -s "$W/a/squashfs-extract.v1.json" "$W/b/squashfs-extract.v1.json" \
     && [ "$(cat "$W/a/extracted/hello.txt")" = hello ] && [ "$(cat "$W/a/extracted/subdir/world.txt")" = world ] \
     && [ "$(stat -c %a "$W/a")" = 700 ] && [ "$(stat -c %a "$W/a/extracted/hello.txt")" = 400 ] \
     && python3 "$TOOLBELT/analysis_manifest.py" verify --root "$W/a" "$W/a/analysis-manifest.v1.json" >/dev/null 2>&1; then
    ok "5 good image: deterministic evidence, tree published 0700/0400, manifest verifies"
  else no "5 good image end to end"; fi

  # 6. a symlink in the image is rejected with the specific message and nothing is published
  rc=0; run "$FIX/sym.sqfs" "$W/sym" 2>"$W/sym.err" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/sym" ] && [ ! -e "$W/.sym.stage" ] && grep -qF 'symlink in extracted tree (rejected): escape' "$W/sym.err"; then
    ok "6 symlink in the image: exit 2, 'symlink in extracted tree (rejected)', nothing published, stage removed"
  else no "6 symlink rejection (rc=$rc)"; fi

  # 7. a blob that is not a SquashFS image is rejected with the specific message
  printf 'this is not a squashfs image' > "$W/blob.bin"
  rc=0; run "$W/blob.bin" "$W/blob_out" 2>"$W/blob.err" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/blob_out" ] && grep -qF 'input too small for a SquashFS superblock' "$W/blob.err"; then
    ok "7 non-SquashFS blob: exit 2, 'input too small for a SquashFS superblock', nothing published"
  else no "7 blob rejection (rc=$rc)"; fi

  # 8. caps: --max-entries 1 on a multi-entry tree is rejected before publication
  rc=0; run "$FIX/good.sqfs" "$W/cap" --max-entries 1 2>"$W/cap.err" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/cap" ] && grep -qF 'entries exceed max-entries (1)' "$W/cap.err"; then
    ok "8 --max-entries 1: exit 2, 'entries exceed max-entries (1)', nothing published"
  else no "8 entries cap (rc=$rc)"; fi

  # 9. an existing destination is never replaced
  mkdir -m 700 "$W/exists"; printf keep > "$W/exists/marker"
  rc=0; run "$FIX/good.sqfs" "$W/exists" 2>"$W/ex.err" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ "$(cat "$W/exists/marker")" = keep ] && grep -qF 'unsafe output destination' "$W/ex.err"; then
    ok "9 existing destination: exit 2, 'unsafe output destination', contents untouched"
  else no "9 existing destination (rc=$rc)"; fi
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for squashfs-extract.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/squashfs-extract.sh" "$2" 2>/dev/null; then MS="$d/squashfs-extract.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: the caller's arguments are no longer forwarded
  if mk A 's#"\$_RSDD_SELF/analysis_manifest.py" "\$@"#"$_RSDD_SELF/analysis_manifest.py"#'; then
    shim_run "$MS" --input x --output y
    [ "$SOUT" != $'ARG[formats]\nARG[squashfs-extract]\nARG[--manifest-cli]\nARG['"$(cd "$(dirname "$MS")" && pwd -P)"$'/analysis_manifest.py]\nARG[--input]\nARG[x]\nARG[--output]\nARG[y]' ] \
      && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#rsdd_exec formats squashfs-extract#rsdd_exec formats squashfs-extrac#'; then
    shim_run "$MS" --input x
    case "$SOUT" in *'ARG[squashfs-extract]'*) no "teeth B: mutant still names squashfs-extract — THEATER" ;; *) ok "teeth B: wrong command name -> forwarding check goes red" ;; esac
  fi
  # C: the degraded path swallowed (library guard exits 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/squashfs-extract.sh"
    out="$(bash "$TMP/mt/C-nolib/squashfs-extract.sh" --input x --output y 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec formats squashfs-extract \(.*\)$#( rsdd_exec formats squashfs-extract \1 ); exit 0#'; then
    shim_run "$MS" --input x
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the manifest tool is no longer handed over (the sibling analysis_manifest.py)
  if mk E 's#--manifest-cli "\$_RSDD_SELF/analysis_manifest.py" ##'; then
    shim_run "$MS" --input x --output y
    case "$SOUT" in *'ARG[--manifest-cli]'*) no "teeth E: mutant still passes --manifest-cli — THEATER" ;; *) ok "teeth E: --manifest-cli dropped -> forwarding check goes red" ;; esac
  fi
  # F: the end-to-end group is real: a mutant that points the shim at the wrong command fails case 5
  if [ -z "$e2e_skip" ] && mk F 's#rsdd_exec formats squashfs-extract#rsdd_exec formats qnx6-read#'; then
    if RSDD_BIN="$real_rsdd" bash "$MS" --input "$FIX/good.sqfs" --output "$TMP/e2e/f" >/dev/null 2>&1; then no "teeth F: the wrong command still extracted — THEATER"
    else ok "teeth F: wrong command -> the end-to-end extraction goes red"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
