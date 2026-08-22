#!/usr/bin/env python3
"""Hardened headless adapter for the curated Ghidra evidence exporter."""
import argparse, ctypes, hashlib, json, os, platform, re, shutil, signal, stat, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
sys.path.insert(0, str(Path(__file__).parent))
from lib.adapter_helpers import warn_evidence
from lib.isolation_profile import make_profile
SCHEMA = "ghidra-corroboration.v1"
SENTINEL = b"RSDD-SENTINEL"
KINDS = ("functions", "symbols", "imports", "exports", "strings", "references")
CHAIN = (
    "support/analyzeHeadless",
    "support/launch.sh",
    "support/launch.properties",
    "support/LaunchSupport.jar",
    "Ghidra/Framework/Utility/lib/Utility.jar",
    "Ghidra/application.properties",
)
RECORD_FIELDS = {
    "functions": {"address": str, "name": str, "external": bool, "thunk": bool},
    "symbols": {"address": str, "name": str, "type": str, "external": bool},
    "imports": {"address": str, "name": str, "type": str, "external": bool},
    "exports": {"address": str, "name": str, "type": str, "external": bool},
    "strings": {"address": str, "value": str, "value_truncated": bool},
    "references": {"from": str, "to": str, "type": str},
}
class GhidraError(ValueError): pass
def canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
def identity(path: Path) -> tuple[Path, int, str]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: fd = os.open(path, flags)
    except OSError as exc: raise GhidraError(f"cannot safely open {path}") from exc
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode): raise GhidraError(f"not a regular file: {path}")
        digest, total = hashlib.sha256(), 0
        while chunk := os.read(fd, 1024 * 1024): digest.update(chunk); total += len(chunk)
        after = os.fstat(fd); fields = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size: raise GhidraError(f"file changed while hashing: {path}")
        return Path(f"/proc/self/fd/{fd}").resolve(), total, "sha256:" + digest.hexdigest()
    finally: os.close(fd)
def fd_identity(fd: int) -> tuple[int,str]:
    digest=hashlib.sha256(); offset=0
    while chunk:=os.pread(fd,1024*1024,offset): digest.update(chunk); offset+=len(chunk)
    return offset,"sha256:"+digest.hexdigest()
def lock(path: Path, record: dict[str, Any]) -> int:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    if fd_identity(fd) != (record["size"], record["sha256"]): os.close(fd); raise GhidraError("staged identity changed before lock")
    return fd
def verify_lock(fd: int, path: Path, record: dict[str, Any]) -> None:
    if not path.exists() or not os.path.samefile(path, f"/proc/self/fd/{fd}"): raise GhidraError("staged pathname replaced")
    if fd_identity(fd) != (record["size"],record["sha256"]): raise GhidraError("locked staged bytes changed")
def stage_file(source: Path, target: Path, logical: str, mode: int, source_fd: int | None = None) -> tuple[dict[str, Any], dict[str, Any]]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: src = os.open(source, flags) if source_fd is None else os.dup(source_fd); os.lseek(src, 0, os.SEEK_SET)
    except OSError as exc: raise GhidraError("source cannot be opened safely") from exc
    digest, total = hashlib.sha256(), 0
    try:
        before = os.fstat(src)
        if not stat.S_ISREG(before.st_mode): raise GhidraError("source is not regular")
        resolved = Path(f"/proc/self/fd/{src}").resolve(); target.parent.mkdir(parents=True, exist_ok=True)
        out = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0), 0o600)
        try:
            while chunk := os.read(src, 1024 * 1024):
                digest.update(chunk); total += len(chunk); view = memoryview(chunk)
                while view: view = view[os.write(out, view):]
            os.fsync(out)
        finally: os.close(out)
        after = os.fstat(src); fields = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size: raise GhidraError("source changed while staging")
    finally: os.close(src)
    digest_text = "sha256:" + digest.hexdigest(); _, size, staged_digest = identity(target)
    if (size, staged_digest) != (total, digest_text): raise GhidraError("staged identity mismatch")
    target.chmod(mode)
    return ({"path": str(resolved), "size": total, "sha256": digest_text},
            {"path": logical, "size": size, "sha256": staged_digest})
