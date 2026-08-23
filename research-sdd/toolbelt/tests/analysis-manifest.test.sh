#!/usr/bin/env bash
# analysis-manifest.test.sh — focused contract tests for analysis-manifest.v1.
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

    later = copy.deepcopy(spec)
    later["run"].update(started_at="2026-07-19T09:00:00Z", ended_at="2026-07-19T09:00:03Z", duration_ms=3000)
    (root / "later.json").write_text(json.dumps(later))
    assert run("create", "--root", root, "--spec", root / "later.json", "--output", root / "later-manifest.json").returncode == 0
    assert json.loads((root / "later-manifest.json").read_text())["identity"] == data["identity"]
    ok("identity excludes volatile timing fields")

    bad = copy.deepcopy(spec); bad["outputs"] = ["../escape.bin"]
    (root / "bad.json").write_text(json.dumps(bad))
    assert run("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json").returncode == 2
    ok("artifact path traversal fails closed")

    for env, label in [({"PASSWORD": "value"}, "secret-like environment key"), ({"LANG": "Bearer abc123"}, "secret-like environment value")]:
        bad = copy.deepcopy(spec); bad["environment"] = env
        (root / "bad.json").write_text(json.dumps(bad))
        assert run("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json").returncode == 2
        ok(label + " fails closed")

    for mutate, label in [
        (lambda d: d["input"].update(sha256="sha256:bad"), "malformed hash"),
        (lambda d: d.update(schema_version="analysis-manifest.v2"), "unknown schema version"),
        (lambda d: d.pop("isolation_profile"), "missing required field"),
    ]:
        tampered = copy.deepcopy(data); mutate(tampered)
        path = root / "tampered.json"; path.write_text(json.dumps(tampered))
        assert run("validate", path).returncode == 2
        ok(label + " fails closed")

    hostile_paths = ["%2e%2e/escape", "%252e%252e%252Fescape", "..%2Fescape", "%2Fabsolute", "C:/drive", "file:payload"]
    for hostile in hostile_paths:
        path = root / hostile; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"hostile")
        bad = copy.deepcopy(spec); bad["outputs"] = [hostile]
        (root / "bad.json").write_text(json.dumps(bad))
        assert run("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json").returncode == 2, hostile
    ok("encoded, Windows-drive, and URI-like artifact paths fail closed")

    with tempfile.TemporaryDirectory() as external:
        outside = Path(external) / "outside"; outside.write_bytes(b"outside")
        link = root / "outputs/link"; link.symlink_to(outside)
        bad = copy.deepcopy(spec); bad["outputs"] = ["outputs/link"]
        (root / "bad.json").write_text(json.dumps(bad))
        assert run("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json").returncode == 2
    ok("artifact symlink escape remains rejected")

    for token in ("ghp_abcdefghijklmnopqrstuvwxyz1234567890", "xoxb-1234567890-secret"):
        bad = copy.deepcopy(spec); bad["environment"] = {"LANG": token}
        (root / "bad.json").write_text(json.dumps(bad))
        rejected = run("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json")
        assert rejected.returncode == 2 and token not in rejected.stderr
    ok("GitHub and Slack token families fail closed without disclosure")

    tampered = copy.deepcopy(data); tampered["tool"]["launcher"]["sha256"] = None
    stable = copy.deepcopy(tampered); stable.pop("identity")
    for field in ("started_at", "ended_at", "duration_ms"): stable["run"].pop(field)
    tampered["identity"] = "sha256:" + hashlib.sha256((json.dumps(stable, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest()
    (root / "tampered.json").write_text(json.dumps(tampered))
    assert run("validate", root / "tampered.json").returncode == 2
    ok("file-backed tool identity requires SHA-256")

    other = root / "bin/other"; other.write_bytes(b"#!/bin/true\n"); other.chmod(0o700)
    tampered = copy.deepcopy(data); tampered["tool"]["launcher"].update(resolved_executable=str(other), sha256="sha256:" + hashlib.sha256(other.read_bytes()).hexdigest()); tampered["identity"] = module._identity(tampered)
    (root / "incoherent.json").write_text(json.dumps(tampered))
    assert run("validate", root / "incoherent.json").returncode == 2
    ok("validate rejects a rehashed launcher unrelated to argv zero")

    assert run("verify", "--root", root, manifest).returncode == 0
    (root / "outputs/result.txt").write_bytes(b"modified\n")
    assert run("validate", manifest).returncode == 0
    assert run("verify", "--root", root, manifest).returncode == 2
    ok("explicit verification mode detects modified artifacts without execution")

    secret_spec = copy.deepcopy(spec); secret_spec["argv"] = [str(root / "bin/tool"), "--token", "ghp_abcdefghijklmnopqrstuvwxyz1234567890"]
    (root / "secret-spec.json").write_text(json.dumps(secret_spec))
    secret_result = run("create", "--root", root, "--spec", root / "secret-spec.json", "--output", root / "secret-manifest.json")
    assert secret_result.returncode == 2 and secret_spec["argv"][2] not in secret_result.stderr
    ok("secret-looking argv is rejected without persistence or disclosure")

    compound_value = "do-not-disclose-this-value"
    for option in ("--client-secret", "--access-token", "--refresh-token", "--password-file"):
        for suffix in ([option, compound_value], [f"{option}={compound_value}"]):
            bad = copy.deepcopy(spec); bad["outputs"] = []; bad["argv"] = [str(root / "bin/tool"), *suffix]
            (root / "compound-secret.json").write_text(json.dumps(bad))
            rejected = run("create", "--root", root, "--spec", root / "compound-secret.json", "--output", root / "compound-secret-manifest.json")
            assert rejected.returncode == 2 and compound_value not in rejected.stderr
    benign = copy.deepcopy(spec); benign["outputs"] = []; benign["argv"] = [str(root / "bin/tool"), "--tokenize", "sample.bin"]
    (root / "benign-option.json").write_text(json.dumps(benign))
    assert run("create", "--root", root, "--spec", root / "benign-option.json", "--output", root / "benign-option-manifest.json").returncode == 0
    ok("compound secret options fail closed without matching benign prefixes")

    atomic_spec = copy.deepcopy(spec); atomic_spec["outputs"] = []
    (root / "atomic-spec.json").write_text(json.dumps(atomic_spec)); atomic = root / "atomic.json"
    assert run("create", "--root", root, "--spec", root / "atomic-spec.json", "--output", atomic).returncode == 0
    original = atomic.read_bytes()
    assert run("create", "--root", root, "--spec", root / "atomic-spec.json", "--output", atomic).returncode == 2 and atomic.read_bytes() == original
    assert run("create", "--overwrite", "--root", root, "--spec", root / "atomic-spec.json", "--output", atomic).returncode == 0
    assert not list(root.glob(".atomic.json.*.tmp"))
    ok("atomic create refuses replacement unless overwrite is explicit")

    bare = copy.deepcopy(atomic_spec); bare["tool"]["executable"] = "tool"; bare["argv"][0] = "tool"; bare["environment"]["PATH"] = str(root / "bin")
    (root / "bare.json").write_text(json.dumps(bare)); bare_out = root / "bare-manifest.json"
    assert run("create", "--root", root, "--spec", root / "bare.json", "--output", bare_out).returncode == 0
    assert json.loads(bare_out.read_text())["tool"]["launcher"]["resolved_executable"] == str((root / "bin/tool").resolve())
    relative = copy.deepcopy(atomic_spec); relative["tool"]["executable"] = "bin/tool"; relative["argv"][0] = "bin/tool"
    (root / "relative.json").write_text(json.dumps(relative))
    assert run("create", "--root", root, "--spec", root / "relative.json", "--output", root / "relative-manifest.json").returncode == 0
    mismatch = copy.deepcopy(atomic_spec); mismatch["argv"][0] = str(other)
    (root / "mismatch.json").write_text(json.dumps(mismatch))
    assert run("create", "--root", root, "--spec", root / "mismatch.json", "--output", root / "mismatch-manifest.json").returncode == 2
    ok("tool identity binds to absolute, bare PATH, and root-relative argv zero")

    unresolved = copy.deepcopy(bare); unresolved["environment"]["PATH"] = str(root / "missing-bin")
    (root / "unresolved.json").write_text(json.dumps(unresolved))
    assert run("create", "--root", root, "--spec", root / "unresolved.json", "--output", root / "unresolved-manifest.json").returncode == 2
    nonexec = root / "bin/nonexec"; nonexec.write_bytes(b"not executable")
    bad_launcher = copy.deepcopy(atomic_spec); bad_launcher["tool"]["executable"] = str(nonexec); bad_launcher["argv"][0] = str(nonexec)
    (root / "nonexec.json").write_text(json.dumps(bad_launcher))
    assert run("create", "--root", root, "--spec", root / "nonexec.json", "--output", root / "nonexec-manifest.json").returncode == 2
    ok("unresolved and non-executable launchers fail closed")

    interpreted = copy.deepcopy(atomic_spec)
    interpreted["argv"] = [str(root / "bin/tool"), "-jar", "tools/vineflower.jar", "--plugin", "tools/plugin.jar"]
    interpreted["tool"]["artifacts"] = [{"path": "tools/vineflower.jar", "argv_index": 2}, {"path": "tools/plugin.jar", "argv_index": 4}]
    (root / "interpreted.json").write_text(json.dumps(interpreted)); interpreted_manifest = root / "interpreted-manifest.json"
    assert run("create", "--root", root, "--spec", root / "interpreted.json", "--output", interpreted_manifest).returncode == 0
    interpreted_data = json.loads(interpreted_manifest.read_text())
    assert [item["argv_index"] for item in interpreted_data["tool"]["artifacts"]] == [2, 4]
    assert interpreted_data["tool"]["artifacts"][0]["sha256"] == "sha256:" + hashlib.sha256(files["tools/vineflower.jar"]).hexdigest()
    for indices in ([0], [5], [2, 2]):
        bad = copy.deepcopy(interpreted); bad["tool"]["artifacts"] = [{"path": "tools/vineflower.jar", "argv_index": value} for value in indices]
        (root / "bad-artifacts.json").write_text(json.dumps(bad))
        assert run("create", "--root", root, "--spec", root / "bad-artifacts.json", "--output", root / "bad-artifacts-manifest.json").returncode == 2
    mismatch_artifact = copy.deepcopy(interpreted); mismatch_artifact["tool"]["artifacts"][0]["path"] = "tools/plugin.jar"
    (root / "mismatch-artifact.json").write_text(json.dumps(mismatch_artifact))
    assert run("create", "--root", root, "--spec", root / "mismatch-artifact.json", "--output", root / "mismatch-artifact-manifest.json").returncode == 2
    for path in ("tools/missing.jar", "tools/link.jar"):
        if path.endswith("link.jar"): (root / path).symlink_to(root / "tools/plugin.jar")
        bad = copy.deepcopy(interpreted); bad["argv"][2] = path; bad["tool"]["artifacts"][0]["path"] = path
        (root / "unsafe-artifact.json").write_text(json.dumps(bad))
        assert run("create", "--root", root, "--spec", root / "unsafe-artifact.json", "--output", root / "unsafe-artifact-manifest.json").returncode == 2
    (root / "tools/vineflower.jar").write_bytes(b"changed jar\n")
    assert run("verify", "--root", root, interpreted_manifest).returncode == 2
    ok("analysis artifacts bind exact nonzero argv positions and rehash on verify")

    with tempfile.TemporaryDirectory() as external:
        external_jar = Path(external) / "vineflower.jar"; external_jar.write_bytes(b"external jar\n")
        external_spec = copy.deepcopy(atomic_spec); external_spec["argv"] = [str(root / "bin/tool"), "-jar", str(external_jar)]
        external_spec["tool"]["artifacts"] = [{"path": str(external_jar), "argv_index": 2}]
        (root / "external.json").write_text(json.dumps(external_spec)); external_manifest = root / "external-manifest.json"
        assert run("create", "--root", root, "--spec", root / "external.json", "--output", external_manifest).returncode == 0
        assert json.loads(external_manifest.read_text())["tool"]["artifacts"][0]["path"] == str(external_jar)
        other_jar = Path(external) / "other.jar"; other_jar.write_bytes(b"other jar\n")
        mismatch = copy.deepcopy(external_spec); mismatch["tool"]["artifacts"][0]["path"] = str(other_jar)
        (root / "external-mismatch.json").write_text(json.dumps(mismatch))
        assert run("create", "--root", root, "--spec", root / "external-mismatch.json", "--output", root / "external-mismatch-manifest.json").returncode == 2
        external_jar.write_bytes(b"tampered jar\n")
        assert run("verify", "--root", root, external_manifest).returncode == 2
    ok("absolute external analysis artifacts preserve exact argv identity")

    with tempfile.TemporaryDirectory(dir=root.parent) as external:
        outside = Path(external); (outside / "tool").write_bytes(b"outside tool")
        (outside / "tool").chmod(0o700)
        escaped = copy.deepcopy(atomic_spec); escaped["tool"]["executable"] = "tool"; escaped["argv"][0] = "tool"; escaped["environment"]["PATH"] = f"../{outside.name}"
        (root / "escaped-path.json").write_text(json.dumps(escaped))
        assert run("create", "--root", root, "--spec", root / "escaped-path.json", "--output", root / "escaped-path-manifest.json").returncode == 2
        path_link = root / "outside-path"; path_link.symlink_to(outside, target_is_directory=True)
        linked_path = copy.deepcopy(escaped); linked_path["environment"]["PATH"] = "outside-path"
        (root / "linked-path.json").write_text(json.dumps(linked_path))
        assert run("create", "--root", root, "--spec", root / "linked-path.json", "--output", root / "linked-path-manifest.json").returncode == 2
        trusted = copy.deepcopy(escaped); trusted["environment"]["PATH"] = str(outside)
        (root / "trusted-path.json").write_text(json.dumps(trusted)); trusted_manifest = root / "trusted-path-manifest.json"
        assert run("create", "--root", root, "--spec", root / "trusted-path.json", "--output", trusted_manifest).returncode == 0
        assert json.loads(trusted_manifest.read_text())["tool"]["launcher"]["resolved_executable"] == str((outside / "tool").resolve())
    ok("relative PATH stays under root while absolute PATH is caller-trusted")

    duplicate = copy.deepcopy(atomic_spec); duplicate["findings"] = [copy.deepcopy(spec["findings"][0]), copy.deepcopy(spec["findings"][0])]
    (root / "duplicate.json").write_text(json.dumps(duplicate))
    assert run("create", "--root", root, "--spec", root / "duplicate.json", "--output", root / "duplicate-manifest.json").returncode == 2
    reversed_range = copy.deepcopy(atomic_spec); reversed_range["findings"][0]["evidence_locations"] = ["evidence/stdout.txt:3-2"]
    (root / "range.json").write_text(json.dumps(reversed_range))
    assert run("create", "--root", root, "--spec", root / "range.json", "--output", root / "range-manifest.json").returncode == 2
    out_of_bounds = copy.deepcopy(atomic_spec); out_of_bounds["findings"][0]["evidence_locations"] = ["evidence/stdout.txt:99"]
    (root / "bounds.json").write_text(json.dumps(out_of_bounds)); bounds = root / "bounds-manifest.json"
    assert run("create", "--root", root, "--spec", root / "bounds.json", "--output", bounds).returncode == 0
    assert run("validate", bounds).returncode == 0 and run("verify", "--root", root, bounds).returncode == 2
    ok("finding IDs and ordered ranges validate; verify enforces line bounds")

    inside_link = root / "outputs/inside-link"; inside_link.symlink_to(root / "sample.bin")
    linked = copy.deepcopy(atomic_spec); linked["outputs"] = ["outputs/inside-link"]
    (root / "linked.json").write_text(json.dumps(linked))
    assert run("create", "--root", root, "--spec", root / "linked.json", "--output", root / "linked-manifest.json").returncode == 2
    tool_link = root / "bin/tool-link"; tool_link.symlink_to(root / "bin/tool")
    linked_tool = copy.deepcopy(atomic_spec); linked_tool["tool"]["executable"] = str(tool_link); linked_tool["argv"][0] = str(tool_link)
    (root / "linked-tool.json").write_text(json.dumps(linked_tool))
    assert run("create", "--root", root, "--spec", root / "linked-tool.json", "--output", root / "linked-tool-manifest.json").returncode == 2
    real_fstat, calls = module.os.fstat, 0
    def changed_fstat(fd):
        nonlocal_calls[0] += 1; stat = real_fstat(fd)
        if nonlocal_calls[0] == 2:
            values = list(stat); values[8] += 1; return module.os.stat_result(values)
        return stat
    nonlocal_calls = [0]; module.os.fstat = changed_fstat
    try: module._file_identity(root / "sample.bin")
    except module.ManifestError: pass
    else: raise AssertionError("concurrent mutation was accepted")
    finally: module.os.fstat = real_fstat
    ok("stable descriptor hashing rejects final symlinks and fstat mutation")

    original_identity = module._file_identity
    def swapped_identity(path, constrained=None):
        result = original_identity(path, constrained)
        replacement = root / "bin/replacement"; replacement.write_bytes(b"#!/bin/false\n"); replacement.chmod(0o700); replacement.replace(path)
        return result
    module._file_identity = swapped_identity
    try: module._resolve_tool(str(root / "bin/tool"), str(root / "bin/tool"), root, {})
    except module.ManifestError: pass
    else: raise AssertionError("launcher replacement after hashing was accepted")
    finally: module._file_identity = original_identity
    ok("launcher replacement during generic identity resolution fails closed")

print(f"== {passed} passed · 0 failed ==")
PY
_main_exit=$?

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  _tp=0; _tf=0
  _tok(){ printf '  PASS  %s\n' "$1"; _tp=$((_tp+1)); }
  _tnok(){ printf '  FAIL  %s\n' "$1"; _tf=$((_tf+1)); }

  # teeth-traversal: removing ".." from _relative must let an intra-root traversal
  # (subdir/../result.txt) slip through -- proving the ".." guard is load-bearing.
  # The prior tooth used ../escape.bin which is independently caught by the root
  # constraint in _file_identity; that means the assertion still passed on a broken SUT
  # (defense-in-depth, not test isolation). The intra-root path stays within root, so
  # only the ".." guard can catch it: mutant accepts it (rc=0), SUT rejects it (rc=2).
  python3 - "$SUT" <<'PY'
import sys, json, subprocess, tempfile
from pathlib import Path
sut = Path(sys.argv[1]); src = sut.read_text()
old = 'any(part in ("", ".", "..") for part in path.parts)'
if old not in src:
    print("MUTANT-SETUP-FAIL: traversal guard not found -- SUT changed?", file=sys.stderr)
    sys.exit(2)
mut = src.replace(old, 'any(part in ("", ".") for part in path.parts)', 1)
mp = Path(tempfile.mkdtemp()) / "analysis_manifest.py"; mp.write_text(mut)
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
  case $? in
    0) _tok "teeth-traversal: '..' guard isolated -- intra-root subdir/../result.txt accepted by mutant, rejected by SUT (has teeth)" ;;
    1) _tnok "teeth-traversal: '..' guard NOT isolated -- mutant still rejects intra-root traversal (no teeth)" ;;
    *) _tnok "teeth-traversal: mutation target not found or pre-check failed (SUT changed?)" ;;
  esac

  # teeth-env-secret: neutralizing SECRET_VALUE_RE in sanitize_environment must let a
  # Bearer token in an allowlisted env key slip through (rc=0 instead of rc=2).
  # 'LANG' is in ENV_ALLOWLIST, so only SECRET_VALUE_RE.search(item) blocks 'Bearer abc123'.
  # With that check disabled the value passes; the assertion at lines ~87-91 goes RED.
  python3 - "$SUT" <<'PY'
