#!/usr/bin/env python3
"""Produce bounded, non-extracting Binwalk evidence for one firmware image."""
from __future__ import annotations

import argparse, ctypes, hashlib, json, os, re, resource, shutil, signal, stat, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from lib.adapter_core import AdapterError, refuse_privileged_execution
from lib.adapter_helpers import warn_evidence
from lib.isolation_profile import PROFILE_BWRAP_STATIC_NETWORK_DENIED

SCHEMA = "firmware-static.v1"
SUPPORTED_BINWALK_MAJOR = "2"
SAFE_ARGS = ["-B", "-E", "-N", "input/firmware.bin"]
PRIVATE_FS = {"btrfs", "ext2", "ext3", "ext4", "f2fs", "jfs", "nilfs2", "overlay", "ramfs", "reiserfs", "tmpfs", "ubifs", "xfs", "zfs"}


class FirmwareError(ValueError): pass


def canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def require_trusted(meta: os.stat_result, resolved: Path, trusted_uids: frozenset[int], hint: str) -> None:
    """Gate an analyzer on the DESCRIPTOR's own owner/mode (not a later path stat) and on its directory."""
    if meta.st_uid not in trusted_uids or meta.st_mode & 0o022:
        raise FirmwareError("Binwalk must be root-owned and non-writable" + hint)
    parent = resolved.parent.stat()
    if parent.st_uid not in trusted_uids or parent.st_mode & 0o022:
        raise FirmwareError("Binwalk's directory must be root-owned (or the invoking user's for RSDD_BINWALK) and not group/world-writable")


def identity(path: Path, max_bytes: int | None = None, trusted_uids: frozenset[int] | None = None, hint: str = "", uid_sink: dict[str, int] | None = None) -> tuple[Path, int, str]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: fd = os.open(path, flags)
    except OSError as exc: raise FirmwareError(f"cannot open regular non-symlink file: {path}") from exc
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode): raise FirmwareError(f"not a regular file: {path}")
        if max_bytes is not None and before.st_size > max_bytes: raise FirmwareError("input exceeds max-input-bytes")
        resolved = Path(f"/proc/self/fd/{fd}").resolve(); digest = hashlib.sha256(); total = 0
        if trusted_uids is not None: require_trusted(before, resolved, trusted_uids, hint)
        if uid_sink is not None: uid_sink["uid"] = before.st_uid
        while chunk := os.read(fd, min(1024 * 1024, max_bytes - total + 1) if max_bytes is not None else 1024 * 1024):
            total += len(chunk)
            if max_bytes is not None and total > max_bytes: raise FirmwareError("input exceeds max-input-bytes")
            digest.update(chunk)
        after = os.fstat(fd); fields = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size: raise FirmwareError(f"file changed while hashing: {path}")
        return resolved, total, "sha256:" + digest.hexdigest()
    finally: os.close(fd)


def stage_file(source: Path, target: Path, logical: str, mode: int, max_bytes: int | None = None, trusted_uids: frozenset[int] | None = None, uid_sink: dict[str, int] | None = None) -> tuple[dict[str, Any], dict[str, Any]]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: src = os.open(source, flags)
    except OSError as exc: raise FirmwareError("source cannot be opened safely") from exc
    digest = hashlib.sha256(); total = 0
    try:
        before = os.fstat(src)
        if not stat.S_ISREG(before.st_mode): raise FirmwareError("source is not a regular file")
        if max_bytes is not None and before.st_size > max_bytes: raise FirmwareError("input exceeds max-input-bytes")
        resolved = Path(f"/proc/self/fd/{src}").resolve()
        if trusted_uids is not None: require_trusted(before, resolved, trusted_uids, "")
        if uid_sink is not None: uid_sink["uid"] = before.st_uid
        out = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0), 0o600)
        try:
            while chunk := os.read(src, min(1024 * 1024, max_bytes - total + 1) if max_bytes is not None else 1024 * 1024):
                total += len(chunk)
                if max_bytes is not None and total > max_bytes: raise FirmwareError("input exceeds max-input-bytes")
                digest.update(chunk); view = memoryview(chunk)
                while view: view = view[os.write(out, view):]
            os.fsync(out)
        finally: os.close(out)
        after = os.fstat(src); stable = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if stable(before) != stable(after) or total != before.st_size: raise FirmwareError("source changed while staging")
    finally: os.close(src)
    digest_text = "sha256:" + digest.hexdigest(); _, size, copied_digest = identity(target, max_bytes)
    if (size, copied_digest) != (total, digest_text): raise FirmwareError("staged identity mismatch")
    target.chmod(mode)
    return ({"path": str(resolved), "size": total, "sha256": digest_text},
            {"path": logical, "size": size, "sha256": copied_digest})