def private_fs(path: Path) -> None:
    selected = (-1, "")
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        left, right = line.split(" - ", 1); mount = Path(left.split()[4].replace("\\040", " ").replace("\\134", "\\"))
        try: path.relative_to(mount)
        except ValueError: continue
        if len(mount.parts) > selected[0]: selected = (len(mount.parts), right.split()[0])
    if selected[1] in {"9p", "drvfs", "cifs", "smb3", "nfs", "nfs4", "fuseblk", "fuse.sshfs"}:
        raise GhidraError("output must reside on a Linux-private filesystem")
def trusted(path: Path, expected: Path | None = None) -> tuple[Path, dict[str, Any]]:
    resolved, size, digest = identity(path)
    if expected is not None and not os.path.samefile(resolved, expected): raise GhidraError("trusted path mismatch")
    if not os.access(resolved, os.X_OK): raise GhidraError("trusted executable is not executable")
    meta = resolved.stat()
    if meta.st_uid not in (0, os.getuid()) or meta.st_mode & 0o022: raise GhidraError("trusted executable is writable by others")
    return resolved, {"path": str(resolved), "size": size, "sha256": digest}
def trusted_bwrap(path: Path, test_only: bool) -> tuple[int, Path, dict[str, Any]]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: fd = os.open(path, flags)
    except OSError as exc: raise GhidraError("Bubblewrap cannot be opened safely") from exc
    try:
        meta = os.fstat(fd); resolved = Path(f"/proc/self/fd/{fd}").resolve()
        if not stat.S_ISREG(meta.st_mode) or not meta.st_mode & 0o111: raise GhidraError("Bubblewrap is not executable")
        if not test_only:
            selected = shutil.which("bwrap", path=os.defpath)
            if selected is None or not os.path.samefile(resolved, Path(selected).resolve()):
                raise GhidraError("Bubblewrap must match trusted PATH-selected bwrap")
            if meta.st_uid != 0 or meta.st_mode & 0o022: raise GhidraError("Bubblewrap must be root-owned and non-writable")
            for ancestor in resolved.parents:
                owner = ancestor.stat()
                if owner.st_uid != 0 or owner.st_mode & 0o022: raise GhidraError("Bubblewrap ancestor chain is not trusted")
        size, digest = fd_identity(fd)
        return fd, resolved, {"path": str(resolved), "size": size, "sha256": digest}
    except Exception:
        os.close(fd); raise
def write(path: Path, value: Any) -> None:
    temporary = path.with_name("." + path.name + ".tmp"); temporary.write_bytes(canonical(value))
    with temporary.open("rb") as stream: os.fsync(stream.fileno())
    os.replace(temporary, path)
def log_fd(path: Path, flags: int) -> int:
    try: fd = os.open(path, flags | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    except OSError as exc: raise GhidraError(f"unsafe diagnostic file: {path.name}") from exc
    if not stat.S_ISREG(os.fstat(fd).st_mode): os.close(fd); raise GhidraError(f"unsafe diagnostic file: {path.name}")
    return fd
def diagnostic_size(paths: tuple[Path, ...]) -> int:
    total = 0
    for path in paths:
        fd = log_fd(path, os.O_RDONLY)
        try: total += os.fstat(fd).st_size
        finally: os.close(fd)
    return total
def run_bounded(command: list[str], executable: str, cwd: Path, env: dict[str, str], seconds: int, cap: int, fds: tuple[int, ...]) -> tuple[dict[str, Any], list[str]]:
    stdout, stderr = cwd / "logs/stdout.txt", cwd / "logs/stderr.txt"; started_at = datetime.now(timezone.utc); started = time.monotonic(); reason = ""
    logs = (stdout, stderr, cwd / "logs/application.log", cwd / "logs/script.log")
    with os.fdopen(log_fd(stdout, os.O_WRONLY | os.O_CREAT | os.O_EXCL), "wb") as out, os.fdopen(log_fd(stderr, os.O_WRONLY | os.O_CREAT | os.O_EXCL), "wb") as err:
        ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)
        process = subprocess.Popen(command, executable=executable, cwd=cwd, env=env, stdout=out, stderr=err, start_new_session=True, pass_fds=fds)
        while process.poll() is None:
            try: diagnostic = diagnostic_size(logs)
            except GhidraError: reason = "unsafe-diagnostic"; diagnostic = 0
            if time.monotonic() - started >= seconds: reason = "wall-timeout"
            elif diagnostic > cap: reason = "diagnostic-cap"
            if reason:
                try: os.killpg(process.pid, signal.SIGTERM); process.wait(timeout=1)
                except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait()
                break
            time.sleep(.02)
        returncode = process.wait()
        try: os.killpg(process.pid, signal.SIGTERM); time.sleep(.05); os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        try:
            while True: os.waitpid(-process.pid, 0)
        except ChildProcessError: pass
    diagnostic = diagnostic_size(logs)
    if not reason and diagnostic > cap: reason = "diagnostic-cap"
    remaining = cap
    for path in logs:
        with os.fdopen(log_fd(path, os.O_RDWR), "r+b") as stream:
            data = stream.read(remaining); stream.seek(0); stream.write(data); stream.truncate()
        remaining -= len(data)
    ended = datetime.now(timezone.utc); run = {"started_at": started_at.isoformat().replace("+00:00", "Z"),
        "ended_at": ended.isoformat().replace("+00:00", "Z"), "duration_ms": int((time.monotonic()-started)*1000),
        "exit_code": returncode if returncode >= 0 else None, "signal": -returncode if returncode < 0 else None}
    errors = ([reason] if reason else []) + ([f"analyzer-exit:{returncode}"] if returncode and not reason else [])
    return run, errors