import sys, json, subprocess, tempfile
from pathlib import Path
sut = Path(sys.argv[1]); src = sut.read_text()
old = "SECRET_VALUE_RE.search(item)"
if old not in src:
    print("MUTANT-SETUP-FAIL: SECRET_VALUE_RE.search(item) not found -- SUT changed?", file=sys.stderr)
    sys.exit(2)
mut = src.replace(old, "False  # MUTANT: secret value check disabled", 1)
mp = Path(tempfile.mkdtemp()) / "analysis_manifest.py"; mp.write_text(mut)
def run_sut(*args):
    return subprocess.run([sys.executable, str(sut), *map(str, args)], capture_output=True, text=True)
def run_mut(*args):
    return subprocess.run([sys.executable, str(mp), *map(str, args)], capture_output=True, text=True)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "sample.bin").write_bytes(b"hello")
    tool = root / "bin" / "tool"; tool.parent.mkdir(parents=True); tool.write_bytes(b"#!/bin/false\n"); tool.chmod(0o700)
    (root / "evidence").mkdir(); (root / "evidence" / "stdout.txt").write_bytes(b""); (root / "evidence" / "stderr.txt").write_bytes(b"")
    spec = {"schema_version": "analysis-manifest.v1",
            "input": {"path": "sample.bin", "detected_type": "data"},
            "tool": {"name": "t", "version": "1", "executable": str(tool), "artifacts": []},
            "argv": [str(tool)], "environment": {"LANG": "Bearer abc123"},
            "run": {"started_at": "2026-01-01T00:00:00Z", "ended_at": "2026-01-01T00:00:01Z",
                    "duration_ms": 1000, "exit_code": 0, "signal": None},
            "stdout_path": "evidence/stdout.txt", "stderr_path": "evidence/stderr.txt",
            "outputs": [], "findings": [], "limitations": [], "errors": [],
            "completeness": "complete",
            "isolation_profile": {"name": "wsl-static", "static_only": True,
                                  "network_access": False, "target_execution": False}}
    (root / "bad.json").write_text(json.dumps(spec))
    r_sut = run_sut("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json")
    if r_sut.returncode != 2:
        print(f"TOOTH-PRECHECK-FAIL: SUT accepted Bearer env value (rc={r_sut.returncode}); cannot prove tooth", file=sys.stderr)
        sys.exit(2)
    r_mut = run_mut("create", "--root", root, "--spec", root / "bad.json", "--output", root / "x.json")
    if r_mut.returncode != 2:
        sys.exit(0)   # mutant accepts Bearer value -- SECRET_VALUE_RE check is load-bearing (has teeth)
    sys.exit(1)       # mutant still rejects -- check is redundant or blocked elsewhere (no teeth)