def absolute_path(search: str) -> str:
    """Drop empty and relative PATH entries: a relative entry resolves against the caller's cwd (#1641)."""
    return os.pathsep.join(entry for entry in search.split(os.pathsep) if os.path.isabs(entry))


def executable(name: str, configured: str, search: str, trusted_uids: frozenset[int] | None = None, hint: str = "",
               must_match_path: bool = True, uid_sink: dict[str, int] | None = None) -> tuple[Path, dict[str, Any]]:
    search = absolute_path(search)
    candidate = Path(configured).resolve(strict=True)
    if must_match_path:
        selected = shutil.which(name, path=search)
        if selected is None: raise FirmwareError(f"PATH-selected {name} is missing")
        if not candidate.is_file() or not os.access(candidate, os.X_OK) or not os.path.samefile(candidate, Path(selected).resolve(strict=True)):
            raise FirmwareError(f"configured {name} does not match PATH-selected executable")
    elif not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise FirmwareError(f"configured {name} is not an executable file: {candidate}")
    resolved, size, digest = identity(candidate, trusted_uids=trusted_uids, hint=hint, uid_sink=uid_sink)
    return resolved, {"path": str(resolved), "size": size, "sha256": digest}


def binwalk_version(text: str) -> str | None:
    match = re.search(r"\b[Bb]inwalk (?:v(\S+)|(\d\S*))", text)
    return (match[1] or match[2]) if match else None


def check_binwalk_version(version: str) -> None:
    if version.split(".")[0] != SUPPORTED_BINWALK_MAJOR:
        raise FirmwareError(f"unsupported Binwalk version {version}: only major {SUPPORTED_BINWALK_MAJOR} output is supported")


def resolve_binwalk(environ: Any) -> tuple[Path, dict[str, Any], str, frozenset[int] | None]:
    """Select the analyzer (#1641): RSDD_BINWALK_TEST_ONLY (test), else an explicit absolute RSDD_BINWALK (used
    even when it is not first on PATH), else the PATH-selected binwalk. Returns path, record, trust label, trusted uids."""
    sink: dict[str, int] = {}
    test_only, explicit, search = environ.get("RSDD_BINWALK_TEST_ONLY"), environ.get("RSDD_BINWALK"), environ.get("PATH", "")
    if test_only:
        binwalk, record = executable("binwalk", test_only, search); return binwalk, record, "test-override", None
    if explicit:
        if not os.path.isabs(explicit): raise FirmwareError("RSDD_BINWALK must be an absolute path")
        uids = frozenset({0, os.geteuid()})
        binwalk, record = executable("binwalk", explicit, search, uids, " (RSDD_BINWALK: or owned by the invoking user, not group/world-writable)", must_match_path=False, uid_sink=sink)
    else:
        selected = shutil.which("binwalk", path=absolute_path(search))
        if selected is None: raise FirmwareError("PATH-selected binwalk is missing")
        uids = frozenset({0})
        binwalk, record = executable("binwalk", selected, search, frozenset({0}), "; set RSDD_BINWALK=<absolute path> to select a user-owned install", uid_sink=sink)
    return binwalk, record, ("root-owned" if sink["uid"] == 0 else "user-owned-explicit"), uids


def require_private(path: Path, mountinfo: str | None = None) -> None:
    selected = (-1, "")
    for line in (mountinfo if mountinfo is not None else Path("/proc/self/mountinfo").read_text()).splitlines():
        try: left, right = line.split(" - ", 1); mount = Path(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), left.split()[4])); fs = right.split()[0]
        except (IndexError, ValueError): continue
        try: path.relative_to(mount)
        except ValueError: continue
        if len(mount.parts) > selected[0]: selected = (len(mount.parts), fs)
    if selected[1] not in PRIVATE_FS:
        raise FirmwareError("output must reside on a Linux-private filesystem")


