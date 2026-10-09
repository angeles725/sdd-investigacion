#!/usr/bin/env bash
# tests/corroborate-firmware.test.sh — corroborate-firmware adapter (lane-aware)
#
# Lane contract (lib/test-lane.sh):
#   fast (default) — live require_private/normalized import teeth + fixture assertions.
#                    Always runs; no binwalk/bwrap spawn required.  Anti-#128 WIN.
#   slow           — integration tests with real binwalk + bwrap.
#                    Skips with informational message when tools are absent.
#   all            — both lanes.
#
# Anti-#128 fix: FAST lane always runs.  The old whole-suite skip at lines 7-13
#   (SKIP: ... when bwrap OR binwalk absent; echo "== 0 passed · 0 failed =="; exit 0)
#   is DELETED.  FAST lane always emits a real pass/fail count, never 0/0.
#   SLOW lane emits an informational message and skips cleanly when tools are absent.
#
# R5 (manifest slow-only): FAST lane never reads or calls verify on
#   analysis-manifest.v1.json.  Manifest verify stays SLOW-only because
#   verify re-resolves the tool launcher on the live machine and would fail
#   on any other machine than where fixtures were captured.
#
# Exit 2 when SUT Python module is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(dirname "$HERE")"
SUT_SH="$TOOLBELT/corroborate-firmware.sh"
SUT_PY="$TOOLBELT/corroborate_firmware.py"
MAN="$TOOLBELT/analysis_manifest.py"

# Source lane helper (aborts on invalid RSDD_TEST_LANE value per §7 anti-silent-zero).
# shellcheck source=../lib/test-lane.sh
source "$TOOLBELT/lib/test-lane.sh"

