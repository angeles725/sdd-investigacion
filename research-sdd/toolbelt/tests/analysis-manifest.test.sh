#!/usr/bin/env bash
# analysis-manifest.test.sh — black-box tests of the analysis_manifest.py entry point.
#
# analysis_manifest.py was ported to Go (internal/adapter, `rsdd adapter manifest`, kit issue #2390). The
# contract itself (every fail-closed rule, the canonical bytes, the argparse surface and its exit codes) is
# pinned by Go parity tests that drive THIS module as the oracle (TestParityManifest*, TestParity*Path,
# TestParitySafeArgv, ...) and by Go-only tests (descriptor-change and launcher-swap hooks, the 0600 atomic
# write). What stays here exercises the entry point and its shim: the CLI run as `python3 analysis_manifest.py`
# (which is the Go binary), one fail-closed exit, the importable Python API the corroborate_* adapters keep
# using, and the shim's routing and fallbacks.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../analysis_manifest.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

python3 - "$SUT" <<'PY'
import copy
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sut = Path(sys.argv[1])
module_spec = importlib.util.spec_from_file_location("analysis_manifest", sut); module = importlib.util.module_from_spec(module_spec); module_spec.loader.exec_module(module)
passed = 0

def ok(name):
    global passed
    passed += 1
    print(f"  PASS  {name}")

def run(*args):
    return subprocess.run([sys.executable, str(sut), *map(str, args)], capture_output=True, text=True)

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    files = {
        "sample.bin": b"input\x00bytes",
        "bin/tool": b"#!/bin/false\n",
        "tools/vineflower.jar": b"jar bytes\n",
        "tools/plugin.jar": b"plugin bytes\n",
        "evidence/stdout.txt": b"finding\n",
        "evidence/stderr.txt": b"",
        "outputs/result.txt": b"result\n",
    }
    for name, content in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    (root / "bin/tool").chmod(0o700)

    spec = {
        "schema_version": "analysis-manifest.v1",
        "input": {"path": "sample.bin", "detected_type": "data"},
        "tool": {"name": "fixture", "version": "1.0", "executable": str(root / "bin/tool"), "artifacts": []},
        "argv": [str(root / "bin/tool"), "--inspect", "sample.bin"],
        "environment": {"LANG": "C.UTF-8", "TZ": "UTC"},
        "run": {"started_at": "2026-07-18T08:00:00Z", "ended_at": "2026-07-18T08:00:01Z", "duration_ms": 1000, "exit_code": 0, "signal": None},
        "stdout_path": "evidence/stdout.txt",
        "stderr_path": "evidence/stderr.txt",
        "outputs": ["outputs/result.txt"],
        "findings": [{"id": "F-1", "claim": "Observed fixture output", "evidence_locations": ["evidence/stdout.txt:1"]}],
        "limitations": [], "errors": [], "completeness": "complete",
        "isolation_profile": {"name": "wsl-static", "static_only": True, "network_access": False, "target_execution": False},
    }
    spec_path, manifest = root / "spec.json", root / "manifest.json"
    spec_path.write_text(json.dumps(spec))
    result = run("create", "--root", root, "--spec", spec_path, "--output", manifest)
    assert result.returncode == 0, result.stderr
    data = json.loads(manifest.read_text())
    assert data["input"]["sha256"] == "sha256:" + hashlib.sha256(files["sample.bin"]).hexdigest()
    assert data["tool"]["launcher"]["sha256"] == "sha256:" + hashlib.sha256(files["bin/tool"]).hexdigest()
    assert data["stdout"]["size"] == len(files["evidence/stdout.txt"])
    assert manifest.read_text() == json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    assert run("validate", manifest).returncode == 0
    ok("create captures file-backed identities and canonical JSON")

    bad = copy.deepcopy(spec); bad["outputs"] = ["../escape.bin"]
    (root / "bad.json").write_text(json.dumps(bad))
    rejected = run("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json")
    assert rejected.returncode == 2 and rejected.stderr.startswith("analysis-manifest: ") and not (root / "x.json").exists()
    ok("artifact path traversal fails closed")

    assert run("verify", "--root", root, manifest).returncode == 0
    (root / "outputs/result.txt").write_bytes(b"modified\n")
    assert run("validate", manifest).returncode == 0
    assert run("verify", "--root", root, manifest).returncode == 2
    (root / "outputs/result.txt").write_bytes(files["outputs/result.txt"])
    ok("explicit verification mode detects modified artifacts without execution")

    atomic_spec = copy.deepcopy(spec); atomic_spec["outputs"] = []
    (root / "atomic-spec.json").write_text(json.dumps(atomic_spec)); atomic = root / "atomic.json"
    assert run("create", "--root", root, "--spec", root / "atomic-spec.json", "--output", atomic).returncode == 0
    original = atomic.read_bytes()
    assert run("create", "--root", root, "--spec", root / "atomic-spec.json", "--output", atomic).returncode == 2 and atomic.read_bytes() == original
    assert run("create", "--overwrite", "--root", root, "--spec", root / "atomic-spec.json", "--output", atomic).returncode == 0
    assert not list(root.glob(".atomic.json.*.tmp"))
    ok("atomic create refuses replacement unless overwrite is explicit")

    # The importable API the corroborate_* adapters use is the Python implementation, unchanged, and it
    # builds byte-for-byte the manifest the CLI (the Go binary) wrote.
    built = module.build_manifest(json.loads(spec_path.read_text()), root)
    assert module.canonical_bytes(built) == manifest.read_bytes()
    module.validate_manifest(built); module.verify_artifacts(built, root)
    module_out = root / "module-out.json"; module._atomic_write(module_out, module.canonical_bytes(built), False)
    assert module_out.read_bytes() == manifest.read_bytes()
    ok("importable build/validate/verify/atomic-write API matches the CLI byte for byte")

    # Shim routing: with lib/rsdd-exec.sh beside the module the CLI is `rsdd adapter manifest` with the
    # arguments, stdin and exit code passed through; RSDD_BIN selects the binary.
    fake = root / "fake-rsdd"
    fake.write_text('#!/bin/sh\necho "ROUTED $*"; echo "ERR" >&2; exit 7\n'); fake.chmod(0o700)
    routed = subprocess.run([sys.executable, str(sut), "validate", "a b", "--odd"], capture_output=True, text=True, env={**os.environ, "RSDD_BIN": str(fake)})
    assert (routed.returncode, routed.stdout, routed.stderr) == (7, "ROUTED adapter manifest validate a b --odd\n", "ERR\n"), routed
    ok("entry-point shim hands the arguments, output and exit code to rsdd adapter manifest")

    # Fallbacks: no usable binary, or a copy of the module with no lib/ beside it, keep the Python CLI.
    unusable = subprocess.run([sys.executable, str(sut), "validate", str(manifest)], capture_output=True, text=True, env={**os.environ, "RSDD_BIN": str(root / "no-such-rsdd")})
    assert unusable.returncode == 0 and unusable.stdout == "" and unusable.stderr == "", unusable
    staged = root / "staged"; staged.mkdir(); (staged / "analysis_manifest.py").write_bytes(sut.read_bytes())
    alone = subprocess.run([sys.executable, str(staged / "analysis_manifest.py"), "validate", str(manifest)], capture_output=True, text=True, env={**os.environ, "RSDD_BIN": str(fake)})
    assert alone.returncode == 0 and "ROUTED" not in alone.stdout, alone
    ok("without a usable binary or a lib/ beside the module the Python CLI runs")