PY
  case $? in
    0) _tok "teeth-env-secret: SECRET_VALUE_RE disabled -> Bearer env value accepted -> assertion fires RED (has teeth)" ;;
    1) _tnok "teeth-env-secret: mutant still rejects Bearer env value -- env-secret check may not be the sole isolator (no teeth)" ;;
    *) _tnok "teeth-env-secret: mutation target not found or pre-check failed (SUT changed?)" ;;
  esac

  # teeth-fstat: removing fstat mismatch check lets a concurrently modified file pass;
  # ManifestError is not raised -- assertion catches it -- has teeth.
  python3 - "$SUT" <<'PY'
import sys, types, tempfile
from pathlib import Path
sut = Path(sys.argv[1]); src = sut.read_text()
old = "        if fields(before) != fields(after) or total != before.st_size:"
if old not in src:
    print("MUTANT-SETUP-FAIL: fstat check line not found -- SUT changed?", file=sys.stderr)
    sys.exit(2)
mut = src.replace(old, "        if False:  # MUTANT: fstat mismatch check removed", 1)
m = types.ModuleType("analysis_manifest"); m.__file__ = str(sut)
exec(compile(mut, str(sut), "exec"), m.__dict__)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    f = root / "sample.bin"; f.write_bytes(b"input data")
    real_fstat = m.os.fstat; calls = [0]
    def patched_fstat(fd):
        calls[0] += 1; stat = real_fstat(fd)
        if calls[0] == 2:
            values = list(stat); values[8] += 1; return m.os.stat_result(values)
        return stat
    m.os.fstat = patched_fstat
    try:
        m._file_identity(f)
        sys.exit(1)   # no ManifestError -- fstat check removed -- has teeth
    except m.ManifestError:
        sys.exit(0)   # fstat check still fires without mutation -- no teeth
    finally:
        m.os.fstat = real_fstat
PY
  case $? in
    1) _tok "teeth-fstat: fstat removal -> concurrent mutation accepted -> assertion fires (has teeth)" ;;
    0) _tnok "teeth-fstat: ManifestError still raised with fstat check removed -- assertion has NO teeth" ;;
    *) _tnok "teeth-fstat: mutation target not found (SUT changed?)" ;;
  esac

  echo "-- ${_tp} teeth-passed · ${_tf} teeth-failed --"
  [ "${_tf}" -eq 0 ] || _main_exit=1
fi

exit $_main_exit