# RED guard — exit 2 when the SUT Python module does not exist yet.
[ -f "$SUT_PY" ] || { echo "FATAL: SUT module not found: $SUT_PY" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# Active lane (aborts on invalid RSDD_TEST_LANE value).
_lane="$(rsdd_lane)"

# Fixture paths (cwd-independent; existence validated in the fast-lane section).
_FIX_HAPPY="$(rsdd_lane_fixture corroborate-firmware happy)"
_FIX_CAPPED="$(rsdd_lane_fixture corroborate-firmware capped)"

_slow_skip=1  # default; set to 0 only when slow lane actually runs

# ---------------------------------------------------------------------------
# SLOW LANE — integration tests with real binwalk + bwrap
# ---------------------------------------------------------------------------
if [[ "$_lane" == "slow" || "$_lane" == "all" ]]; then
  _slow_skip=0
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "SLOW lane: 'bwrap' not found; slow-lane tests skipped." >&2
    _slow_skip=1
  elif [ ! -x "$SUT_SH" ]; then
    echo "SLOW lane: SUT shell wrapper not found: $SUT_SH" >&2; _slow_skip=1
  fi
  # S1-S3 need the REAL analyzer: the PATH-selected binwalk (or RSDD_BINWALK, #1641) and S2 pins
  # engine.version 2.3.3 (the version IS the assertion). A host without exactly that analyzer cannot
  # run them: environmental, so a typed, counted SKIP (run-all counts "  SKIP  "), never a FAIL and
  # never a silent pass (#1588). S4-S15 use RSDD_BINWALK_TEST_ONLY / RSDD_BINWALK fakes and keep running.
  _REAL_CASES=(S1 S2 S3)   # the real-binwalk cases a SKIP reports, one line each
  _real_reason=""; _real_bw="$(command -v binwalk || true)"
  if [ -z "$_real_bw" ]; then
    _real_reason="no binwalk on PATH"
  elif _bw_help="$("$_real_bw" --help 2>&1)"; [[ "$_bw_help" != *"Binwalk v2.3.3"* ]]; then
    _real_reason="PATH binwalk ($_real_bw) is not v2.3.3 (S2 pins engine.version 2.3.3; only binwalk major 2 is supported)"
  fi

  if [[ "$_slow_skip" -eq 0 ]]; then
    ROOT="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap 'rm -rf "$ROOT"' EXIT

    run(){ "$SUT_SH" --input "$ROOT/fixture.bin" --output "$1" "${@:2}"; }
    # A root-owned PATH binwalk exercises the default (root-only) branch; a user-owned one needs the explicit env.
    if [ "$(stat -c %u "$(readlink -f "${_real_bw:-/nonexistent}")" 2>/dev/null)" = 0 ]; then real_run(){ run "$@"; }
    else real_run(){ RSDD_BINWALK="$_real_bw" run "$@"; }; fi
    mkfake(){ mkdir -p "$ROOT/$1"; cat >"$ROOT/$1/binwalk"; chmod +x "$ROOT/$1/binwalk"; }

    cat >"$ROOT/fixture.c" <<C
#include <stdio.h>
__attribute__((constructor)) static void marker(void){FILE*f=fopen("$ROOT/TARGET_EXECUTED","w");if(f)fclose(f);}
int main(void){return 0;}
C
    gcc -O0 -o "$ROOT/fixture.bin" "$ROOT/fixture.c"
    printf '\x89PNG\r\n\x1a\n' >>"$ROOT/fixture.bin"

    if [ -n "$_real_reason" ]; then
      for _c in "${_REAL_CASES[@]}"; do printf '  SKIP  %s real-binwalk case: %s\n' "$_c" "$_real_reason"; done
    else
      # S1: real Binwalk output is deterministic and target is never executed.
      if real_run "$ROOT/a" && real_run "$ROOT/b" \
        && cmp -s "$ROOT/a/firmware-static.v1.json" "$ROOT/b/firmware-static.v1.json" \
        && cmp -s "$ROOT/a/engine/signatures.json" "$ROOT/b/engine/signatures.json" \
        && cmp -s "$ROOT/a/engine/entropy.json" "$ROOT/b/engine/entropy.json" \
        && [ ! -e "$ROOT/TARGET_EXECUTED" ]; then
        ok "S1: real Binwalk evidence is deterministic and never executes the fixture"
      else no "S1: real deterministic static evidence"; fi

      # S2: report contract — schema, status, version, argv, isolation profile.
      if python3 - "$ROOT/a/firmware-static.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d['engine']
assert d['schema'] == 'firmware-static.v1' and d['status'] == 'complete' and e['version'] == '2.3.3'
assert e['trust'] in ('root-owned', 'user-owned-explicit'), e['trust']
assert e['argv'] == ['engine/binwalk', '-B', '-E', '-N', 'input/firmware.bin']
assert e['launcher']['source']['sha256'] == e['launcher']['staged']['sha256']
assert d['isolation']['profile'] == {
    'name': 'bubblewrap-static-network-denied', 'network_access': False,
    'static_only': True, 'target_execution': False}
PY
      then ok "S2: report binds staged launcher, fixed argv, and truthful isolation profile"
      else no "S2: report contract"; fi

      # S3: manifest validates and verifies (R5 — manifest verify is SLOW only).
      if python3 "$MAN" validate "$ROOT/a/engine/analysis-manifest.v1.json" \
        && python3 "$MAN" verify --root "$ROOT/a" "$ROOT/a/engine/analysis-manifest.v1.json"; then
        ok "S3: manifest validates and verifies"
      else no "S3: manifest verification"; fi

    fi

    # S4: preflight safety — symlink, output collision, PATH disagreement.
    ln -s "$ROOT/fixture.bin" "$ROOT/link.bin"
    mkdir "$ROOT/pathbad"; ln -s /usr/bin/true "$ROOT/pathbad/binwalk"
    if ! "$SUT_SH" --input "$ROOT/link.bin" --output "$ROOT/link-out" 2>/dev/null \
      && ! run "$ROOT/fixture.bin" 2>/dev/null \
      && ! PATH="$ROOT/pathbad:/usr/bin:/bin" run "$ROOT/path-mismatch" 2>/dev/null; then
      ok "S4: symlink, collision, and PATH disagreement fail closed"
    else no "S4: preflight safety"; fi

    # S5: dense and sparse oversized inputs reject without creating output.
    printf 12345 >"$ROOT/oversized.bin"; truncate -s 1048576 "$ROOT/sparse.bin"
    if ! "$SUT_SH" --input "$ROOT/oversized.bin" --output "$ROOT/oversized-out" \
         --max-input-bytes 4 2>/dev/null \
      && ! "$SUT_SH" --input "$ROOT/sparse.bin" --output "$ROOT/sparse-out" \
         --max-input-bytes 4 2>/dev/null \
      && [ ! -e "$ROOT/oversized-out" ] && [ ! -e "$ROOT/sparse-out" ]; then
      ok "S5: dense and sparse oversized inputs reject without output"
    else no "S5: input byte cap rejection"; fi

    # S6: foreign staging directory is preserved on collision.
    mkdir "$ROOT/.occupied.stage"; echo keep >"$ROOT/.occupied.stage/sentinel"
    if ! run "$ROOT/occupied" 2>/dev/null && [ -f "$ROOT/.occupied.stage/sentinel" ]; then
      ok "S6: foreign stage is preserved on collision"; else no "S6: stage collision"; fi

    # S7: finding cap publishes truthful partial evidence.
    mkfake capped_slow <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk vfake'; exit; }
printf '0 0x0 first\n1 0x1 second\n2 0x2 third\n'
SH
    if PATH="$ROOT/capped_slow:/usr/bin:/bin" \
         RSDD_BINWALK_TEST_ONLY="$ROOT/capped_slow/binwalk" \
         run "$ROOT/partial" --max-findings 2; [ "$?" -eq 1 ] \
      && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="partial" and d["counts"]=={
    "entropy_total":0,"findings_emitted":2,"findings_total":3,"signatures_total":3}
' "$ROOT/partial/firmware-static.v1.json"; then
      ok "S7: finding cap publishes truthful partial evidence"
    else no "S7: finding cap"; fi

    # S8: process cap kills and cleans the process tree.
    mkfake child <<SH
#!/bin/sh
[ "\$1" = --help ] && { echo 'Binwalk vfake'; exit; }
(sleep 2; touch "$ROOT/LEAKED_CHILD") &
sleep 5
SH
    if ! PATH="$ROOT/child:/usr/bin:/bin" \
           RSDD_BINWALK_TEST_ONLY="$ROOT/child/binwalk" \
           run "$ROOT/failed-child" --max-processes 1 \
      && sleep 3 \
      && [ ! -e "$ROOT/LEAKED_CHILD" ] \
      && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="failed" and "process-cap" in d["errors"]
' "$ROOT/failed-child/firmware-static.v1.json" \
      && python3 "$MAN" verify --root "$ROOT/failed-child" \
           "$ROOT/failed-child/engine/analysis-manifest.v1.json"; then
      ok "S8: process cap is verifiable and the complete process tree is cleaned"
    else no "S8: process cap cleanup"; fi

    # S9: diagnostic cap truncates 1MiB noisy output to the cap limit.
    mkfake noisy <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk vfake'; exit; }
dd if=/dev/zero bs=1M count=1 2>/dev/null
SH
    if ! PATH="$ROOT/noisy:/usr/bin:/bin" \
           RSDD_BINWALK_TEST_ONLY="$ROOT/noisy/binwalk" \
           run "$ROOT/noisy-out" --max-diagnostic-bytes 4096 \
      && [ "$(wc -c <"$ROOT/noisy-out/engine/stdout.txt")" -le 4096 ] \
      && grep -q diagnostic-cap "$ROOT/noisy-out/firmware-static.v1.json"; then
      ok "S9: 1MiB output is execution-time bounded by a 4KiB file cap"
    else no "S9: diagnostic cap"; fi

    # S10: rc=1 path emits warn_evidence stderr pointer (§7 anti-silent-zero).
    mkfake fail9 <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk vfake'; exit; }
exit 9
SH
    if ! PATH="$ROOT/fail9:/usr/bin:/bin" \
           RSDD_BINWALK_TEST_ONLY="$ROOT/fail9/binwalk" \
           run "$ROOT/warn-fw-ptr" 2>"$ROOT/fw-warn.err" \
      && grep -q 'firmware-static.v1' "$ROOT/fw-warn.err" \
      && grep -q 'firmware-static.v1.json' "$ROOT/fw-warn.err"; then
      ok "S10: rc=1 path emits warn_evidence pointer for firmware-static.v1 in stderr"
    else no "S10: warn-firmware warn_evidence pointer missing from stderr"; fi

    # S11: privileged-execution guard (integration/monkeypatch; SLOW only).
    # geteuid monkeypatched → 0; main() must return 2 with "root or set-id" in stderr.
    # The substring "root or set-id" is the real tooth — rc=2 alone is not unique.
    if python3 - "$SUT_PY" <<'PY'
import importlib.util, io, pathlib, sys
s = importlib.util.spec_from_file_location("fw", sys.argv[1])
f = importlib.util.module_from_spec(s)
s.loader.exec_module(f)
buf = io.StringIO(); f.os.geteuid = lambda: 0
sys.stderr = buf
r = f.main(["--input", "x", "--output", "y", "--manifest-cli", "z"])
sys.stderr = sys.__stderr__
assert r == 2 and "root or set-id" in buf.getvalue(), \
    f"rc={r!r}, stderr={buf.getvalue()!r}"
PY
    then ok "S11: privileged-execution guard: geteuid=0 → rc=2 + 'root or set-id' in stderr"
    else no "S11: privileged-execution guard"; fi

    # S12: source mutation after staging cannot alter analyzed bytes.
    mkfake slow_stage <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk vfake'; exit; }
sleep 1; echo '0 0x0 staged source'
SH
    before="$(sha256sum "$ROOT/fixture.bin" | cut -d' ' -f1)"
    PATH="$ROOT/slow_stage:/usr/bin:/bin" \
      RSDD_BINWALK_TEST_ONLY="$ROOT/slow_stage/binwalk" \
      run "$ROOT/source-swap" & pid=$!
    for _ in $(seq 1 300); do
      [ "$(stat -c %a "$ROOT/.source-swap.stage/input/firmware.bin" 2>/dev/null)" = 400 ] \
        && break
      sleep .01
    done
    printf mutation >>"$ROOT/fixture.bin"; wait "$pid"; _sswap_rc=$?
    if [ "$_sswap_rc" -eq 0 ] && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["input"]["source"]["sha256"]=="sha256:"+sys.argv[2]==d["input"]["staged"]["sha256"]
' "$ROOT/source-swap/firmware-static.v1.json" "$before"; then
      ok "S12: source mutation after staging cannot change analyzed bytes"
    else no "S12: source staging mutation resistance"; fi

    # S13-S15 (#1641): the real-analyzer path is a PATH probe / RSDD_BINWALK, not a fixed /usr/bin/binwalk.
    mkfake v2fake <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk v2.3.3'; exit; }
printf '0 0x0 PNG image\n'
SH
    mkfake v3fake <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Usage: binwalk [OPTIONS] [FILE_NAME]'; exit; }
[ "$1" = --version ] && { echo 'binwalk 3.1.0'; exit; }
printf '0 0x0 PNG image\n'
SH
    # S13: an explicitly selected, user-owned v2 analyzer on PATH is used and reported as real (not a test override).
    if PATH="$ROOT/v2fake:/usr/bin:/bin" RSDD_BINWALK="$ROOT/v2fake/binwalk" run "$ROOT/s13" \
      && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="complete" and d["engine"]["test_override"] is False and d["engine"]["version"]=="2.3.3", d["engine"]
assert d["engine"]["trust"]=="user-owned-explicit", d["engine"]
assert any("not root-owned" in l for l in d["limitations"]) and not any("distro Binwalk package" in l for l in d["limitations"]), d["limitations"]
' "$ROOT/s13/firmware-static.v1.json"; then
      ok "S13: RSDD_BINWALK selects a PATH analyzer outside /usr/bin as real evidence"
    else no "S13: RSDD_BINWALK real-analyzer selection"; fi

    # S13b/c: RSDD_BINWALK is a REAL selection — used when another binwalk is first on PATH, and when PATH has none.
    if PATH="$ROOT/v3fake:$ROOT/v2fake:/usr/bin:/bin" RSDD_BINWALK="$ROOT/v2fake/binwalk" run "$ROOT/s13b" \
      && PATH="/usr/bin:/bin" RSDD_BINWALK="$ROOT/v2fake/binwalk" run "$ROOT/s13c" \
      && python3 -c '
import json,sys
for f in sys.argv[1:]:
    d=json.load(open(f)); assert d["status"]=="complete" and d["engine"]["version"]=="2.3.3", f
' "$ROOT/s13b/firmware-static.v1.json" "$ROOT/s13c/firmware-static.v1.json"; then
      ok "S13b/c: RSDD_BINWALK is used when not first on PATH and when PATH has no binwalk"
    else no "S13b/c: RSDD_BINWALK real selection"; fi

    # S14: a non-root-owned PATH analyzer without the explicit env is refused with a typed, actionable message.
    _s14_err="$(PATH="$ROOT/v2fake:/usr/bin:/bin" run "$ROOT/s14" 2>&1 >/dev/null)"; _s14_rc=$?
    if [ "$_s14_rc" -eq 2 ] && [[ "$_s14_err" == *"root-owned"* && "$_s14_err" == *"RSDD_BINWALK"* ]] && [ ! -e "$ROOT/s14" ]; then
      ok "S14: user-owned PATH analyzer without RSDD_BINWALK fails closed naming RSDD_BINWALK"
    else no "S14: untrusted PATH analyzer message (rc=$_s14_rc: $_s14_err)"; fi

    # S16: a group/world-writable analyzer directory is refused even for an explicit, user-owned binwalk.
    mkfake v2writable <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk v2.3.3'; exit; }
printf '0 0x0 PNG image\n'
SH
    chmod 777 "$ROOT/v2writable"
    _s16_err="$(PATH="$ROOT/v2writable:/usr/bin:/bin" RSDD_BINWALK="$ROOT/v2writable/binwalk" run "$ROOT/s16" 2>&1 >/dev/null)"; _s16_rc=$?
    if [ "$_s16_rc" -eq 2 ] && [[ "$_s16_err" == *"directory must be"* ]] && [ ! -e "$ROOT/s16" ]; then
      ok "S16: analyzer in a group/world-writable directory is refused"
    else no "S16: writable analyzer directory (rc=$_s16_rc: $_s16_err)"; fi

    # S17: a test-override run is not an explicit user-owned RSDD_BINWALK run: no "not root-owned" limitation.
    if PATH="$ROOT/v2fake:/usr/bin:/bin" RSDD_BINWALK_TEST_ONLY="$ROOT/v2fake/binwalk" run "$ROOT/s17" \
      && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["engine"]["trust"]=="test-override", d["engine"]
assert not any("not root-owned" in l for l in d["limitations"]), d["limitations"]
assert any("test analyzer" in l for l in d["limitations"]), d["limitations"]
' "$ROOT/s17/firmware-static.v1.json"; then
      ok "S17: test-override report has the test-analyzer limitation and no false not-root-owned line"
    else no "S17: test-override limitations"; fi

    # S15: an unsupported binwalk major is a typed refusal, not a silent mis-parse.
    _s15_err="$(PATH="$ROOT/v3fake:/usr/bin:/bin" RSDD_BINWALK="$ROOT/v3fake/binwalk" run "$ROOT/s15" 2>&1 >/dev/null)"; _s15_rc=$?
    if [ "$_s15_rc" -eq 2 ] && [[ "$_s15_err" == *"unsupported Binwalk version 3.1.0"* ]] && [ ! -e "$ROOT/s15" ]; then
      ok "S15: binwalk 3.x is refused with a typed unsupported-version error"
    else no "S15: unsupported major (rc=$_s15_rc: $_s15_err)"; fi

  fi # _slow_skip == 0
fi # slow | all

# ---------------------------------------------------------------------------
# FAST LANE — live require_private/normalized import teeth + fixture assertions
# ---------------------------------------------------------------------------
if [[ "$_lane" == "fast" || "$_lane" == "all" ]]; then

  # Anti-silent-zero §7: both fixtures must exist before asserting.
  for _fix in "$_FIX_HAPPY" "$_FIX_CAPPED"; do
    if [[ ! -f "$_fix" ]]; then
      echo "FATAL: fixture missing: $_fix" >&2
      echo "  Run: bash research-sdd/toolbelt/tests/regen-lane-fixtures.sh --suite corroborate-firmware" >&2
      exit 1
    fi
  done

  # F1: require_private live-import teeth — STRONGEST fast-lane assertion.
  # Imports the real SUT module and exercises require_private() with synthetic
  # mountinfo strings — no /proc I/O, fully pure.
  # Mutation control: remove 'ext4' from PRIVATE_FS → ext4 mount raises FirmwareError
  #   → the "ext4 must pass" assertion fires RED.
  if python3 - "$TOOLBELT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
import corroborate_firmware as fw

p = Path("/safe/out")
# Private fs — all must NOT raise.
for kind in ("ext4", "xfs", "btrfs", "tmpfs", "overlay"):
    fw.require_private(p, f"1 0 0:1 / /safe rw - {kind} disk rw")

# Non-private fs — all must raise FirmwareError.
errors = []
for kind in ("drvfs", "9p", "nfs4", "fuse.sshfs", "virtiofs"):
    try:
        fw.require_private(p, f"1 0 0:1 / /safe rw - {kind} disk rw")
        errors.append(f"MISSED: {kind} should raise FirmwareError but did not")
    except fw.FirmwareError:
        pass
if errors:
    print("\n".join(errors), file=__import__("sys").stderr)
    raise SystemExit(1)
print(f"OK: PRIVATE_FS passes ext4/xfs/btrfs/tmpfs/overlay; rejects drvfs/9p/nfs4/fuse.sshfs/virtiofs")
PY
  then ok "F1: require_private live-import: private fs passes, foreign fs raises FirmwareError"
  else no "F1: require_private live-import (fast-lane teeth)"; fi

  # F2: normalized live-import teeth — parses fake-binwalk stdout into signatures/entropy.
  # Imports the real SUT module and feeds it a temp file with known output.
  # Mutation control: break the sort inside normalized() → offset order wrong → RED.
  if python3 - "$TOOLBELT" <<'PY'
import sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
import corroborate_firmware as fw

# Write fake binwalk stdout to a temp file; normalized() requires a Path, not a string.
with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
    f.write("0 0x0 first\n1 0x1 second\n2 0x2 third\n")
    tmp_path = Path(f.name)

try:
    sigs, ent = fw.normalized(tmp_path)
    # No "entropy" keyword in the output → all 3 go to signatures.
    assert len(sigs) == 3, f"expected 3 signatures, got {len(sigs)}"
    assert len(ent) == 0, f"expected 0 entropy, got {len(ent)}"
    # sorted by (offset, description).
    offsets = [s["offset"] for s in sigs]
    assert offsets == [0, 1, 2], f"sort order wrong: {offsets}"
    assert sigs[0]["description"] == "first", f"description[0]={sigs[0]['description']!r}"
    print(f"OK: normalized() split={len(sigs)} sigs, {len(ent)} entropy, sorted by offset")
finally:
    tmp_path.unlink(missing_ok=True)
PY
  then ok "F2: normalized live-import: splits signatures/entropy and sorts by (offset, description)"
  else no "F2: normalized live-import (fast-lane teeth)"; fi

  # F3: happy fixture — schema, status, test_override, errors, counts, relative argv.
  # argv structural invariant is CHEAP (relative by construction) — the real
  # teeth are the live-import checks in F1/F2.
  if python3 - "$_FIX_HAPPY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "firmware-static.v1", \
    f"F3: schema={d.get('schema')!r}"
assert d.get("status") == "complete", \
    f"F3: status={d.get('status')!r}"
e = d.get("engine", {})
assert e.get("test_override") is True, \
    f"F3: engine.test_override must be True (fake-binwalk fixture)"
assert d.get("errors") == [], \
    f"F3: errors={d.get('errors')!r}"
counts = d.get("counts", {})
assert counts.get("findings_emitted", 0) >= 1, \
    f"F3: findings_emitted={counts.get('findings_emitted')!r}"
# argv structural invariant: all entries are relative or option strings (no abs paths).
argv = e.get("argv", [])
abs_in_argv = [x for x in argv if isinstance(x, str) and x.startswith("/")]
assert abs_in_argv == [], f"F3 (structural): argv contains absolute paths: {abs_in_argv!r}"
assert argv == ["engine/binwalk", "-B", "-E", "-N", "input/firmware.bin"], \
    f"F3: argv={argv!r}"
print(f"OK: schema=firmware-static.v1 status=complete emitted={counts['findings_emitted']}")
PY
  then ok "F3: happy fixture: schema, status=complete, test_override=True, errors=[], relative argv"
  else no "F3: happy fixture structural assertions"; fi

  # F4: sha256 equality pairs + relative logical paths.
  if python3 - "$_FIX_HAPPY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
inp = d.get("input", {})
# input sha256 equality: source == staged (same content, different roles).
assert inp["source"]["sha256"] == inp["staged"]["sha256"], \
    f"F4: input sha256 mismatch: {inp['source']['sha256']!r} != {inp['staged']['sha256']!r}"
lnch = d.get("engine", {}).get("launcher", {})
# binwalk sha256 equality: source == staged (verified staging).
assert lnch["source"]["sha256"] == lnch["staged"]["sha256"], \
    f"F4: binwalk sha256 mismatch: {lnch['source']['sha256']!r} != {lnch['staged']['sha256']!r}"
# Relative logical paths must NOT be normalized away.
assert inp["staged"]["path"] == "input/firmware.bin", \
    f"F4: staged input path={inp['staged']['path']!r}"
assert lnch["staged"]["path"] == "engine/binwalk", \
    f"F4: staged launcher path={lnch['staged']['path']!r}"
sha_i = inp["source"]["sha256"]
sha_b = lnch["source"]["sha256"]
print(f"OK: sha_input={sha_i!r} sha_binwalk={sha_b!r}")
PY
  then ok "F4: sha256 equality pairs + relative logical paths (input/firmware.bin, engine/binwalk)"
  else no "F4: sha256 equality / path invariants (fixture)"; fi

  # F5: capped fixture — partial status, emitted=2, total=3 (combined, not emitted).
  # This anchors the cap-line-239 mutation: SUT line 239 uses len(combined) for
  # findings_total (CORRECT); mutating to len(emitted) drops total from 3 to 2
  # and this assertion fires RED.
  if python3 - "$_FIX_CAPPED" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "partial", \
    f"F5: status={d.get('status')!r} (expected partial)"
counts = d.get("counts", {})
assert counts.get("findings_emitted") == 2, \
    f"F5: findings_emitted={counts.get('findings_emitted')!r} (expected 2)"
assert counts.get("findings_total") == 3, \
    f"F5: findings_total={counts.get('findings_total')!r} (expected 3 = len(combined), not len(emitted))"
assert d.get("truncated", {}).get("findings") is True, \
    f"F5: truncated.findings must be True"
print(f"OK: status=partial emitted=2 total=3 (combined>max_findings → truncated)")
PY
  then ok "F5: capped fixture: status=partial, emitted=2, total=3, truncated=True (cap-line-239 anchor)"
  else no "F5: capped fixture structural assertions"; fi

  # F6 (#1641): binwalk_version parses the 2.x and 3.x banners and refuses to read the usage line as a version.
  if python3 - "$TOOLBELT" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
import corroborate_firmware as fw
cases = {"Binwalk v2.3.3\nCraig": "2.3.3", "binwalk 3.1.0\n": "3.1.0",
         "Usage: binwalk [OPTIONS] [FILE_NAME]": None, "Binwalk vfake": "fake", "": None}
for text, want in cases.items():
    got = fw.binwalk_version(text)
    assert got == want, f"{text!r}: {got!r} != {want!r}"
for version, refused in (("2.3.3", False), ("3.1.0", True), ("10.0", True)):
    try: fw.check_binwalk_version(version)
    except fw.FirmwareError: assert refused, f"{version} refused"
    else: assert not refused, f"{version} accepted"
print("OK: binwalk_version")
PY
  then ok "F6: binwalk_version reads 2.x/3.x banners and ignores the usage line"
  else no "F6: binwalk_version parsing"; fi

  # F7 (#1641): resolve_binwalk — PATH probe, explicit selection, trust rules, descriptor-level checks.
  if python3 - "$TOOLBELT" <<'PY'
import os, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
import corroborate_firmware as fw
def refused(env, needle):
    try: fw.resolve_binwalk(env)
    except fw.FirmwareError as exc: assert needle in str(exc), (needle, str(exc)); return
    raise SystemExit(f"accepted but must refuse ({needle}): {env}")
with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as other:
    b = Path(d) / "binwalk"; b.write_text("#!/bin/sh\n"); b.chmod(0o755)
    o = Path(other) / "binwalk"; o.write_text("#!/bin/sh\n"); o.chmod(0o755)
    path = f"{other}:{d}:/usr/bin:/bin"
    refused({"PATH": path}, "RSDD_BINWALK")                      # default branch is root-only
    got, _, trust, _ = fw.resolve_binwalk({"PATH": path, "RSDD_BINWALK": str(b)})
    assert got == b.resolve() and trust == "user-owned-explicit", (got, trust)   # real selection, not first on PATH
    got, _, _, _ = fw.resolve_binwalk({"PATH": "/nonexistent", "RSDD_BINWALK": str(b)}); assert got == b.resolve()
    refused({"PATH": path, "RSDD_BINWALK": "binwalk"}, "absolute")
    b.chmod(0o775); refused({"PATH": path, "RSDD_BINWALK": str(b)}, "non-writable"); b.chmod(0o755)
    os.chmod(d, 0o777); refused({"PATH": path, "RSDD_BINWALK": str(b)}, "directory"); os.chmod(d, 0o700)
    refused({"PATH": "/nonexistent"}, "missing")
    cwd = os.getcwd(); os.chdir(d)
    try: refused({"PATH": ".:/nonexistent"}, "missing"); refused({"PATH": ":/nonexistent"}, "missing")   # relative / empty entries are not searched
    finally: os.chdir(cwd)
    # the gate lives on the opened descriptor inside identity() and stage_file()
    for call in (lambda: fw.identity(b, trusted_uids=frozenset({0})), lambda: fw.stage_file(b, Path(d) / "copy", "x", 0o500, trusted_uids=frozenset({0}))):
        try: call()
        except fw.FirmwareError as exc: assert "root-owned" in str(exc), exc
        else: raise SystemExit("descriptor-level trust gate missing")
    # the trust label comes from the same checked descriptor (uid_sink), not a second path stat
    sink = {}; fw.identity(b, trusted_uids=frozenset({0, os.geteuid()}), uid_sink=sink); assert sink["uid"] == os.geteuid(), sink
    sink = {}; fw.stage_file(b, Path(d) / "copy2", "x", 0o500, trusted_uids=frozenset({0, os.geteuid()}), uid_sink=sink); assert sink["uid"] == os.geteuid(), sink
print("OK: resolve_binwalk")
PY
  then ok "F7: resolve_binwalk selects explicitly, refuses untrusted owner/mode/directory, ignores relative PATH entries"
  else no "F7: resolve_binwalk selection"; fi

fi # fast | all

# ---------------------------------------------------------------------------
# --prove-teeth: mutation controls (no bwrap/binwalk required)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth: corroborate-firmware mutation controls --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_built mutant_tooth mutant_cleanup_register mutant_chain_or_count mutant_built_or_count || exit 2
  # The mutants are python/json files: skip the bash -n check (empty, identical, live-tree,
  # symlink and dead-stage refusals still apply).
  # The lane's own EXIT trap (ROOT cleanup) is chained by the registry, never replaced.
  _MUT="$(mktemp -d)"; mutant_cleanup_register "$_MUT"
  _tt() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  # corroborate_firmware.py does `sys.path.insert(0, <own dir>); from lib.adapter_core import ...`
  # (SUT lines 10-13), so each mutant lives in its own dir next to a copy of lib/.
  # mut_py LABEL DIR SED_EXPR — build DIR/corroborate_firmware.py from the SUT; returns non-zero
  # (counted as a failure) when the mutant was refused, so its tooth never runs.
  mut_py() {
    if ! { mkdir -p "$_MUT/$2" && cp -R "$TOOLBELT/lib" "$_MUT/$2/lib"; }; then fail=$((fail+1)); return 1; fi
    MUTANT_SYNTAX=none mutant_chain_or_count fail "$1" "$SUT_PY" "$_MUT/$2/corroborate_firmware.py" "$3"   # counts a refusal exactly once
  }

  # tooth-require_private: remove 'ext4' from PRIVATE_FS so an ext4 mount is rejected instead of
  # accepted (F1 "ext4 must pass"). Same harness on both: it prints which way ext4 went.
  cat > "$_MUT/h1.py" <<'PY'
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("fw_under_test", pathlib.Path(sys.argv[1]).resolve())
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
try:
    m.require_private(pathlib.Path("/safe/out"), "1 0 0:1 / /safe rw - ext4 disk rw")
except m.FirmwareError:
    print("VERDICT: ext4 rejected")
else:
    print("VERDICT: ext4 accepted")
PY
  mut_py "tooth-require_private" t1 's/"ext4", "f2fs"/"f2fs"/' \
    && _tt "tooth-require_private: ext4 removed from PRIVATE_FS → ext4 raises → F1 RED (bites)" 0 0 "$_MUT/t1/corroborate_firmware.py" --orig "$SUT_PY" \
         --good-has '^VERDICT: ext4 accepted$' --bad-has '^VERDICT: ext4 rejected$' --bad-lacks '^VERDICT: ext4 accepted$' -- \
         python3 "$_MUT/h1.py" @SUT@

  # tooth-normalized: replace sorted() with reversed() so offset order breaks (F2). Input is in
  # 0,2,1 order: reversal gives [1,2,0], which differs from sorted [0,1,2] ([2,1,0] would be
  # accidentally correct under reversal). Each run gets a fresh scratch dir for its input file.
  cat > "$_MUT/h2.py" <<'PY'
import sys, importlib.util, pathlib, tempfile
spec = importlib.util.spec_from_file_location("fw_under_test", pathlib.Path(sys.argv[1]).resolve())
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as d:
    p = pathlib.Path(d) / "sigs.txt"
    p.write_text("0 0x0 alpha\n2 0x2 gamma\n1 0x1 beta\n")
    sigs, _ = m.normalized(p)
print("VERDICT: offsets", [s["offset"] for s in sigs])
PY
  mut_py "tooth-normalized" t2 's/^    return sorted(signatures, key=key), sorted(entropy, key=key)$/    return list(reversed(signatures)), list(reversed(entropy))/' \
    && _tt "tooth-normalized: reversed() sort → offset order wrong → F2 RED (bites)" 0 0 "$_MUT/t2/corroborate_firmware.py" --orig "$SUT_PY" \
         --good-has '^VERDICT: offsets \[0, 1, 2\]$' --bad-has '^VERDICT: offsets \[1, 2, 0\]$' --bad-lacks '^VERDICT: offsets \[0, 1, 2\]$' -- \
         python3 "$_MUT/h2.py" @SUT@

  # tooth-cap-line-239: len(combined)→len(emitted) drops findings_total 3→2 (F5). Proven at the
  # fixture level (no bwrap needed): the mutant fixture has findings_total == findings_emitted,
  # and F5's assertion (findings_total == 3) runs on the original and on the mutant fixture.
  if [[ ! -f "$_FIX_CAPPED" ]]; then
    no "tooth-cap-line-239: capped fixture missing (run regen first)"
  else
    python3 - "$_FIX_CAPPED" "$_MUT/mutant-capped.json" <<'PY'
import json, sys, pathlib
d = json.load(open(sys.argv[1]))
d["counts"]["findings_total"] = d["counts"]["findings_emitted"]
pathlib.Path(sys.argv[2]).write_text(json.dumps(d, indent=2))
PY
    cat > "$_MUT/h3.py" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])).get("counts", {}).get("findings_total")