def sandbox(bwrap: Path, env: dict[str, str]) -> list[str]:
    root = Path("/tmp/rsdd"); root.mkdir(mode=0o700, exist_ok=True); meta = root.lstat()
    if stat.S_ISLNK(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o077: raise FirmwareError("unsafe Bubblewrap mountpoint")
    command = [str(bwrap), "--die-with-parent", "--new-session", "--unshare-net", "--unshare-pid", "--cap-drop", "ALL", "--ro-bind", "/", "/",
               "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/home", "--dir", "/tmp/rsdd/cache",
               "--dir", "/tmp/rsdd/config", "--dir", "/tmp/rsdd/data", "--dir", "/tmp/rsdd/work", "--ro-bind", ".", "/tmp/rsdd/work"]
    for key, value in env.items(): command += ["--setenv", key, value]
    return command + ["--chdir", "/tmp/rsdd/work", "--"]


def tree_size(root: int) -> int:
    parents: dict[int, int] = {}
    for path in Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = path.read_text().rsplit(")", 1)[1].split(); parents[int(path.parent.name)] = int(fields[1])
        except (OSError, IndexError, ValueError): pass
    descendants = {root}
    while True:
        expanded = descendants | {pid for pid, parent in parents.items() if parent in descendants}
        if expanded == descendants: return len(descendants & parents.keys())
        descendants = expanded


def stop_group(group: int) -> None:
    for sig, delay in ((signal.SIGTERM, .5), (signal.SIGKILL, .5)):
        try: os.killpg(group, sig)
        except ProcessLookupError: return
        deadline = time.monotonic() + delay
        while time.monotonic() < deadline and tree_size(group): time.sleep(.01)


def run(command: list[str], cwd: Path, env: dict[str, str], timeout: int, max_bytes: int, max_processes: int) -> tuple[dict[str, Any], list[str]]:
    out, err = cwd / "engine/stdout.txt", cwd / "engine/stderr.txt"; wall = datetime.now(timezone.utc); started = time.monotonic(); reason = ""
    with out.open("wb") as stdout, err.open("wb") as stderr:
        def limit() -> None:
            hard = resource.getrlimit(resource.RLIMIT_FSIZE)[1]; cap = max_bytes if hard == resource.RLIM_INFINITY else min(max_bytes, hard)
            resource.setrlimit(resource.RLIMIT_FSIZE, (cap, cap))
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stdout, stderr=stderr, start_new_session=True, preexec_fn=limit)
        while process.poll() is None:
            if time.monotonic() - started >= timeout: reason = "timeout"
            elif out.stat().st_size + err.stat().st_size >= max_bytes: reason = "diagnostic-cap"
            elif max(0, tree_size(process.pid) - 1) > max_processes: reason = "process-cap"
            if reason: break
            time.sleep(.02)
        returncode = process.poll()
        stop_group(process.pid)
        if returncode is None: returncode = process.wait()
    if not reason and out.stat().st_size + err.stat().st_size >= max_bytes: reason = "diagnostic-cap"
    if reason:
        budget = max_bytes
        for path in (out, err):
            with path.open("r+b") as stream: data = stream.read(budget); stream.seek(0); stream.write(data); stream.truncate()
            budget -= len(data)
    ended = datetime.now(timezone.utc); run_record = {"started_at": wall.isoformat().replace("+00:00", "Z"),
        "ended_at": ended.isoformat().replace("+00:00", "Z"), "duration_ms": int((time.monotonic() - started) * 1000),
        "exit_code": returncode if returncode >= 0 else None, "signal": -returncode if returncode < 0 else None}
    errors = ([reason] if reason else []) + ([f"analyzer-exit:{returncode}"] if returncode and not reason else [])
    return run_record, errors


def write(path: Path, value: Any) -> None:
    temporary = path.with_name("." + path.name + ".tmp"); temporary.write_bytes(canonical(value))
    with temporary.open("rb") as stream: os.fsync(stream.fileno())
    os.replace(temporary, path)


def normalized(path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    signatures, entropy = [], []
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"^\s*(\d+)\s+0x([0-9a-fA-F]+)\s+(.+?)\s*$", re.sub(r"\x1b\[[0-9;]*m", "", line))
        if not match: continue
        item = {"description": " ".join(match[3].split()), "hex": f"0x{int(match[2], 16):x}", "offset": int(match[1])}
        (entropy if "entropy" in item["description"].lower() else signatures).append(item)
    key = lambda item: (item["offset"], item["description"])
    return sorted(signatures, key=key), sorted(entropy, key=key)