print(f"== {passed} passed · 0 failed ==")
PY
_main_exit=$?

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  _tp=0; _tf=0
  _tok(){ printf '  PASS  %s\n' "$1"; _tp=$((_tp+1)); }
  _tnok(){ printf '  FAIL  %s\n' "$1"; _tf=$((_tf+1)); }
  # Mutants are built in bash through lib/mutant.sh (refuses empty / byte-identical / live-tree / symlink
  # OUT). MUTANT_SYNTAX=none because the SUT is Python; a py compile check replaces `bash -n`.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_py_replace mutant_cleanup_register || exit 2
  _amt="$(mktemp -d)"; mutant_cleanup_register "$_amt"   # one shared EXIT trap, no hand-written copy
  # _am_mutant LABEL OLD NEW OUT -- replace the first OLD in the SUT with NEW through the shared
  # lib/mutant.sh builder. rc 2 = anchor absent (SUT changed), rc 3 = refused by the helper or not
  # valid Python; the refusal text goes to stderr.
  _am_mutant() { mutant_py_replace "$1" "$SUT" "$2" "$3" "$4"; }

  # teeth-traversal: removing ".." from _relative must let an intra-root traversal
  # (subdir/../result.txt) slip through -- proving the ".." guard is load-bearing.
  # The prior tooth used ../escape.bin which is independently caught by the root
  # constraint in _file_identity; that means the assertion still passed on a broken SUT
  # (defense-in-depth, not test isolation). The intra-root path stays within root, so
  # only the ".." guard can catch it: mutant accepts it (rc=0), SUT rejects it (rc=2).
  _am_mutant teeth-traversal 'any(part in ("", ".", "..") for part in path.parts)' \
    'any(part in ("", ".") for part in path.parts)' "$_amt/traversal.py"
  if [ $? -ne 0 ]; then (exit 2); else python3 - "$SUT" "$_amt/traversal.py" <<'PY'
import sys, json, subprocess, tempfile
from pathlib import Path
sut = Path(sys.argv[1]); mp = Path(sys.argv[2])
def run_sut(*args):
    return subprocess.run([sys.executable, str(sut), *map(str, args)], capture_output=True, text=True)