print("VERDICT: F5 holds" if t == 3 else f"VERDICT: F5 RED findings_total={t}")
PY
    if MUTANT_SYNTAX=none mutant_built_or_count fail "tooth-cap-line-239" "$_FIX_CAPPED" "$_MUT/mutant-capped.json"; then
      _tt "tooth-cap-line-239: mutant fixture (total=emitted=2) → F5 total==3 assertion RED (bites)" 0 0 "$_MUT/mutant-capped.json" --orig "$_FIX_CAPPED" \
        --good-has '^VERDICT: F5 holds$' --bad-has '^VERDICT: F5 RED findings_total=2$' --bad-lacks '^VERDICT: F5 holds$' -- \
        python3 "$_MUT/h3.py" @SUT@
    fi   # a refused build was already counted once by mutant_built_or_count
  fi

  # tooth-binwalk-trust / tooth-binwalk-major (#1641): the ownership/mode gate and the major-version
  # gate each have their own mutant. The harness prints how each gate behaved on a user-owned,
  # group-writable analyzer and on a 3.x version.
  cat > "$_MUT/h4.py" <<'PY'
import sys, importlib.util, pathlib, tempfile
spec = importlib.util.spec_from_file_location("fw_under_test", pathlib.Path(sys.argv[1]).resolve())
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as d:
    b = pathlib.Path(d) / "binwalk"; b.write_text("#!/bin/sh\n"); b.chmod(0o775)
    try: m.resolve_binwalk({"PATH": d + ":/usr/bin", "RSDD_BINWALK": str(b)})
    except m.FirmwareError: print("VERDICT: trust refused")
    else: print("VERDICT: trust accepted")
