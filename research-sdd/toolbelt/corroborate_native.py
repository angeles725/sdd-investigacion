#!/usr/bin/env python3
"""Produce bounded, non-executing radare2 evidence for one native binary."""
from __future__ import annotations

import argparse, ctypes, hashlib, json, os, platform, shutil, signal, stat, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from lib.isolation_profile import PROFILE_BWRAP_STATIC_NETWORK_DENIED

SCHEMA = "native-static.v1"
SAFE_R2 = ["-NN", "-S", "-x", "-q", "-e", "scr.color=0", "-e", "scr.utf8=false",
           "-e", "scr.interactive=false", "-c", "aaa;aflj", "input/target.bin"]


class NativeError(ValueError): pass


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def identity(path: Path) -> tuple[Path, int, str]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: fd = os.open(path, flags)
    except OSError as exc: raise NativeError(f"cannot open regular non-symlink file: {path}") from exc
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode): raise NativeError(f"not a regular file: {path}")
        resolved = Path(f"/proc/self/fd/{fd}").resolve(); digest = hashlib.sha256(); total = 0
        while chunk := os.read(fd, 1024 * 1024): digest.update(chunk); total += len(chunk)
        after = os.fstat(fd); fields = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size: raise NativeError(f"file changed while hashing: {path}")
        return resolved, total, "sha256:" + digest.hexdigest()
    finally: os.close(fd)


def stage_file(source: Path, staged: Path, logical: str, mode: int) -> tuple[dict[str, Any], dict[str, Any]]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: src = os.open(source, flags)
    except OSError as exc: raise NativeError("source cannot be opened safely") from exc
    digest = hashlib.sha256(); total = 0
    try:
        before = os.fstat(src)
        if not stat.S_ISREG(before.st_mode): raise NativeError("source is not a regular file")
        resolved = Path(f"/proc/self/fd/{src}").resolve()
        out = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0), 0o600)
        try:
            while chunk := os.read(src, 1024 * 1024):
                digest.update(chunk); total += len(chunk); view = memoryview(chunk)
                while view: view = view[os.write(out, view):]
            os.fsync(out)
        finally: os.close(out)
        after = os.fstat(src); fields = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size: raise NativeError("source changed while staging")
    finally: os.close(src)
    digest_text = "sha256:" + digest.hexdigest(); _, staged_size, staged_digest = identity(staged)
    if (staged_size, staged_digest) != (total, digest_text): raise NativeError("staged identity mismatch")
    staged.chmod(mode)
    return ({"path": str(resolved), "size": total, "sha256": digest_text},
            {"path": logical, "size": staged_size, "sha256": staged_digest})


def executable(name: str, configured: str | None, path: str) -> tuple[Path, dict[str, Any]]:
    selected = shutil.which(name, path=path)
    if selected is None: raise NativeError(f"PATH-selected {name} is missing")
    candidate = Path(configured or selected).resolve(strict=True); selected_path = Path(selected).resolve(strict=True)
    if not candidate.is_file() or not os.access(candidate, os.X_OK) or not os.path.samefile(candidate, selected_path):
        raise NativeError(f"configured {name} does not match PATH-selected executable")
    resolved, size, digest = identity(candidate)
    return resolved, {"path": str(resolved), "size": size, "sha256": digest}


def require_linux_private(path: Path) -> None:
    selected = (-1, "")
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        left, right = line.split(" - ", 1); encoded = left.split()[4]
        mount = Path(encoded.replace("\\040", " ").replace("\\011", "\t").replace("\\134", "\\"))
        try: path.relative_to(mount)
        except ValueError: continue
        if len(mount.parts) > selected[0]: selected = (len(mount.parts), right.split()[0])
    if selected[1] in {"9p", "drvfs", "cifs", "smb3", "nfs", "nfs4", "fuseblk", "fuse.sshfs"}:
        raise NativeError("output must reside on a Linux-private filesystem")


