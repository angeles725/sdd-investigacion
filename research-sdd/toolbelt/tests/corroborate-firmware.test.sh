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
  for _cmd in binwalk bwrap; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
      echo "SLOW lane: '$_cmd' not found; slow-lane tests skipped." >&2
      _slow_skip=1; break
    fi
  done
  if [[ "$_slow_skip" -eq 0 ]] && [ ! -x "$SUT_SH" ]; then
    echo "SLOW lane: SUT shell wrapper not found: $SUT_SH" >&2; _slow_skip=1
  fi

  if [[ "$_slow_skip" -eq 0 ]]; then
    ROOT="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap 'rm -rf "$ROOT"' EXIT

    run(){ "$SUT_SH" --input "$ROOT/fixture.bin" --output "$1" "${@:2}"; }
    mkfake(){ mkdir -p "$ROOT/$1"; cat >"$ROOT/$1/binwalk"; chmod +x "$ROOT/$1/binwalk"; }

    cat >"$ROOT/fixture.c" <<C
#include <stdio.h>
__attribute__((constructor)) static void marker(void){FILE*f=fopen("$ROOT/TARGET_EXECUTED","w");if(f)fclose(f);}
int main(void){return 0;}
C
    gcc -O0 -o "$ROOT/fixture.bin" "$ROOT/fixture.c"
    printf '\x89PNG\r\n\x1a\n' >>"$ROOT/fixture.bin"

    # S1: real Binwalk output is deterministic and target is never executed.
    if run "$ROOT/a" && run "$ROOT/b" \
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

fi # fast | all

# ---------------------------------------------------------------------------
# --prove-teeth: mutation controls (no bwrap/binwalk required)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- prove-teeth: corroborate-firmware mutation controls --"

  # tooth-require_private: remove 'ext4' from PRIVATE_FS → ext4 mount raises
  # FirmwareError → F1 "ext4 must pass" assertion fires RED.
  _mut_dir_1="$(mktemp -d)"
  _mut_rc_1=0
  _RP_MARKER='PRIVATE_FS = {"btrfs", "ext2", "ext3", "ext4"'
  if ! grep -qF "$_RP_MARKER" "$SUT_PY"; then
    no "tooth-require_private: mutation marker not found in SUT (SUT changed?)"
  else
    python3 - "$SUT_PY" "$_mut_dir_1" "$TOOLBELT" <<'PY'
import sys, pathlib, shutil
sut = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
tb = pathlib.Path(sys.argv[3])
src = sut.read_text()
# Remove 'ext4' from PRIVATE_FS so ext4 mounts are no longer private.
mutated = src.replace('"ext4", "f2fs"', '"f2fs"', 1)
if mutated == src:
    print("MUTANT-SETUP-FAIL: 'ext4', 'f2fs' token not found in PRIVATE_FS", file=sys.stderr)
    sys.exit(2)
(out_dir / "corroborate_firmware.py").write_text(mutated)
shutil.copytree(str(tb / "lib"), str(out_dir / "lib"))
PY
    _setup_rc_1=$?
    if [[ "$_setup_rc_1" -ne 0 ]]; then
      no "tooth-require_private: mutant setup failed"
    else
      python3 - "$_mut_dir_1" <<'PY' || _mut_rc_1=$?