def validate_curated(path: Path, caps: dict[str, int], max_bytes: int) -> tuple[dict[str, Any] | None, list[str]]:
    if not path.exists(): return None, ["missing-curated-output"]
    if path.is_symlink() or not path.is_file():
        if path.is_symlink(): path.unlink()
        return None, ["unsafe-curated-output"]
    if path.stat().st_size > max_bytes:
        with path.open("r+b") as stream:
            raw = stream.read(max_bytes); stream.seek(0); stream.write(raw); stream.truncate()
        return None, ["curated-output-cap"]
    raw = path.read_bytes()
    if raw == SENTINEL: return None, ["unchanged-sentinel"]
    try:
        text = raw.decode("utf-8")
        value, end = json.JSONDecoder().raw_decode(text)
        if text[end:] != "\n": raise ValueError
        required = {"schema", "status", "program", "analysis", *KINDS, "counts", "caps", "truncation",
                    "string_values_truncated", "warnings", "errors", "limitations"}
        if not isinstance(value, dict) or set(value) != required or value["schema"] != "ghidra-curated-evidence.v1": raise ValueError
        if value["status"] not in ("complete", "partial") or not isinstance(value["caps"],dict) or any(type(item) is not int for item in value["caps"].values()) or value["caps"] != caps: raise ValueError
        program_fields = {"name", "format", "language", "compiler", "image_base", "md5"}
        if not isinstance(value["program"], dict) or set(value["program"]) != program_fields: raise ValueError
        if not all(isinstance(item, str) for item in value["program"].values()): raise ValueError
        if not isinstance(value["analysis"], dict) or set(value["analysis"]) != {"timed_out"}: raise ValueError
        if not isinstance(value["analysis"]["timed_out"], bool): raise ValueError
        shortened = value["string_values_truncated"]
        if isinstance(shortened, bool) or not isinstance(shortened, int) or shortened < 0: raise ValueError
        partial = value["analysis"]["timed_out"] or shortened > 0
        for kind in KINDS:
            count = value["counts"].get(kind, {})
            items = value[kind]
            truncated = value["truncation"].get(kind)
            if not isinstance(items, list) or len(items) > caps[kind] or type(count.get("emitted")) is not int or count["emitted"] != len(items): raise ValueError
            if set(count) != {"emitted", "observed", "exact"}: raise ValueError
            observed, exact = count["observed"], count["exact"]
            if isinstance(observed, bool) or not isinstance(observed, int) or observed < len(items) or observed > caps[kind] + 1: raise ValueError
            if not isinstance(exact, bool) or not isinstance(truncated, bool) or exact == truncated: raise ValueError
            if exact and observed != len(items): raise ValueError
            fields = RECORD_FIELDS[kind]
            for record in items:
                if not isinstance(record, dict) or set(record) != set(fields): raise ValueError
                if any(not isinstance(record[key], expected) for key, expected in fields.items()): raise ValueError
                if kind == "strings" and len(record["value"]) > caps["string_chars"]: raise ValueError
            partial |= truncated
        if (value["status"] == "partial") != partial: raise ValueError
        for diagnostic in ("warnings", "errors", "limitations"):
            if not isinstance(value[diagnostic], list) or not all(isinstance(item, str) for item in value[diagnostic]): raise ValueError
        return value, []
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, TypeError, AttributeError): return None, ["malformed-curated-output"]
def publish(stage: Path, destination: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if not hasattr(libc, "renameat2"): raise GhidraError("RENAME_NOREPLACE is unavailable")
    if libc.renameat2(-100, os.fsencode(stage), -100, os.fsencode(destination), 1):
        raise OSError(ctypes.get_errno(), "atomic no-replace publication failed", destination)
def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(); p.add_argument("--input", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    for name in ("ghidra-home", "analyze-headless", "java", "exporter", "bwrap", "manifest-cli"): p.add_argument("--"+name, type=Path, required=True, help=argparse.SUPPRESS)
    p.add_argument("--timeout-seconds", type=int, default=120); p.add_argument("--analysis-timeout", type=int, default=90)
    p.add_argument("--max-diagnostic-bytes", type=int, default=2_000_000); p.add_argument("--max-output-bytes", type=int, default=8_000_000)
    p.add_argument("--max-files", type=int, default=64); p.add_argument("--max-functions", type=int, default=10_000)
    p.add_argument("--max-strings", type=int, default=5_000); p.add_argument("--max-references", type=int, default=20_000)
    p.add_argument("--max-string-chars", type=int, default=1024); p.add_argument("--heap-mb", type=int, default=2048); p.add_argument("--cpus", type=int, default=2)
    p.add_argument("--test-only-untrusted-bwrap", action="store_true", help=argparse.SUPPRESS)
    args = p.parse_args(argv); stage: Path | None = None
    try:
        numeric = (args.timeout_seconds, args.analysis_timeout, args.max_diagnostic_bytes, args.max_output_bytes, args.max_files,
                   args.max_functions, args.max_strings, args.max_references, args.max_string_chars, args.heap_mb, args.cpus)
        if min(numeric) < 1 or args.max_files < 12: raise GhidraError("caps must be positive and max-files at least 12")
        source, _, _ = identity(args.input); parent = args.output.parent
        if parent != parent.resolve(strict=True): raise GhidraError("output parent must be canonical")
        if args.output.name in ("", ".", ".."): raise GhidraError("output name is invalid")
        private_fs(parent); destination = parent / args.output.name
        if destination.exists() or destination.is_symlink() or source == destination: raise GhidraError("output must be new and non-colliding")
        ghidra = args.ghidra_home.resolve(strict=True); java_home = args.java.resolve(strict=True).parent.parent
        analyze, analyze_record = trusted(args.analyze_headless, ghidra / "support/analyzeHeadless"); java, java_record = trusted(args.java, java_home / "bin/java")
        bwrap_fd, bwrap, bwrap_record = trusted_bwrap(args.bwrap, args.test_only_untrusted_bwrap); identity(args.exporter); identity(args.manifest_cli)
        candidate = parent / f".{destination.name}.stage"; candidate.mkdir(mode=0o700); stage = candidate
        stage_meta = stage.lstat()
        if not stat.S_ISDIR(stage_meta.st_mode) or stage_meta.st_uid != os.getuid() or stage_meta.st_mode & 0o077:
            raise GhidraError("staging directory is not private 0700")
        for directory in ("input", "script", "tool", "project", "output", "logs", "state/home", "state/cache", "state/config", "state/data", "state/tmp"):
            (stage / directory).mkdir(parents=True, exist_ok=True)
        for log in ("application.log", "script.log"): (stage/"logs"/log).touch(mode=0o600)
        source_record, staged_input = stage_file(args.input, stage/"input/target.bin", "input/target.bin", 0o400)
        provenance = []; pairs = [(args.exporter, "script/CuratedEvidenceExporter.java", 0o400),
            (bwrap, "tool/bwrap", 0o500), (args.manifest_cli, "tool/manifest.py", 0o400)]
        pairs += [(ghidra / item, "tool/ghidra/" + item, 0o500 if item.endswith(("analyzeHeadless", "launch.sh")) else 0o400) for item in CHAIN]
        pairs += [(java, "tool/jdk/bin/java", 0o500)]
        locked: list[tuple[int,Path,dict[str,Any]]] = []
        for src, logical, mode in pairs:
            original, staged = stage_file(src, stage/logical, logical, mode, bwrap_fd if logical == "tool/bwrap" else None)
            if logical == "tool/bwrap" and (original["size"], original["sha256"]) != (bwrap_record["size"], bwrap_record["sha256"]): raise GhidraError("staged Bubblewrap differs from authenticated identity")
            expected = analyze_record if logical.endswith("/analyzeHeadless") else java_record if logical == "tool/jdk/bin/java" else None
            if expected is not None and original != expected: raise GhidraError("trusted launcher changed before staging")
            if logical == "tool/bwrap": bwrap_record = staged
            provenance.append({"source": original, "staged": staged})
            locked.append((lock(stage/logical, staged), stage/logical, staged))
        locked.append((lock(stage/"input/target.bin", staged_input), stage/"input/target.bin", staged_input))
        app = (stage/"tool/ghidra/Ghidra/application.properties").read_text(); match = re.search(r"(?m)^application\.version=([^\r\n]+)$", app)
        if not match: raise GhidraError("staged application.properties has no version")
        version = match.group(1); caps = {"functions": args.max_functions, "symbols": args.max_functions, "imports": args.max_functions,
            "exports": args.max_functions, "strings": args.max_strings, "references": args.max_references, "string_chars": args.max_string_chars}
        root="/tmp/rsdd"; work=root+"/work"; groot=root+"/ghidra"; jroot=root+"/jdk"
        environment = {"HOME":work+"/state/home", "XDG_CACHE_HOME":work+"/state/cache", "XDG_CONFIG_HOME":work+"/state/config",
            "XDG_DATA_HOME":work+"/state/data", "TMPDIR":work+"/state/tmp", "JAVA_HOME":jroot, "PATH":jroot+"/bin:/usr/bin:/bin",
            "LANG":"C.UTF-8", "LC_ALL":"C.UTF-8", "TZ":"UTC"}
        command = ["tool/bwrap", "--die-with-parent", "--new-session", "--unshare-net", "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev",
            "--tmpfs",root,"--dir",work,"--dir",groot,"--dir",jroot,"--ro-bind",str(ghidra),groot,"--ro-bind",str(java_home),jroot,"--ro-bind",".",work]
        mounts = [("project",work+"/project",True),("output",work+"/output",True),("logs",work+"/logs",True),("state",work+"/state",True)]
        for host, guest, writable in mounts: command += ["--bind" if writable else "--ro-bind", host, guest]
        command += ["--ro-bind",f"/proc/self/fd/{locked[-1][0]}",work+"/input/target.bin"]
        for fd,path,record in locked[:1]: command += ["--ro-bind",f"/proc/self/fd/{fd}",work+"/"+record["path"]]
        for (fd,path,record),item in zip(locked[3:3+len(CHAIN)],CHAIN): command += ["--ro-bind",f"/proc/self/fd/{fd}",groot+"/"+item]
        command += ["--ro-bind",f"/proc/self/fd/{locked[3+len(CHAIN)][0]}",jroot+"/bin/java"]
        bound_tools = [item["staged"]["path"] for item in provenance if item["staged"]["path"] != "tool/bwrap"]
        command += ["--dir", root+"/provenance"]
        for index, logical in enumerate(bound_tools): command += ["--ro-bind", logical, f"{root}/provenance/{index}"]
        for key, value in environment.items(): command += ["--setenv", key, value]
        inner = ["/usr/bin/env", f"GHIDRA_HEADLESS_MAXMEM={args.heap_mb}M", "GHIDRA_HEADLESS_JAVA_OPTIONS=-Djava.io.tmpdir="+work+"/state/tmp", "/usr/bin/prlimit", f"--cpu={args.analysis_timeout+5}", "--",
            groot+"/support/analyzeHeadless", work+"/project", "rsdd", "-import", work+"/input/target.bin", "-readOnly", "-deleteProject",
            "-analysisTimeoutPerFile", str(args.analysis_timeout), "-max-cpu", str(args.cpus), "-scriptPath", work+"/script", "-postScript",
            "CuratedEvidenceExporter.java", work+"/output/curated.json", *map(str, caps.values()), "-log", work+"/logs/application.log",
            "-scriptlog", work+"/logs/script.log"]
        command += ["--chdir", work, "--", *inner]; pass_fds=tuple(fd for fd,_,_ in locked)
        bwrap_exec=f"/proc/self/fd/{locked[1][0]}"
        probe = subprocess.run(command[:command.index("--chdir")] + ["--chdir",work,"--","/bin/true"], executable=bwrap_exec, cwd=stage, env=environment, pass_fds=pass_fds,
                               timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if probe.returncode: raise GhidraError("Bubblewrap isolation probe failed")
        run, errors = run_bounded(command, bwrap_exec, stage, environment, args.timeout_seconds, args.max_diagnostic_bytes, pass_fds)
        curated, validation_errors = validate_curated(stage/"output/curated.json", caps, args.max_output_bytes); errors += validation_errors
        for fd,path,record in locked: verify_lock(fd,path,record)
        isolated = not args.test_only_untrusted_bwrap
        limitations = ["Listed launch-chain files, exporter, Java, Bubblewrap, and manifest CLI have byte provenance; Bubblewrap executes from its staged FD and argv[0] binds that staged artifact; the read-only remainder of Ghidra and JDK trees is unbound.",
            "Ghidra parses untrusted input in-process; Bubblewrap is not a hostile-parser boundary."]
        if not isolated: limitations.append("TEST ONLY: the untrusted Bubblewrap launcher does not establish an isolation claim.")
        completeness = "failed" if errors else curated["status"]
        curated_path = stage/"output/curated.json"
        outputs = ["logs/application.log", "logs/script.log"] + (["output/curated.json"] if curated_path.is_file() else [])
        report = {"schema":SCHEMA,"status":completeness,"input":{"source":source_record,"staged":staged_input},"provenance":provenance,
            "ghidra":{"version":version,"argv":inner,"manifest":"analysis-manifest.v1.json"},
            "run":{"exit_code":run["exit_code"],"signal":run["signal"]},"caps":{"wall_seconds":args.timeout_seconds,"analysis_seconds":args.analysis_timeout,
            "diagnostic_bytes":args.max_diagnostic_bytes,"output_bytes":args.max_output_bytes,"files":args.max_files,"functions":args.max_functions,
            "strings":args.max_strings,"references":args.max_references,"string_chars":args.max_string_chars,"heap_mb":args.heap_mb,"cpus":args.cpus},
             "isolation":{"launcher":bwrap_record,"network_access":not isolated,"target_execution":False,"read_only_host_root":isolated,
                          "new_session":isolated,"synthetic_user_state":isolated},
            "runtime":{"python":platform.python_version(),"kernel":platform.release()},"limitations":limitations,"errors":errors}
        write(stage/"report.json", report)
        outputs.append("report.json")
        spec = {"schema_version":"analysis-manifest.v1", "input":{"path":"input/target.bin","detected_type":None},
            "tool":{"name":"Ghidra","version":version,"executable":command[0],"artifacts":[{"path":path,"argv_index":command.index(path)} for path in bound_tools]}, "argv":command, "environment":environment,
            "run":run,"stdout_path":"logs/stdout.txt","stderr_path":"logs/stderr.txt","outputs":outputs,"findings":[],"limitations":limitations,
            "errors":errors,"completeness":completeness,"isolation_profile":make_profile("bubblewrap-ghidra-static" if isolated else "test-only-untrusted-bwrap",network_access=not isolated)}
        write(stage/"manifest-spec.json", spec); manifest = stage/"analysis-manifest.v1.json"
        manifest_fd=locked[2][0]; manifest_cli=f"/proc/self/fd/{manifest_fd}"
        subprocess.run([sys.executable,manifest_cli,"create","--root",str(stage),"--spec",str(stage/"manifest-spec.json"),"--output",str(manifest)],check=True,pass_fds=(manifest_fd,))
        (stage/"manifest-spec.json").unlink(); subprocess.run([sys.executable,manifest_cli,"validate",str(manifest)],check=True,pass_fds=(manifest_fd,))
        for fd,path,record in locked: verify_lock(fd,path,record)
        if sum(p.is_file() for p in stage.rglob("*")) > args.max_files: raise GhidraError("evidence file cap exceeded")
        publish(stage,destination); stage=None
        if completeness not in ("complete","partial"):
            warn_evidence(schema=SCHEMA, destination=destination, detail=f"completeness={completeness}")
        return 0 if completeness in ("complete","partial") else 1
    except (GhidraError,OSError,subprocess.SubprocessError,json.JSONDecodeError) as exc:
        print(f"corroborate-ghidra: {exc}",file=sys.stderr); return 2
    finally:
        for fd,_,_ in locals().get("locked", []): os.close(fd)
        if "bwrap_fd" in locals(): os.close(bwrap_fd)
        if stage is not None and stage.exists(): shutil.rmtree(stage)
if __name__ == "__main__": sys.exit(main())