try: m.check_binwalk_version("3.1.0")
except m.FirmwareError: print("VERDICT: major refused")
else: print("VERDICT: major accepted")
PY
  mut_py "tooth-binwalk-trust" t4 's/^    if meta.st_uid not in trusted_uids or meta.st_mode \& 0o022:$/    if False:/' \
    && _tt "tooth-binwalk-trust: ownership/mode gate removed → group-writable analyzer accepted → F7 RED (bites)" 0 0 "$_MUT/t4/corroborate_firmware.py" --orig "$SUT_PY" \
         --good-has '^VERDICT: trust refused$' --bad-has '^VERDICT: trust accepted$' --bad-lacks '^VERDICT: trust refused$' -- \
         python3 "$_MUT/h4.py" @SUT@
  mut_py "tooth-binwalk-major" t5 's/^    if version.split(".")\[0\] != SUPPORTED_BINWALK_MAJOR:$/    if False:/' \
    && _tt "tooth-binwalk-major: major gate removed → 3.1.0 accepted → F6 RED (bites)" 0 0 "$_MUT/t5/corroborate_firmware.py" --orig "$SUT_PY" \
         --good-has '^VERDICT: major refused$' --bad-has '^VERDICT: major accepted$' --bad-lacks '^VERDICT: major refused$' -- \
         python3 "$_MUT/h4.py" @SUT@

  # tooth-binwalk-uids / -parent / -relative-path / -fd-gate (#1641): one harness prints each gate's verdict.
  cat > "$_MUT/h6.py" <<'PY'
