#!/usr/bin/env python3
"""Produce bounded, reproducible evidence from five non-executing JVM adapters."""
from __future__ import annotations

import argparse
import ctypes
import fcntl
import importlib.util
import json
import os
import re
import resource
import select
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from lib.isolation_profile import PROFILE_BWRAP_STATIC_NETWORK_DENIED

SCHEMA = "java-corroboration.v1"
DEFAULT_PINS = {
    "vineflower": "a615d07ddbbcd489369674f40e42df639c32be95410890b38f173d5c1e2ea39c",
    "cfr": "f686e8f3ded377d7bc87d216a90e9e9512df4156e75b06c655a16648ae8765b2",
    "procyon": "821da96012fc69244fa1ea298c90455ee4e021434bc796d3b9546ab24601b779",
}
SANDBOX_ROOT = "/tmp/rsdd/analysis"
STAGE_MARKER = b"research-sdd corroborate-java staging v1\n"


class CorroborationError(ValueError):
    pass


def positive(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def load_manifest_module(path: Path):
    spec = importlib.util.spec_from_file_location("rsdd_analysis_manifest", path)
    if spec is None or spec.loader is None:
        raise CorroborationError("analysis manifest module cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def canonical_destination(requested: Path) -> Path:
    lexical = requested.expanduser().absolute()
    if lexical.is_symlink():
        raise CorroborationError("output root must not be a symlink")
    if not lexical.name:
        raise CorroborationError("output root must name a new directory")
    parent = lexical.parent.resolve(strict=True)
    destination = parent / lexical.name
    if destination.is_symlink():
        raise CorroborationError("output root must not be a symlink")
    if destination.exists() and not destination.is_dir():
        raise CorroborationError("output root must be a directory")
    return destination.resolve() if destination.exists() else destination


def protect_destination(destination: Path, protected: list[Path]) -> None:
    for artifact in protected:
        if artifact == destination or destination in artifact.parents:
            raise CorroborationError(f"output root collides with protected artifact: {artifact}")


def jar_inventory(path: Path, max_files: int, max_bytes: int, max_classes: int) -> dict[str, Any]:
    if path.stat().st_size > max_bytes:
        raise CorroborationError("input exceeds --max-bytes")
    if not zipfile.is_zipfile(path):
        raise CorroborationError("input is not a valid JAR/ZIP")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > max_files:
            raise CorroborationError("JAR entry count exceeds --max-files")
        if sum(item.file_size for item in entries) > max_bytes:
            raise CorroborationError("JAR expanded bytes exceed --max-bytes")
        names: set[str] = set()
        for item in entries:
            name = item.filename[:-1] if item.is_dir() else item.filename
            entry = PurePosixPath(name)
            mode = (item.external_attr >> 16) & 0xFFFF
            if (not name or "\\" in name or "\0" in name or entry.is_absolute()
                    or any(part in ("", ".", "..") for part in entry.parts)
                    or entry.as_posix() != name or stat.S_ISLNK(mode) or item.filename in names):
                raise CorroborationError(f"unsafe or duplicate JAR entry: {item.filename}")
            names.add(item.filename)
        corrupt = archive.testzip()
        if corrupt is not None:
            raise CorroborationError(f"corrupt JAR entry: {corrupt}")
    class_entries = sorted(item.filename for item in entries if not item.is_dir() and item.filename.endswith(".class"))
    base = sorted({item[:-6].replace("/", ".") for item in class_entries
                   if not item.startswith("META-INF/versions/") and not item.endswith(("module-info.class", "package-info.class"))})
    return {
        "entry_count": len(entries), "expanded_bytes": sum(item.file_size for item in entries),
        "class_entries": class_entries, "expected_total": len(base),
        "expected_classes": base[:max_classes], "classes_truncated": len(base) > max_classes,
        "multi_release": any(item.startswith("META-INF/versions/") for item in class_entries),
    }


def scan_files(root: Path, max_files: int, max_bytes: int) -> tuple[int, int]:
    files, total = 0, 0
    if not root.exists():
        return files, total
    for path in root.rglob("*"):
        if path.is_symlink():
            raise CorroborationError(f"adapter emitted a symlink: {path}")
        if path.is_file():
            files += 1
            total += path.stat().st_size
            if files > max_files or total > max_bytes:
                return files, total
    return files, total


def stop_group(process: subprocess.Popen[Any], deadline: float) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    try: os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    if process.poll() is None:
        try: process.wait(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired: process.kill()


def drain_diagnostic(source: Any, target: Path, budget: dict[str, int],
                     lock: threading.Lock, exceeded: threading.Event,
                     stop: threading.Event, deadline: float) -> None:
    with target.open("wb") as output:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([source], [], [], min(0.05, max(0.0, deadline - time.monotonic())))
            if not ready:
                if stop.is_set(): break
                continue
            chunk = os.read(source.fileno(), 64 * 1024)
            if not chunk: break
            with lock:
                retained = chunk[:budget["remaining"]]
                budget["remaining"] -= len(retained)
            output.write(retained)
            if len(retained) != len(chunk):
                exceeded.set()


def limit_generated_file_size(max_bytes: int) -> None:
    resource.setrlimit(resource.RLIMIT_FSIZE, (max_bytes, max_bytes))


def canonical_launcher(path: Path) -> Path:
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise CorroborationError(f"launcher cannot be resolved: {path}") from exc
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise CorroborationError(f"launcher is not an executable file: {resolved}")
    return resolved


def stage_trusted_artifact(module: Any, name: str, value: str, stage: Path) -> dict[str, Any] | None:
    if not value:
        return None
    key = f"{name.upper()}_SHA256"
    pin = os.environ[key] if key in os.environ else DEFAULT_PINS[name]
    pin = pin.removeprefix("sha256:")
    if not re.fullmatch(r"[0-9a-f]{64}", pin):
        raise CorroborationError(f"{name} trusted SHA-256 pin is absent or invalid")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: source_fd = os.open(Path(value), flags)
    except OSError as exc: raise CorroborationError(f"{name} source cannot be opened safely") from exc
    staged_relative = Path("trusted-tools") / f"{name}.jar"
    staged = stage / staged_relative
    digest = __import__("hashlib").sha256(); total = 0
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode): raise CorroborationError(f"{name} source is not regular")
        resolved = Path(f"/proc/self/fd/{source_fd}").resolve()
        output_fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0), 0o600)
        try:
            while chunk := os.read(source_fd, 1024 * 1024):
                digest.update(chunk); total += len(chunk)
                view = memoryview(chunk)
                while view: view = view[os.write(output_fd, view):]
            os.fsync(output_fd)
        finally: os.close(output_fd)
        after = os.fstat(source_fd)
        fields = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size:
            raise CorroborationError(f"{name} source changed while copying")
    finally: os.close(source_fd)
    source_digest = "sha256:" + digest.hexdigest()
    if source_digest != f"sha256:{pin}":
        raise CorroborationError(f"{name} SHA-256 does not match trusted pin")
    staged.chmod(0o400)
    _, staged_size, staged_digest, _ = module._file_identity(staged, stage)
    if staged_size != total or staged_digest != source_digest:
        raise CorroborationError(f"{name} private copy verification failed")
    return {"schema": "trusted-tool-copy.v1",
            "source": {"path": str(resolved), "size": total, "sha256": source_digest},
            "staged": {"path": staged_relative.as_posix(), "size": staged_size, "sha256": staged_digest}}