def isolation_prefix(bwrap: Path, environment: dict[str, str]) -> list[str]:
    root = Path("/tmp/rsdd"); root.mkdir(mode=0o700, exist_ok=True); meta = root.lstat()
    if stat.S_ISLNK(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o077: raise NativeError("unsafe Bubblewrap mountpoint")
    command = [str(bwrap), "--die-with-parent", "--new-session", "--unshare-net", "--ro-bind", "/", "/",
               "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/home",
               "--dir", "/tmp/rsdd/cache", "--dir", "/tmp/rsdd/config", "--dir", "/tmp/rsdd/data",
               "--dir", "/tmp/rsdd/work", "--ro-bind", ".", "/tmp/rsdd/work"]
    for key, value in environment.items(): command += ["--setenv", key, value]
    return command + ["--chdir", "/tmp/rsdd/work", "--"]


def run_bounded(command: list[str], cwd: Path, env: dict[str, str], timeout: int, max_bytes: int) -> tuple[dict[str, Any], list[str]]:
    out, err = cwd / "engine/stdout.txt", cwd / "engine/stderr.txt"; started_wall = datetime.now(timezone.utc); started = time.monotonic()
    with out.open("wb") as stdout, err.open("wb") as stderr:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
        reason = ""
        while process.poll() is None:
            if time.monotonic() - started >= timeout: reason = "timeout"
            elif sum(p.stat().st_size for p in (out, err)) > max_bytes: reason = "output-cap"
            if reason:
                try: os.killpg(process.pid, signal.SIGTERM); process.wait(timeout=1)
                except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait()
                break
            time.sleep(0.02)
        returncode = process.wait()
    if not reason and sum(path.stat().st_size for path in (out, err)) > max_bytes: reason = "output-cap"
    if reason:
        budget = max_bytes
        for path in (out, err):
            with path.open("r+b") as stream:
                data = stream.read(budget); stream.seek(0); stream.write(data); stream.truncate()
            budget -= len(data)
    ended = datetime.now(timezone.utc); duration = int((time.monotonic() - started) * 1000)
    run = {"started_at": started_wall.isoformat().replace("+00:00", "Z"), "ended_at": ended.isoformat().replace("+00:00", "Z"),
           "duration_ms": duration, "exit_code": returncode if returncode >= 0 else None, "signal": -returncode if returncode < 0 else None}
    errors = ([reason] if reason else []) + ([f"analyzer-exit:{returncode}"] if returncode and not reason else [])
    return run, errors


def write(path: Path, value: Any) -> None:
    temporary = path.with_name("." + path.name + ".tmp"); temporary.write_bytes(canonical_bytes(value))
    with temporary.open("rb") as stream: os.fsync(stream.fileno())
    os.replace(temporary, path)


def publish(stage: Path, destination: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if not hasattr(libc, "renameat2"): raise NativeError("atomic no-replace publication is unavailable")
    result = libc.renameat2(-100, os.fsencode(stage), -100, os.fsencode(destination), 1)
    if result: raise OSError(ctypes.get_errno(), "atomic publication failed", destination)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--input", type=Path, required=True); parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=30); parser.add_argument("--max-bytes", type=int, default=2_000_000)
    parser.add_argument("--max-functions", type=int, default=10_000); parser.add_argument("--max-files", type=int, default=8)
    parser.add_argument("--manifest-cli", type=Path, required=True, help=argparse.SUPPRESS); args = parser.parse_args(argv)
    stage: Path | None = None
    try:
        if min(args.timeout_seconds, args.max_bytes, args.max_functions) < 1 or args.max_files < 6: raise NativeError("caps must be positive and max-files at least 6")
        source, _, _ = identity(args.input); parent = args.output.parent.resolve(strict=True); require_linux_private(parent)
        destination = parent / args.output.name
        if destination.exists() or destination.is_symlink() or source == destination: raise NativeError("output must be a new non-colliding path")
        candidate = parent / f".{destination.name}.stage"; candidate.mkdir(mode=0o700); stage = candidate
        (stage / "input").mkdir(); (stage / "engine").mkdir()
        source_record, staged_record = stage_file(args.input, stage / "input/target.bin", "input/target.bin", 0o400)
        r2, r2_record = executable("r2", os.environ.get("RSDD_R2"), os.environ.get("PATH", ""))
        copied_r2, staged_r2 = stage_file(r2, stage / "engine/r2", "engine/r2", 0o500)
        if copied_r2 != r2_record: raise NativeError("analyzer changed before trusted staging")
        safe_path = f"{r2.parent}:/usr/bin:/bin"; bwrap, bwrap_record = executable("bwrap", os.environ.get("RSDD_BWRAP"), safe_path)
        bmeta = bwrap.stat()
        if bmeta.st_uid != 0 or bmeta.st_mode & 0o022: raise NativeError("Bubblewrap must be root-owned and non-writable")
        environment = {"HOME": "/tmp/rsdd/home", "XDG_CACHE_HOME": "/tmp/rsdd/cache", "XDG_CONFIG_HOME": "/tmp/rsdd/config",
                       "XDG_DATA_HOME": "/tmp/rsdd/data", "TMPDIR": "/tmp/rsdd", "PATH": safe_path, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC"}
        prefix = isolation_prefix(bwrap, environment)
        probe = subprocess.run(prefix + ["/bin/true"], cwd=stage, env=environment, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if probe.returncode: raise NativeError("network-denied isolation probe failed")
        version = subprocess.run(prefix + ["engine/r2", "-v"], cwd=stage, env=environment, capture_output=True,
                                 text=True, timeout=5, check=True).stdout.splitlines()[0]
        inner = ["engine/r2", *SAFE_R2]; command = prefix + inner
        run, errors = run_bounded(command, stage, environment, args.timeout_seconds, args.max_bytes)
        stdout = stage / "engine/stdout.txt"; stderr = stage / "engine/stderr.txt"
        for path in (stdout, stderr): path.write_bytes(path.read_bytes().replace(os.fsencode(str(stage)), b"<STAGING_ROOT>"))
        functions: list[dict[str, Any]] = []
        if not errors:
            try:
                raw = json.loads(stdout.read_text()); assert isinstance(raw, list)
                functions = sorted(({key: item[key] for key in ("name", "offset", "size", "nargs", "nbbs", "type") if key in item}
                                    for item in raw if isinstance(item, dict)), key=lambda item: (item.get("offset", 0), item.get("name", "")))
            except (ValueError, AssertionError): errors.append("invalid-functions-json")
        total = len(functions); emitted = functions[:args.max_functions]; write(stage / "engine/functions.json", emitted)
        truncated = total > len(emitted)
        limitations = ["radare2 aaa is heuristic and can miss or over-identify functions.",
                       "The trusted analyzer can read the host filesystem through Bubblewrap's read-only root bind.",
                       "Bubblewrap on WSL2 reduces filesystem and network exposure but is not a hostile-sample security boundary; use a disposable VM."]
        spec = {"schema_version": "analysis-manifest.v1", "input": {"path": "input/target.bin", "detected_type": None},
                "tool": {"name": "radare2", "version": version, "executable": str(bwrap), "artifacts": [{"path": "engine/r2", "argv_index": command.index("engine/r2")}]},
                "argv": command, "environment": environment, "run": run, "stdout_path": "engine/stdout.txt", "stderr_path": "engine/stderr.txt",
                "outputs": ["engine/functions.json"], "findings": [], "limitations": limitations, "errors": errors,
                "completeness": "failed" if errors else "partial" if truncated else "complete", "isolation_profile": PROFILE_BWRAP_STATIC_NETWORK_DENIED}
        write(stage / "engine/manifest-spec.json", spec)
        manifest = stage / "engine/analysis-manifest.v1.json"
        subprocess.run([sys.executable, str(args.manifest_cli), "create", "--root", str(stage), "--spec", str(stage / "engine/manifest-spec.json"), "--output", str(manifest)], check=True)
        (stage / "engine/manifest-spec.json").unlink(); subprocess.run([sys.executable, str(args.manifest_cli), "validate", str(manifest)], check=True)
        manifest_identity = json.loads(manifest.read_text())["identity"]
        report = {"schema": SCHEMA, "status": "failed" if errors else "partial" if truncated else "complete", "input": {"source": source_record, "staged": staged_record},
                  "runtime": {"python": platform.python_version(), "kernel": platform.release()},
                  "isolation": {"launcher": bwrap_record, "profile": spec["isolation_profile"]},
                  "engine": {"name": "radare2", "version": version, "launcher": {"source": r2_record, "staged": staged_r2}, "argv": inner,
                             "run": {key: run[key] for key in ("exit_code", "signal")},
                             "manifest": "engine/analysis-manifest.v1.json", "manifest_identity": manifest_identity},
                  "functions": emitted, "counts": {"functions_total": total, "functions_emitted": len(emitted)},
                  "caps": {"timeout_seconds": args.timeout_seconds, "max_bytes": args.max_bytes, "max_files": args.max_files, "max_functions": args.max_functions},
                   "truncated": {"functions": truncated}, "limitations": limitations, "errors": errors}
        write(stage / f"{SCHEMA}.json", report)
        if sum(1 for path in stage.rglob("*") if path.is_file() and path != stage / "input/target.bin") > args.max_files: raise NativeError("evidence file cap exceeded")
        publish(stage, destination); stage = None
        return 1 if errors or truncated else 0
    except (NativeError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"corroborate-native: {exc}", file=sys.stderr); return 2
    finally:
        if stage is not None and stage.exists(): shutil.rmtree(stage)


if __name__ == "__main__": sys.exit(main())