def publish(stage: Path, destination: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True); function = getattr(libc, "renameat2", None)
    if function is None: raise FirmwareError("atomic no-replace publication is unavailable")
    if function(-100, os.fsencode(stage), -100, os.fsencode(destination), 1):
        raise OSError(ctypes.get_errno(), "atomic publication failed", destination)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--input", type=Path, required=True); parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=30); parser.add_argument("--max-diagnostic-bytes", type=int, default=2_000_000)
    parser.add_argument("--max-input-bytes", type=int, default=1_073_741_824)
    parser.add_argument("--max-findings", type=int, default=10_000); parser.add_argument("--max-processes", type=int, default=32)
    parser.add_argument("--max-files", type=int, default=7); parser.add_argument("--manifest-cli", type=Path, required=True, help=argparse.SUPPRESS); args = parser.parse_args(argv)
    stage: Path | None = None
    try:
        refuse_privileged_execution()
        if min(args.timeout_seconds, args.max_diagnostic_bytes, args.max_input_bytes, args.max_findings, args.max_processes) < 1 or args.max_files < 7: raise FirmwareError("caps must be positive and max-files at least 7")
        source, _, _ = identity(args.input, args.max_input_bytes); parent = args.output.parent.resolve(strict=True); require_private(parent); destination = parent / args.output.name
        if destination.exists() or destination.is_symlink() or source == destination: raise FirmwareError("output must be a new non-colliding path")
        candidate = parent / f".{destination.name}.stage"; candidate.mkdir(mode=0o700); stage = candidate
        (stage / "input").mkdir(); (stage / "engine").mkdir()
        source_record, staged_input = stage_file(args.input, stage / "input/firmware.bin", "input/firmware.bin", 0o400, args.max_input_bytes)
        override = os.environ.get("RSDD_BINWALK_TEST_ONLY")
        binwalk, source_binwalk, trust, binwalk_uids = resolve_binwalk(os.environ)
        stage_sink: dict[str, int] = {}
        copied_binwalk, staged_binwalk = stage_file(binwalk, stage / "engine/binwalk", "engine/binwalk", 0o500, trusted_uids=binwalk_uids, uid_sink=stage_sink)
        if binwalk_uids is not None: trust = "root-owned" if stage_sink["uid"] == 0 else "user-owned-explicit"  # the bytes that run
        if copied_binwalk != source_binwalk: raise FirmwareError("analyzer changed before trusted staging")
        safe_path = "/usr/bin:/bin"; bwrap, bwrap_record = executable("bwrap", os.environ.get("RSDD_BWRAP", "/usr/bin/bwrap"), safe_path)
        meta = bwrap.stat()
        if meta.st_uid != 0 or meta.st_mode & 0o022: raise FirmwareError("Bubblewrap must be root-owned and non-writable")
        env = {"HOME": "/tmp/rsdd/home", "XDG_CACHE_HOME": "/tmp/rsdd/cache", "XDG_CONFIG_HOME": "/tmp/rsdd/config", "XDG_DATA_HOME": "/tmp/rsdd/data",
               "TMPDIR": "/tmp/rsdd", "PATH": safe_path, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC"}
        prefix = sandbox(bwrap, env); probe = subprocess.run(prefix + ["/bin/sh", "-c", "! grep -Eq '^Cap(Inh|Prm|Eff|Bnd|Amb):.*[1-9a-fA-F]' /proc/self/status"], cwd=stage, env=env, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if probe.returncode: raise FirmwareError("network-denied zero-capability isolation probe failed")
        _, version_errors = run(prefix + ["engine/binwalk", "--help"], stage, env, min(5, args.timeout_seconds), args.max_diagnostic_bytes, args.max_processes)
        if version_errors: raise FirmwareError("bounded Binwalk version probe failed: " + ",".join(version_errors))
        version = binwalk_version((stage / "engine/stdout.txt").read_text(errors="replace"))
        if version is None:  # binwalk 3.x has no version banner in --help; ask it directly
            _, version_errors = run(prefix + ["engine/binwalk", "--version"], stage, env, min(5, args.timeout_seconds), args.max_diagnostic_bytes, args.max_processes)
            if version_errors: raise FirmwareError("bounded Binwalk version probe failed: " + ",".join(version_errors))
            version = binwalk_version((stage / "engine/stdout.txt").read_text(errors="replace"))
        if version is None: raise FirmwareError("Binwalk version is unavailable")
        if not override: check_binwalk_version(version)
        inner = ["engine/binwalk", *SAFE_ARGS]; command = prefix + inner
        run_record, errors = run(command, stage, env, args.timeout_seconds, args.max_diagnostic_bytes, args.max_processes)
        signatures, entropy = normalized(stage / "engine/stdout.txt"); combined = [("signature", item) for item in signatures] + [("entropy", item) for item in entropy]
        emitted = combined[:args.max_findings]; truncated = len(combined) > len(emitted)
        signatures_out = [item for kind, item in emitted if kind == "signature"]; entropy_out = [item for kind, item in emitted if kind == "entropy"]
        write(stage / "engine/signatures.json", signatures_out); write(stage / "engine/entropy.json", entropy_out)
        limitations = ["Binwalk signatures and entropy edges are heuristic, not proof of extractability or execution behavior.",
            ("The distro Binwalk package, Python dependencies, and magic database are read-only but are not artifact-bound by this report."
             if trust == "root-owned" else
             "The analyzer is a test override; its installation is not covered by any trust check."
             if trust == "test-override" else
             "The analyzer is not root-owned (explicit RSDD_BINWALK): its installation, Python dependencies, and magic database are writable by the invoking user and are not artifact-bound by this report."),
            "Bubblewrap on WSL2 is defense in depth, not a hostile-parser security boundary; use a disposable VM for hostile firmware."]
        if override: limitations.append("RSDD_BINWALK_TEST_ONLY selected a test analyzer; this is not official Binwalk evidence.")
        status = "failed" if errors else "partial" if truncated else "complete"
        profile = PROFILE_BWRAP_STATIC_NETWORK_DENIED
        spec = {"schema_version": "analysis-manifest.v1", "input": {"path": "input/firmware.bin", "detected_type": "firmware or opaque binary"},
            "tool": {"name": "binwalk-test-override" if override else "binwalk", "version": version, "executable": str(bwrap), "artifacts": [{"path": "engine/binwalk", "argv_index": command.index("engine/binwalk")}]},
            "argv": command, "environment": env, "run": run_record, "stdout_path": "engine/stdout.txt", "stderr_path": "engine/stderr.txt",
            "outputs": ["engine/signatures.json", "engine/entropy.json"], "findings": [], "limitations": limitations, "errors": errors,
            "completeness": status, "isolation_profile": profile}
        write(stage / "engine/manifest-spec.json", spec); manifest = stage / "engine/analysis-manifest.v1.json"
        subprocess.run([sys.executable, str(args.manifest_cli), "create", "--root", str(stage), "--spec", str(stage / "engine/manifest-spec.json"), "--output", str(manifest)], check=True)
        (stage / "engine/manifest-spec.json").unlink(); subprocess.run([sys.executable, str(args.manifest_cli), "validate", str(manifest)], check=True)
        subprocess.run([sys.executable, str(args.manifest_cli), "verify", "--root", str(stage), str(manifest)], check=True)
        report = {"schema": SCHEMA, "status": status, "input": {"source": source_record, "staged": staged_input},
            "isolation": {"launcher": bwrap_record, "profile": profile}, "engine": {"name": "binwalk", "version": version, "test_override": bool(override), "trust": trust,
            "launcher": {"source": source_binwalk, "staged": staged_binwalk}, "argv": inner, "run": {key: run_record[key] for key in ("exit_code", "signal")},
            "manifest": "engine/analysis-manifest.v1.json", "manifest_identity": json.loads(manifest.read_text())["identity"]},
            "signatures": signatures_out, "entropy": entropy_out, "counts": {"signatures_total": len(signatures), "entropy_total": len(entropy),
            "findings_total": len(combined), "findings_emitted": len(emitted)}, "caps": {"timeout_seconds": args.timeout_seconds,
            "max_diagnostic_bytes": args.max_diagnostic_bytes, "max_input_bytes": args.max_input_bytes, "max_findings": args.max_findings, "max_processes": args.max_processes, "max_files": args.max_files},
            "truncated": {"findings": truncated}, "limitations": limitations, "errors": errors}
        write(stage / f"{SCHEMA}.json", report)
        if sum(path.is_file() for path in stage.rglob("*")) - 1 > args.max_files: raise FirmwareError("evidence file cap exceeded")
        publish(stage, destination); stage = None
        if status != "complete":
            warn_evidence(schema=SCHEMA, destination=destination, detail=f"status={status}")
        return 0 if status == "complete" else 1
    except (FirmwareError, AdapterError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"corroborate-firmware: {exc}", file=sys.stderr); return 2
    finally:
        if stage is not None and stage.exists(): shutil.rmtree(stage)


if __name__ == "__main__": sys.exit(main())