def isolation_prefix(bwrap: Path, writable: str | None = None,
                     trusted_tool: tuple[str, str] | None = None) -> list[str]:
    command = [str(bwrap), "--die-with-parent", "--new-session", "--unshare-net",
               "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp/rsdd",
               "--dir", "/tmp/rsdd/home", "--dir", "/tmp/rsdd/tmp", "--dir", "/tmp/rsdd/cache",
               "--dir", "/tmp/rsdd/config", "--dir", "/tmp/rsdd/data", "--dir", SANDBOX_ROOT,
               "--ro-bind", ".", SANDBOX_ROOT]
    if trusted_tool is not None:
        command += ["--dir", "/tmp/rsdd/tools", "--ro-bind", trusted_tool[0], trusted_tool[1]]
    if writable is not None:
        command += ["--bind", writable, f"{SANDBOX_ROOT}/{writable}"]
    command += ["--setenv", "HOME", "/tmp/rsdd/home", "--setenv", "XDG_CACHE_HOME", "/tmp/rsdd/cache",
                "--setenv", "XDG_CONFIG_HOME", "/tmp/rsdd/config", "--setenv", "XDG_DATA_HOME", "/tmp/rsdd/data",
                "--setenv", "TMPDIR", "/tmp/rsdd/tmp", "--chdir", SANDBOX_ROOT, "--"]
    return command


