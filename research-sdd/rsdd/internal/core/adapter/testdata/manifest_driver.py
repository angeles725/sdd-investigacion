"""Parity driver for the manifest half of internal/adapter: runs the REAL
analysis_manifest.py and isolation_profile.py and prints one JSON list.

usage: python3 -I manifest_driver.py <toolbelt-dir> <op>   (JSON list of cases on stdin)

Ops: loads, iso, nfkc, unquote, relative, artifact_path, safe_argv, sanitize_env,
evidence_location, profile, profile_consts, main.
Each case yields {"ok", "class", "msg", "value"}; `main` yields {"rc", "out", "err"}.
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import traceback
import unicodedata
from datetime import datetime, timedelta
from urllib.parse import unquote

toolbelt = sys.argv[1]
sys.path.insert(0, os.path.join(toolbelt, "lib"))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


am = load(os.path.join(toolbelt, "analysis_manifest.py"), "analysis_manifest")
ip = load(os.path.join(toolbelt, "lib", "isolation_profile.py"), "isolation_profile")
op = sys.argv[2]


def result(fn):
    try:
        return {"ok": True, "value": fn()}
    except Exception as exc:  # noqa: BLE001 - the class name is the contract
        return {"ok": False, "class": type(exc).__name__, "msg": str(exc)}


def iso(c):
    d = datetime.fromisoformat(c.replace("Z", "+00:00"))
    off = d.utcoffset()
    naive = d.replace(tzinfo=None) - datetime(1, 1, 1)
    us = (naive.days * 86400 + naive.seconds) * 1000000 + naive.microseconds
    if off is not None:
        us -= (off.days * 86400 + off.seconds) * 1000000 + off.microseconds
    return {"aware": off is not None, "us": us}


def run_main(c):
    os.chdir(c["cwd"])
    os.environ.pop("COLUMNS", None)
    for k, v in (c.get("env") or {}).items():
        os.environ[k] = v
    sys.argv[0] = "analysis_manifest.py"
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    last = ""
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = am.main(c["argv"])
        except SystemExit as exc:
            rc = exc.code if isinstance(exc.code, int) else 1
        except BaseException:  # noqa: BLE001 - an uncaught exception is exit 1 with a traceback
            rc = 1
            last = traceback.format_exc().strip().splitlines()[-1]
            print("Traceback (most recent call last):", file=sys.stderr)
    return {"rc": rc, "out": out.getvalue(), "err": err.getvalue(), "crash": last}


def sub(text, root):
    return text.replace("{root}", root)


def run_script(c):
    """Replay a recorded world: filesystem steps and CLI runs, in order, under one root."""
    root = c["root"]
    os.makedirs(root, exist_ok=True)
    runs = []
    for st in c["steps"]:
        kind = st["kind"]
        if kind == "run":
            runs.append(run_main({"cwd": sub(st.get("cwd") or "{root}", root), "argv": [sub(a, root) for a in st.get("argv", [])], "env": st.get("env") or {}}))
            continue
        path = sub(st["path"], root)
        if kind == "write":
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(bytes.fromhex(st["hex"]) if "hex" in st else sub(st.get("text", ""), root).encode())
            os.chmod(path, st.get("mode", 0))
        elif kind == "mkdir":
            os.makedirs(path, exist_ok=True)
        elif kind == "symlink":
            os.makedirs(os.path.dirname(path), exist_ok=True)
            os.symlink(sub(st["target"], root), path)
        elif kind == "chmod":
            os.chmod(path, st.get("mode", 0))
        elif kind == "remove":
            os.remove(path)
        elif kind == "replace":
            os.replace(path, sub(st["target"], root))
        else:
            raise SystemExit("unknown step " + kind)
    return runs


def profile(c):
    return ip.make_profile(c["name"], static_only=c["static_only"], network_access=c["network_access"], target_execution=c["target_execution"])


if op == "profile_consts":
    print(json.dumps({k: v for k, v in vars(ip).items() if k.startswith("PROFILE_")}))
    sys.exit(0)

cases = json.load(sys.stdin)
out = []
for c in cases:
    if op == "loads":
        out.append(result(lambda: repr(json.loads(c))))
    elif op == "iso":
        out.append(result(lambda: iso(c)))
    elif op == "unassigned":
        out.append(any(unicodedata.category(ch) == "Cn" for ch in c))
    elif op == "nfkc":
        out.append(unicodedata.normalize("NFKC", c))
    elif op == "unquote":
        out.append(unquote(c))
    elif op == "relative":
        out.append(result(lambda: am._relative(c["v"], "ctx")))
    elif op == "artifact_path":
        out.append(result(lambda: am._analysis_artifact_path(c["v"], "ctx")))
    elif op == "safe_argv":
        out.append(result(lambda: am._safe_argv(c["v"])))
    elif op == "sanitize_env":
        out.append(result(lambda: am.sanitize_environment(c["v"])))
    elif op == "evidence_location":
        out.append(result(lambda: [str(x) for x in am._evidence_location(c["v"])]))
    elif op == "profile":
        out.append(result(lambda: profile(c)))
    elif op == "main":
        out.append(run_main(c))
    elif op == "script":
        out.append(run_script(c))
    else:
        raise SystemExit("unknown op " + op)
print(json.dumps(out))