def run_mut(*args):
    return subprocess.run([sys.executable, str(mp), *map(str, args)], capture_output=True, text=True)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "sample.bin").write_bytes(b"hello")
    (root / "subdir").mkdir()                          # safe intermediate dir (stays in root)
    (root / "result.txt").write_bytes(b"output data")  # traversal target -- within root
    tool = root / "bin" / "tool"; tool.parent.mkdir(parents=True); tool.write_bytes(b"#!/bin/false\n"); tool.chmod(0o700)
    (root / "evidence").mkdir(); (root / "evidence" / "stdout.txt").write_bytes(b""); (root / "evidence" / "stderr.txt").write_bytes(b"")
    spec = {"schema_version": "analysis-manifest.v1",
            "input": {"path": "sample.bin", "detected_type": "data"},
            "tool": {"name": "t", "version": "1", "executable": str(tool), "artifacts": []},
            "argv": [str(tool)], "environment": {"LANG": "C.UTF-8"},
            "run": {"started_at": "2026-01-01T00:00:00Z", "ended_at": "2026-01-01T00:00:01Z",
                    "duration_ms": 1000, "exit_code": 0, "signal": None},
            "stdout_path": "evidence/stdout.txt", "stderr_path": "evidence/stderr.txt",
            "outputs": [], "findings": [], "limitations": [], "errors": [],
            "completeness": "complete",
            "isolation_profile": {"name": "wsl-static", "static_only": True,
                                  "network_access": False, "target_execution": False}}
    # intra-root traversal: subdir/../result.txt resolves to result.txt (within root)
    # root constraint will NOT catch this -- only the ".." guard in _relative does
    bad = dict(spec); bad["outputs"] = ["subdir/../result.txt"]
    (root / "bad.json").write_text(json.dumps(bad))
    r_sut = run_sut("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json")
    if r_sut.returncode != 2:
        print(f"TOOTH-PRECHECK-FAIL: SUT accepted intra-root traversal (rc={r_sut.returncode}); cannot prove tooth", file=sys.stderr)
        sys.exit(2)
    r_mut = run_mut("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json")
    if r_mut.returncode != 2:
        sys.exit(0)   # mutant accepts intra-root traversal -- ".." guard is load-bearing (has teeth)
    sys.exit(1)       # mutant still rejects -- ".." guard is redundant for this path (no teeth)
PY
  fi
  case $? in
    0) _tok "teeth-traversal: '..' guard isolated -- intra-root subdir/../result.txt accepted by mutant, rejected by SUT (has teeth)" ;;
    1) _tnok "teeth-traversal: '..' guard NOT isolated -- mutant still rejects intra-root traversal (no teeth)" ;;
    *) _tnok "teeth-traversal: mutation target not found or pre-check failed (SUT changed?)" ;;
  esac

  # teeth-shim-*: each shim decision, mutated in a copy that has lib/ linked beside it, must break the
  # routing scenario (fake rsdd exits 7 after printing the routed arguments) or the fallback scenario
  # (unusable RSDD_BIN must leave the Python CLI running with exit 0).
  _shim_tooth() { # LABEL OLD NEW
    local label="$1" dir="$_amt/shim-$1"
    mkdir -p "$dir" && ln -s "$HERE/../lib" "$dir/lib" || { _tnok "$label: cannot stage the mutant"; return; }
    _am_mutant "$label" "$2" "$3" "$dir/analysis_manifest.py"
    if [ $? -ne 0 ]; then _tnok "$label: mutation target not found or refused (SUT changed?)"; return; fi
    if python3 - "$dir/analysis_manifest.py" "$_amt" <<'PY'
import os, subprocess, sys
mut, tmp = sys.argv[1], sys.argv[2]
fake = os.path.join(tmp, "fake-rsdd"); open(fake, "w").write('#!/bin/sh\necho "ROUTED $*"; exit 7\n'); os.chmod(fake, 0o700)
def run(rsdd):
    r = subprocess.run([sys.executable, mut, "validate", "/nonexistent-manifest"], capture_output=True, text=True, env={**os.environ, "RSDD_BIN": rsdd})
    return r.returncode, r.stdout
routed, fallback = run(fake), run(os.path.join(tmp, "no-such-rsdd"))
sys.exit(0 if (routed != (7, "ROUTED adapter manifest validate /nonexistent-manifest\n") or fallback[0] != 2) else 1)
PY
    then _tok "$label: mutated shim deviates from the routing/fallback contract (has teeth)"
    else _tnok "$label: mutated shim still behaves as the contract (no teeth)"; fi
  }
  _shim_tooth teeth-shim-never-routes 'if not os.path.isfile(os.path.join(here, "lib", "rsdd-exec.sh")):' 'if True:'
  _shim_tooth teeth-shim-drops-exit-code 'return None if result.returncode == 97 else result.returncode' 'return None if result.returncode == 97 else 0'
  _shim_tooth teeth-shim-no-fallback 'return None if result.returncode == 97 else result.returncode' 'return result.returncode'

  echo "-- ${_tp} teeth-passed · ${_tf} teeth-failed --"
  [ "${_tf}" -eq 0 ] || _main_exit=1
fi

exit $_main_exit