def require_isolation(bwrap: Path, stage: Path, environment: dict[str, str]) -> None:
    try:
        system_value = shutil.which("bwrap", path=environment.get("PATH"))
        if system_value is None or not os.path.samefile(bwrap, canonical_launcher(Path(system_value))):
            raise CorroborationError("configured isolation launcher does not match system Bubblewrap")
        mountpoint = Path("/tmp/rsdd")
        mountpoint.mkdir(mode=0o700, exist_ok=True)
        metadata = mountpoint.lstat()
        if stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
            raise CorroborationError("unsafe bubblewrap temporary mountpoint")
        result = subprocess.run(isolation_prefix(bwrap) + ["/bin/true"], cwd=stage, env=environment,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise CorroborationError("network-denied isolation cannot be established") from exc
    if result.returncode != 0:
        raise CorroborationError("network-denied isolation cannot be established")


def normalize_diagnostics(engine_root: Path, stage: Path, max_bytes: int) -> tuple[int, bool]:
    marker = b"<STAGING_ROOT>"
    variants = {os.fsencode(str(stage)), os.fsencode(stage.as_posix()), os.fsencode(SANDBOX_ROOT)}
    remaining = max_bytes
    truncated = False
    for stream in ("stdout", "stderr"):
        raw = engine_root / f"{stream}.raw.txt"
        with raw.open("rb") if raw.exists() else open(os.devnull, "rb") as source:
            payload = source.read(remaining + 1)
        consumed = min(len(payload), remaining)
        if len(payload) > remaining:
            payload = payload[:remaining]
            truncated = True
        for value in variants:
            if value:
                payload = payload.replace(value, marker)
        (engine_root / f"{stream}.txt").write_bytes(payload)
        remaining -= len(payload)
        if raw.exists():
            if raw.stat().st_size > consumed:
                truncated = True
            raw.unlink()
    return remaining, truncated


def run_adapter(command: list[str], cwd: Path, engine_root: Path, environment: dict[str, str],
                timeout_seconds: int, max_files: int, max_bytes: int) -> dict[str, Any]:
    stdout_path, stderr_path = engine_root / "stdout.raw.txt", engine_root / "stderr.raw.txt"
    started_wall = datetime.now(timezone.utc); started = time.monotonic(); deadline = started + timeout_seconds
    cleanup_at = deadline - min(0.25, timeout_seconds / 4)
    state = "running"
    process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True,
                               preexec_fn=lambda: limit_generated_file_size(max_bytes))
    assert process.stdout is not None and process.stderr is not None
    budget = {"remaining": max_bytes}; budget_lock = threading.Lock(); diagnostics_exceeded = threading.Event(); drain_stop = threading.Event()
    drainers = [threading.Thread(target=drain_diagnostic, args=(source, target, budget, budget_lock,
                                                                diagnostics_exceeded, drain_stop, deadline), daemon=True)
                for source, target in ((process.stdout, stdout_path), (process.stderr, stderr_path))]
    for drainer in drainers: drainer.start()
    try:
        while process.poll() is None:
            files, size = scan_files(engine_root, max_files, max_bytes)
            if diagnostics_exceeded.is_set() or files > max_files or size > max_bytes:
                state = "cap_exceeded"; stop_group(process, deadline); break
            if time.monotonic() >= cleanup_at:
                state = "timeout"; stop_group(process, deadline); break
            time.sleep(0.05)
    except Exception:
        stop_group(process, deadline); raise
    finally:
        stop_group(process, deadline)
        drain_stop.set()
        for drainer in drainers: drainer.join(max(0.0, deadline - time.monotonic()))
        for source, drainer in zip((process.stdout, process.stderr), drainers):
            if drainer.is_alive():
                raise CorroborationError("diagnostic drainer exceeded wall deadline")
            source.close()
    returncode = process.wait()
    files, size = scan_files(engine_root, max_files, max_bytes)
    if state == "running" and (diagnostics_exceeded.is_set() or files > max_files or size > max_bytes):
        state = "cap_exceeded"
    ended_wall = datetime.now(timezone.utc); duration = int((time.monotonic() - started) * 1000)
    if state == "running": state = "success" if returncode == 0 else "failed"
    return {
        "status": state, "returncode": returncode,
        "diagnostics_truncated": diagnostics_exceeded.is_set(),
        "started_at": started_wall.isoformat().replace("+00:00", "Z"),
        "ended_at": ended_wall.isoformat().replace("+00:00", "Z"), "duration_ms": duration,
    }