import os, sys, importlib.util, pathlib, tempfile
spec = importlib.util.spec_from_file_location("fw_under_test", pathlib.Path(sys.argv[1]).resolve())
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def verdict(name, env):
    try: m.resolve_binwalk(env)
    except m.FirmwareError as exc: print(f"VERDICT: {name} refused"); print(f"DETAIL: {name} {'missing' if 'missing' in str(exc) else 'other'}")
    else: print(f"VERDICT: {name} accepted")
with tempfile.TemporaryDirectory() as d:
    b = pathlib.Path(d) / "binwalk"; b.write_text("#!/bin/sh\n"); b.chmod(0o755)
    verdict("default-uid", {"PATH": d + ":/usr/bin"})
    os.chmod(d, 0o777); verdict("parent", {"PATH": d, "RSDD_BINWALK": str(b)}); os.chmod(d, 0o700)
    cwd = os.getcwd(); os.chdir(d)
    try: verdict("relative-path", {"PATH": ".:/nonexistent"})
    finally: os.chdir(cwd)
    try: m.identity(b, trusted_uids=frozenset({0})); print("VERDICT: fd-gate accepted")
    except m.FirmwareError: print("VERDICT: fd-gate refused")
    try: m.stage_file(b, pathlib.Path(d) / "staged", "x", 0o500, trusted_uids=frozenset({0})); print("VERDICT: stage-gate accepted")
    except m.FirmwareError: print("VERDICT: stage-gate refused")