import sys, importlib.util, pathlib
mut_dir = pathlib.Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("fw_mut1", mut_dir / "corroborate_firmware.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
p = pathlib.Path("/safe/out")
try:
    m.require_private(p, "1 0 0:1 / /safe rw - ext4 disk rw")
    # ext4 did NOT raise → mutation has no teeth.
    print("MUTANT: ext4 did NOT raise FirmwareError — no teeth", file=sys.stderr)
    sys.exit(0)   # GREEN → no teeth
except m.FirmwareError:
    print("MUTANT: ext4 raised FirmwareError → has teeth", file=sys.stderr)
    sys.exit(1)   # RED → has teeth
PY
      if [[ "$_mut_rc_1" -ne 0 ]]; then
        ok "tooth-require_private: ext4 removed from PRIVATE_FS → ext4 raises → F1 RED (bites)"
      else
        no "tooth-require_private: ext4 removal had no effect — NO teeth"
      fi
    fi
  fi
  rm -rf "$_mut_dir_1"

  # tooth-normalized: replace sorted() with reversed() → offset order breaks →
  # F2 offset-order assertion fires RED.
  _mut_dir_2="$(mktemp -d)"
  _mut_rc_2=0
  _NORM_MARKER='    return sorted(signatures, key=key), sorted(entropy, key=key)'
  if ! grep -qF "$_NORM_MARKER" "$SUT_PY"; then
    no "tooth-normalized: sort marker not found in SUT (SUT changed?)"
  else
    python3 - "$SUT_PY" "$_mut_dir_2" "$TOOLBELT" <<'PY'
import sys, pathlib, shutil
sut = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
tb = pathlib.Path(sys.argv[3])
src = sut.read_text()
old = '    return sorted(signatures, key=key), sorted(entropy, key=key)\n'
if old not in src:
    print("MUTANT-SETUP-FAIL: normalized sort line not found", file=sys.stderr)
    sys.exit(2)
mutated = src.replace(old, '    return list(reversed(signatures)), list(reversed(entropy))\n', 1)
(out_dir / "corroborate_firmware.py").write_text(mutated)
shutil.copytree(str(tb / "lib"), str(out_dir / "lib"))
PY
    _setup_rc_2=$?
    if [[ "$_setup_rc_2" -ne 0 ]]; then
      no "tooth-normalized: mutant setup failed"
    else
      python3 - "$_mut_dir_2" <<'PY' || _mut_rc_2=$?
import sys, importlib.util, pathlib, tempfile
mut_dir = pathlib.Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("fw_mut2", mut_dir / "corroborate_firmware.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
# Input in 0,2,1 order: reversal gives [1,2,0], which differs from sorted [0,1,2].
# (Avoid [2,1,0] input: reversed([2,1,0])=[0,1,2] accidentally correct.)
with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
    f.write("0 0x0 alpha\n2 0x2 gamma\n1 0x1 beta\n")
    tmp = pathlib.Path(f.name)
try:
    sigs, _ = m.normalized(tmp)
    # With broken sort (reversed), first offset will NOT be 0 → RED.
    if not sigs or sigs[0]["offset"] != 0:
        print(f"MUTANT: sort broken → offset[0]={sigs[0]['offset'] if sigs else 'N/A'} != 0 → has teeth",
              file=sys.stderr)
        sys.exit(1)   # RED → has teeth
    else:
        print("MUTANT: sort still correct despite mutation — NO teeth", file=sys.stderr)
        sys.exit(0)   # GREEN → no teeth
finally:
    tmp.unlink(missing_ok=True)
PY
      if [[ "$_mut_rc_2" -ne 0 ]]; then
        ok "tooth-normalized: reversed() sort → offset order wrong → F2 RED (bites)"
      else
        no "tooth-normalized: sort mutation had no effect — NO teeth"
      fi
    fi
  fi
  rm -rf "$_mut_dir_2"

  # tooth-cap-line-239: len(combined)→len(emitted) drops findings_total 3→2 → F5 RED.
  # Proven at the fixture level (no bwrap needed):
  #   1. Construct a mutant fixture where findings_total == findings_emitted (== 2).
  #   2. Run F5's assertion against the mutant fixture.
  #   3. Assert the assertion FAILS (exits non-zero) — meaning the tooth bites.
  _mut_dir_3="$(mktemp -d)"
  _mut_rc_3=0
  if [[ ! -f "$_FIX_CAPPED" ]]; then
    no "tooth-cap-line-239: capped fixture missing (run regen first)"
  else
    python3 - "$_FIX_CAPPED" "$_mut_dir_3/mutant-capped.json" <<'PY'
import json, sys, pathlib
d = json.load(open(sys.argv[1]))
# Apply mutation: findings_total = findings_emitted (what len(emitted) would produce).
d["counts"]["findings_total"] = d["counts"]["findings_emitted"]
pathlib.Path(sys.argv[2]).write_text(json.dumps(d, indent=2))
PY
    # Run F5 assertion against the mutant fixture — it SHOULD fail (exit non-zero).
    python3 - "$_mut_dir_3/mutant-capped.json" <<'PY' || _mut_rc_3=$?
import json, sys
d = json.load(open(sys.argv[1]))
counts = d.get("counts", {})
# This is the F5 assertion — fires RED when findings_total != 3.
assert counts.get("findings_total") == 3, \
    f"findings_total={counts.get('findings_total')} (expected 3 = len(combined))"
PY
    if [[ "$_mut_rc_3" -ne 0 ]]; then
      ok "tooth-cap-line-239: mutant fixture (total=emitted=2) → F5 total==3 assertion RED (bites)"
    else
      no "tooth-cap-line-239: F5 stayed GREEN on wrong findings_total — NO teeth"
    fi
  fi
  rm -rf "$_mut_dir_3"

  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