def output_inventory(module: Any, stage: Path, output: Path, max_files: int,
                     max_bytes: int) -> tuple[list[dict[str, Any]], bool]:
    files = []
    if output.exists():
        for path in sorted(output.rglob("*"), key=lambda item: item.as_posix()):
            if path.is_symlink(): raise CorroborationError("adapter output symlink is forbidden")
            if path.is_file():
                files.append(path)
    records = []
    remaining = max_bytes
    truncated = False
    for path in files:
        size = path.stat().st_size
        if len(records) >= max_files or remaining == 0:
            path.unlink()
            truncated = True
            continue
        if size > remaining:
            flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(path, flags)
            try:
                if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                    raise CorroborationError("adapter output is not a regular file")
                os.ftruncate(descriptor, remaining)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            truncated = True
        _, size, digest, _ = module._file_identity(path, stage)
        records.append({"path": path.relative_to(output).as_posix(), "size": size, "sha256": digest})
        remaining -= size
    for path in sorted(output.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if path.is_dir():
            try: path.rmdir()
            except OSError: pass
    return records, truncated


def output_contains_bytes(output: Path) -> bool:
    if not output.exists():
        return False
    for path in output.rglob("*"):
        if path.is_symlink():
            raise CorroborationError("adapter output symlink is forbidden")
        if path.is_file() and path.stat().st_size:
            return True
    return False


def run_record(returncode: int, started_at: str, ended_at: str, duration_ms: int) -> dict[str, Any]:
    return {"started_at": started_at, "ended_at": ended_at, "duration_ms": duration_ms,
            "exit_code": returncode if returncode >= 0 else None,
            "signal": -returncode if returncode < 0 else None}


def make_manifest(module: Any, stage: Path, name: str, command: list[str], environment: dict[str, str],
                  artifacts: list[tuple[Path, int]], evidence: list[str], outcome: dict[str, Any],
                  outputs: list[dict[str, Any]]) -> tuple[str, str]:
    engine_root = Path("engines") / name
    limitations = ["This adapter provides corroborating static evidence, not source or runtime equivalence.",
                   "WSL2 is not a security boundary; use a disposable VM for hostile artifacts."]
    errors = [] if outcome["status"] == "success" else [f"adapter status: {outcome['status']}"]
    bound_artifacts = [{"path": str(path), "argv_index": index} for path, index in artifacts]
    spec = {
        "schema_version": "analysis-manifest.v1",
        "input": {"path": "input/target.jar", "detected_type": "Java archive"},
        "tool": {"name": name, "version": "artifact-bound", "executable": command[0],
                 "artifacts": bound_artifacts},
        "argv": command, "environment": environment,
        "run": run_record(outcome["returncode"], outcome["started_at"], outcome["ended_at"], outcome["duration_ms"]),
        "stdout_path": (engine_root / "stdout.txt").as_posix(),
        "stderr_path": (engine_root / "stderr.txt").as_posix(),
        "outputs": [(engine_root / "output" / item["path"]).as_posix() for item in outputs] + evidence,
        "findings": [], "limitations": limitations, "errors": errors,
        "completeness": "partial" if errors else "complete",
        "isolation_profile": PROFILE_BWRAP_STATIC_NETWORK_DENIED,
    }
    manifest = module.build_manifest(spec, stage)
    relative = (engine_root / "analysis-manifest.v1.json").as_posix()
    module._atomic_write(stage / relative, module.canonical_bytes(manifest), False)
    module.verify_artifacts(manifest, stage)
    return relative, manifest["identity"]


def signatures(path: Path) -> list[str]:
    return sorted({line.strip() for line in path.read_text(errors="replace").splitlines()
                   if line.strip().endswith(";") or line.strip().startswith("descriptor:")})


def dependency_lines(path: Path) -> list[str]:
    return sorted({line.strip() for line in path.read_text(errors="replace").splitlines() if line.strip()})


def coverage(expected: list[str], inventory: list[dict[str, Any]]) -> dict[str, Any]:
    source_paths = {item["path"][:-5].replace("/", ".") for item in inventory if item["path"].endswith(".java")}
    covered = sorted(item for item in expected if item in source_paths or item.split("$")[0] in source_paths)
    missing = sorted(set(expected) - set(covered))
    return {"covered": covered, "missing": missing, "covered_count": len(covered), "expected_count": len(expected)}


def comparisons(engine_records: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    names = [name for name in ("vineflower", "cfr", "procyon") if name in engine_records]
    results = []
    for index, left in enumerate(names):
        for right in names[index + 1:]:
            a = {item["path"]: item["sha256"] for item in engine_records[left]["output_inventory"]}
            b = {item["path"]: item["sha256"] for item in engine_records[right]["output_inventory"]}
            common = sorted(set(a) & set(b))
            results.append({"engines": [left, right], "common_paths": common,
                            "same_hash_paths": [path for path in common if a[path] == b[path]],
                            "different_hash_paths": [path for path in common if a[path] != b[path]],
                            "only_left": sorted(set(a) - set(b)), "only_right": sorted(set(b) - set(a))})
    return results


def remove_private_tree(path: Path) -> None:
    trusted = path / "trusted-tools"
    if trusted.is_dir() and not trusted.is_symlink(): trusted.chmod(0o700)
    shutil.rmtree(path)


def lock_publication_parent(destination: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(destination.parent, flags)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(descriptor)
        raise CorroborationError("another publication is active in the output parent") from exc
    return descriptor


def prepare_stage(destination: Path) -> Path:
    stage = destination.parent / f".{destination.name}.stage"
    if stage.exists() or stage.is_symlink():
        marker = stage / ".corroborate-java-stage"
        if (stage.is_symlink() or not stage.is_dir() or marker.is_symlink()
                or not marker.is_file() or marker.read_bytes() != STAGE_MARKER):
            raise CorroborationError("staging path exists and is not managed by corroborate-java")
        remove_private_tree(stage)
    stage.mkdir(mode=0o700)
    (stage / ".corroborate-java-stage").write_bytes(STAGE_MARKER)
    return stage


def renameat2(source: Path, destination: Path, flags: int) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    function = getattr(libc, "renameat2", None)
    if function is None:
        raise CorroborationError("atomic publication is unavailable on this platform")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(-100, os.fsencode(source), -100, os.fsencode(destination), flags):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try: os.fsync(descriptor)
    finally: os.close(descriptor)


def publish(stage: Path, destination: Path, overwrite: bool) -> None:
    if destination.is_symlink():
        raise CorroborationError("output root must not be a symlink")
    if destination.exists() and not overwrite:
        raise CorroborationError("output root exists; pass --overwrite")
    if destination.exists():
        if not destination.is_dir():
            raise CorroborationError("output root must be a directory")
        renameat2(stage, destination, 2)  # RENAME_EXCHANGE keeps destination continuously visible.
        fsync_directory(destination.parent)
        remove_private_tree(stage)
        fsync_directory(destination.parent)
    else:
        renameat2(stage, destination, 1)  # RENAME_NOREPLACE preserves no-overwrite publication.
        fsync_directory(destination.parent)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--decompile-wrapper", type=Path, required=True, help=argparse.SUPPRESS)
    parser.add_argument("--manifest-module", type=Path, required=True, help=argparse.SUPPRESS)
    parser.add_argument("--input", type=Path, required=True); parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--timeout-seconds", type=positive, default=120)
    parser.add_argument("--max-heap", default="1024m")
    parser.add_argument("--max-files", type=positive, default=20_000)
    parser.add_argument("--max-bytes", type=positive, default=1_073_741_824)
    parser.add_argument("--max-classes", type=positive, default=10_000)
    args = parser.parse_args(argv)
    if not __import__("re").fullmatch(r"[1-9][0-9]{0,5}[mMgG]", args.max_heap):
        parser.error("--max-heap must look like 1024m or 2g")

    module = load_manifest_module(args.manifest_module)
    stage: Path | None = None
    publication_lock: int | None = None
    try:
        resolved, size, digest, _ = module._file_identity(args.input)
        input_path = Path(resolved)
        destination = canonical_destination(args.output)
        java_home = Path(os.environ["JAVA_HOME"]).resolve()
        wrapper = args.decompile_wrapper.resolve(strict=True)
        java = canonical_launcher(java_home / "bin/java")
        javap = canonical_launcher(java_home / "bin/javap")
        jdeps = canonical_launcher(java_home / "bin/jdeps")
        bwrap_value = os.environ.get("RSDD_BWRAP", "/usr/bin/bwrap")
        if not bwrap_value:
            raise CorroborationError("bubblewrap is required for analyzer isolation")
        bwrap = canonical_launcher(Path(bwrap_value))
        bwrap_metadata = bwrap.stat()
        if bwrap_metadata.st_uid != 0 or bwrap_metadata.st_mode & 0o022:
            raise CorroborationError("bubblewrap launcher must be root-owned and non-writable")
        tool_sources = {
            "vineflower": os.environ.get("RSDD_CORROBORATE_VINEFLOWER", ""),
            "cfr": os.environ.get("RSDD_CORROBORATE_CFR", ""),
            "procyon": os.environ.get("RSDD_CORROBORATE_PROCYON", "")}
        protected = [input_path, wrapper, args.manifest_module.resolve(), bwrap, java, javap, jdeps]
        protect_destination(destination, protected)
        publication_lock = lock_publication_parent(destination)
        stage = prepare_stage(destination)
        if destination.exists() and not args.overwrite:
            raise CorroborationError("output root exists; pass --overwrite")

        (stage / "input").mkdir(); shutil.copyfile(input_path, stage / "input/target.jar")
        copied = module._file_identity(stage / "input/target.jar", stage)
        if copied[1] != size or copied[2] != digest: raise CorroborationError("input changed while staging")
        jar = jar_inventory(stage / "input/target.jar", args.max_files, args.max_bytes, args.max_classes)
        trusted_dir = stage / "trusted-tools"; trusted_dir.mkdir(mode=0o700)
        tool_jars = {name: stage_trusted_artifact(module, name, value, stage)
                     for name, value in tool_sources.items()}
        trusted_dir.chmod(0o500)
        protect_destination(destination, protected + [Path(item["source"]["path"])
                                                      for item in tool_jars.values() if item is not None])

        path_value = f"{java_home / 'bin'}:/usr/bin:/bin"
        environment = {"HOME": "/tmp/rsdd/home", "XDG_CACHE_HOME": "/tmp/rsdd/cache",
                       "XDG_CONFIG_HOME": "/tmp/rsdd/config", "XDG_DATA_HOME": "/tmp/rsdd/data",
                       "TMPDIR": "/tmp/rsdd/tmp", "JAVA_HOME": str(java_home), "LANG": "C.UTF-8",
                       "LC_ALL": "C.UTF-8", "PATH": path_value, "TZ": "UTC",
                       "RSDD_DECOMPILE_MAX_HEAP": args.max_heap}
        require_isolation(bwrap, stage, environment)
        engines: dict[str, dict[str, Any]] = {}
        for name in ("vineflower", "cfr", "procyon", "javap", "jdeps"):
            root = stage / "engines" / name; output = root / "output"; output.mkdir(parents=True)
            artifact = None; trusted_source = None; trusted_bind = None; evidence: list[str] = []
            if name in tool_jars:
                trusted_source = tool_jars[name]
                if trusted_source is not None:
                    artifact = Path(trusted_source["staged"]["path"])
                    sandbox_jar = f"/tmp/rsdd/tools/{name}.jar"
                    trusted_bind = (artifact.as_posix(), sandbox_jar)
                    inner = [str(java), f"-Xmx{args.max_heap}", "-jar", sandbox_jar]
                    if name == "vineflower":
                        inner += ["--thread-count=1", "input/target.jar", f"engines/{name}/output"]
                    elif name == "cfr":
                        inner += ["input/target.jar", "--outputdir", f"engines/{name}/output"]
                    else:
                        inner += ["-jar", "input/target.jar", "-o", f"engines/{name}/output"]
            elif name == "javap":
                inner = [str(javap), f"-J-Xmx{args.max_heap}", "-p", "-s", "-classpath", "input/target.jar", *jar["expected_classes"]]
            else:
                inner = [str(jdeps), f"-J-Xmx{args.max_heap}", "--multi-release", "base", "-verbose:class", "input/target.jar"]
            if artifact is None and name in tool_jars:
                now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
                (root / "stdout.raw.txt").write_bytes(b"")
                (root / "stderr.raw.txt").write_text("analyzer JAR unavailable\n")
                outcome = {"status": "unavailable", "returncode": 127, "diagnostics_truncated": False,
                           "started_at": now, "ended_at": now, "duration_ms": 0}
                manifest_path, identity = None, None
            else:
                writable = f"engines/{name}/output"
                command = isolation_prefix(bwrap, writable, trusted_bind) + inner
                outcome = run_adapter(command, stage, root, environment, args.timeout_seconds, args.max_files, args.max_bytes)
            diagnostic_limit = args.max_bytes - int(output_contains_bytes(output))
            diagnostic_remaining, finalization_truncated = normalize_diagnostics(root, stage, diagnostic_limit)
            remaining = args.max_bytes - (diagnostic_limit - diagnostic_remaining)
            diagnostics_truncated = outcome["diagnostics_truncated"] or finalization_truncated
            inventory, outputs_truncated = output_inventory(module, stage, output, args.max_files, remaining)
            caps_truncated = diagnostics_truncated or outputs_truncated
            if caps_truncated and outcome["status"] in ("success", "failed"):
                outcome["status"] = "cap_exceeded"
            if not (artifact is None and name in tool_jars):
                inner_artifacts = [(Path(inner[0]), command.index(inner[0]))]
                if artifact is not None:
                    evidence_path = (Path("engines") / name / "trusted-source.json").as_posix()
                    module._atomic_write(stage / evidence_path, module.canonical_bytes(trusted_source), False)
                    evidence.append(evidence_path)
                    inner_artifacts.append((artifact, command.index(artifact.as_posix())))
                manifest_path, identity = make_manifest(module, stage, name, command, environment,
                                                        inner_artifacts, evidence, outcome, inventory)
            engines[name] = {"status": outcome["status"], "exit_code": outcome["returncode"] if outcome["returncode"] >= 0 else None,
                             "signal": -outcome["returncode"] if outcome["returncode"] < 0 else None,
                             "manifest": manifest_path, "manifest_identity": identity, "output_inventory": inventory,
                             "trusted_source": trusted_source,
                             "diagnostics": {"stdout": f"engines/{name}/stdout.txt",
                                             "stderr": f"engines/{name}/stderr.txt"},
                             "truncated": {"diagnostics": diagnostics_truncated, "outputs": outputs_truncated}}

        expected = jar["expected_classes"]
        coverage_map = {name: coverage(expected, engines[name]["output_inventory"])
                        for name in ("vineflower", "cfr", "procyon")}
        failures = [name for name, record in engines.items() if record["status"] != "success"]
        report = {
            "schema": SCHEMA, "status": "partial" if failures else "complete",
            "input": {"path": str(input_path), "size": size, "sha256": digest,
                      "entry_count": jar["entry_count"], "expanded_bytes": jar["expanded_bytes"]},
            "class_entries": jar["class_entries"], "expected_classes": expected,
            "expected_class_count": jar["expected_total"], "multi_release": jar["multi_release"],
            "engines": engines, "javap_signatures": signatures(stage / "engines/javap/stdout.txt"),
            "jdeps": dependency_lines(stage / "engines/jdeps/stdout.txt"), "class_coverage": coverage_map,
            "agreements": comparisons(engines),
            "disagreements": [item for item in comparisons(engines) if item["different_hash_paths"] or item["only_left"] or item["only_right"]],
            "truncated": {"classes": jar["classes_truncated"],
                          "adapter_caps": any(any(item["truncated"].values()) for item in engines.values())},
            "errors": [f"{name}: {engines[name]['status']}" for name in failures],
            "limitations": ["Decompiler outputs are compared only by observable path and byte-hash inventories; source equivalence is not claimed.",
                            "Multi-release class entries are inventoried, but javap coverage uses base classes only.",
                            "JDK runtime behavior and target class initialization are not executed.",
                            "WSL2 is not a security boundary; use a disposable VM for hostile artifacts."],
        }
        module._atomic_write(stage / f"{SCHEMA}.json", module.canonical_bytes(report), False)
        publish(stage, destination, args.overwrite); stage = None
        return 1 if failures else 0
    except (CorroborationError, module.ManifestError, OSError, zipfile.BadZipFile, subprocess.SubprocessError) as exc:
        print(f"corroborate-java: {exc}", file=sys.stderr); return 2
    finally:
        if stage is not None and stage.exists(): remove_private_tree(stage)
        if publication_lock is not None: os.close(publication_lock)


if __name__ == "__main__":
    sys.exit(main())