PY
  mut_py "tooth-binwalk-uids" t6a 's/executable("binwalk", selected, search, frozenset({0}),/executable("binwalk", selected, search, frozenset({0, os.geteuid()}),/' \
    && _tt "tooth-binwalk-uids: default branch trusts the invoking uid → user-owned PATH binwalk accepted (bites)" 0 0 "$_MUT/t6a/corroborate_firmware.py" --orig "$SUT_PY" \
         --good-has '^VERDICT: default-uid refused$' --bad-has '^VERDICT: default-uid accepted$' --bad-lacks '^VERDICT: default-uid refused$' -- \
         python3 "$_MUT/h6.py" @SUT@
  mut_py "tooth-binwalk-parent" t6b 's/^    if parent.st_uid not in trusted_uids or parent.st_mode \& 0o022:$/    if False:/' \
    && _tt "tooth-binwalk-parent: directory check removed → analyzer in a world-writable directory accepted (bites)" 0 0 "$_MUT/t6b/corroborate_firmware.py" --orig "$SUT_PY" \
         --good-has '^VERDICT: parent refused$' --bad-has '^VERDICT: parent accepted$' --bad-lacks '^VERDICT: parent refused$' -- \
         python3 "$_MUT/h6.py" @SUT@
  mut_py "tooth-binwalk-relative-path" t6c 's/if os.path.isabs(entry))/if True)/' \
    && _tt "tooth-binwalk-relative-path: relative PATH entries kept → ./binwalk is searched (bites)" 0 0 "$_MUT/t6c/corroborate_firmware.py" --orig "$SUT_PY" \
         --good-has '^DETAIL: relative-path missing$' --bad-has '^DETAIL: relative-path other$' --bad-lacks '^DETAIL: relative-path missing$' -- \
         python3 "$_MUT/h6.py" @SUT@
  mut_py "tooth-binwalk-fd-gate" t6d 's/^        if trusted_uids is not None: require_trusted(before, resolved, trusted_uids, hint)$/        pass/' \
    && _tt "tooth-binwalk-fd-gate: identity() no longer gates on the descriptor → direct call accepts a user-owned file (bites)" 0 0 "$_MUT/t6d/corroborate_firmware.py" --orig "$SUT_PY" \
         --good-has '^VERDICT: fd-gate refused$' --bad-has '^VERDICT: fd-gate accepted$' --bad-lacks '^VERDICT: fd-gate refused$' -- \
         python3 "$_MUT/h6.py" @SUT@

  mut_py "tooth-binwalk-stage-gate" t6e 's/^        if trusted_uids is not None: require_trusted(before, resolved, trusted_uids, "")$/        pass/' \
    && _tt "tooth-binwalk-stage-gate: stage_file() no longer gates the bytes it copies → direct call accepts a user-owned file (bites)" 0 0 "$_MUT/t6e/corroborate_firmware.py" --orig "$SUT_PY" \
         --good-has '^VERDICT: stage-gate refused$' --bad-has '^VERDICT: stage-gate accepted$' --bad-lacks '^VERDICT: stage-gate refused$' -- \
         python3 "$_MUT/h6.py" @SUT@

  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
