#!/usr/bin/env python3
"""Create and validate deterministic Research-SDD analysis manifests.

This module only reads artifacts and supplied run metadata. It never launches the
target or the recorded tool.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import unicodedata
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import unquote

SCHEMA_VERSION = "analysis-manifest.v1"
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
LOCATION_RE = re.compile(r"^(?P<path>[^:]+):(?P<start>[1-9][0-9]*)(?:-(?P<end>[1-9][0-9]*))?$")
SECRET_KEY_RE = re.compile(r"(?i)(secret|token|passw(?:or)?d|credential|private|api[_-]?key|auth|cookie)")
SECRET_VALUE_RE = re.compile(r"(?i)(bearer\s+\S+|ghp_[A-Za-z0-9]{20,}|xoxb-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.|AKIA[0-9A-Z]{16}|-----BEGIN\s+[^-]*PRIVATE KEY-----|(?:secret|token|passw(?:or)?d|api[_-]?key|authorization|cookie)\s*[:=])")
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
SECRET_OPTION_RE = re.compile(r"(?i)(?:^|[-_])(?:passw(?:or)?d|token|secret|credential|private[-_]?key|api[-_]?key|authorization|cookie)(?:$|[-_])")
ENV_ALLOWLIST = frozenset({
    "HOME", "JAVA_HOME", "LANG", "LC_ALL", "PATH", "SHELL", "TMPDIR", "TZ", "USER",
    "HOMEBREW_PREFIX", "RSDD_BREW_PREFIX", "RSDD_PROBE_TIMEOUT",
    "RESEARCH_SDD_JAVA_HOME", "RESEARCH_SDD_TOOL_HOME",
    "RSDD_DECOMPILE_MAX_HEAP",
    "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
})


class ManifestError(ValueError):
    """A fail-closed contract violation."""


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _keys(value: Any, expected: set[str], context: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        missing = sorted(expected - set(value)) if isinstance(value, dict) else sorted(expected)
        extra = sorted(set(value) - expected) if isinstance(value, dict) else []
        raise ManifestError(f"{context} fields invalid; missing={missing}, extra={extra}")
    return value


def _text(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ManifestError(f"{context} must be a non-empty string")
    return value


def _relative(value: Any, context: str) -> str:
    text = _text(value, context)
    normalized = text
    for _ in range(8):
        decoded = unicodedata.normalize("NFKC", unquote(normalized))
        if decoded == normalized:
            break
        normalized = decoded
    else:
        raise ManifestError(f"{context} exceeds normalization limit")
    path = PurePosixPath(normalized)
    if "\\" in normalized or SCHEME_RE.match(normalized) or path.is_absolute() or any(part in ("", ".", "..") for part in path.parts) or path.as_posix() != normalized:
        raise ManifestError(f"{context} must be a canonical artifact-relative path")
    return text


def _file_identity(path: Path, root: Path | None = None) -> tuple[str, int, str, int]:
    """Hash one stable descriptor and return resolved path, size, digest, lines."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    if not hasattr(os, "O_NOFOLLOW") and path.is_symlink():
        raise ManifestError("final symlink is not allowed")
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise ManifestError("file identity cannot be opened safely") from exc
    try:
        resolved = Path(f"/proc/self/fd/{fd}").resolve() if Path("/proc/self/fd").is_dir() else path.resolve()
        if root is not None:
            try: resolved.relative_to(root)
            except ValueError as exc: raise ManifestError("opened file escapes analysis root") from exc
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ManifestError("file identity is not a regular file")
        digest, total, lines, last = hashlib.sha256(), 0, 0, b""
        while chunk := os.read(fd, 1024 * 1024):
            digest.update(chunk); total += len(chunk); lines += chunk.count(b"\n"); last = chunk[-1:]
        after = os.fstat(fd)
        fields = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size:
            raise ManifestError("file changed while hashing")
        return str(resolved), total, "sha256:" + digest.hexdigest(), lines + int(total > 0 and last != b"\n")
    finally:
        os.close(fd)


def _analysis_artifact_path(value: Any, context: str) -> str:
    text = _text(value, context)
    path = PurePosixPath(text)
    if not path.is_absolute():
        return _relative(text, context)
    if text.startswith("//") or "\\" in text or path.as_posix() != text or any(part in (".", "..") for part in path.parts):
        raise ManifestError(f"{context} must be a canonical absolute or artifact-relative path")
    return text


def _artifact_identity(root: Path, relative: Any, context: str, analysis_tool: bool = False) -> tuple[dict[str, Any], int]:
    recorded = _analysis_artifact_path(relative, context) if analysis_tool else _relative(relative, context)
    external = Path(recorded).is_absolute()
    _, size, digest, lines = _file_identity(Path(recorded) if external else root / recorded, None if external else root)
    return {"path": recorded, "size": size, "sha256": digest}, lines


def _artifact(root: Path, relative: Any, context: str, analysis_tool: bool = False) -> dict[str, Any]:
    return _artifact_identity(root, relative, context, analysis_tool)[0]


def _resolve_tool(argv0: str, claimed: str, root: Path, environment: dict[str, str]) -> dict[str, Any]:
    search_path: list[tuple[Path, bool]] | None = None

    def path_directories() -> list[tuple[Path, bool]]:
        nonlocal search_path
        if search_path is not None:
            return search_path
        search_path = []
        for index, entry in enumerate(environment.get("PATH", "").split(os.pathsep)):
            expanded = Path(entry).expanduser()
            constrained = not expanded.is_absolute()
            if entry in ("", "."):
                directory = root
            elif constrained:
                directory = root / _relative(entry, f"environment PATH entry[{index}]")
            else:
                directory = expanded
            if constrained:
                directory = directory.resolve()
                try:
                    directory.relative_to(root)
                except ValueError as exc:
                    raise ManifestError("relative PATH entry escapes analysis root") from exc
            search_path.append((directory, constrained))
        return search_path

    def candidate(value: str) -> tuple[Path, bool] | None:
        path = Path(value).expanduser()
        if path.is_absolute():
            return path, False
        if "/" in value or "\\" in value:
            return root / _relative(value, "tool command path"), True
        for directory, constrained in path_directories():
            option = directory / value
            if option.is_file():
                return option, constrained
        return None

    invoked, declared = candidate(argv0), candidate(claimed)
    if invoked is None:
        raise ManifestError("tool command is unresolved or mismatched")
    invoked_path = Path(os.path.abspath(invoked[0]))
    if declared is None or not os.path.samefile(declared[0], invoked_path):
        raise ManifestError("tool identity does not match argv zero")
    before = invoked_path.stat()
    resolved, _, digest, _ = _file_identity(invoked_path, root if invoked[1] else None)
    after = invoked_path.stat(); stable = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if stable(before) != stable(after) or not os.path.samefile(declared[0], resolved):
        raise ManifestError("tool launcher changed while resolving identity")
    if not os.access(resolved, os.X_OK):
        raise ManifestError("tool launcher is not executable")
    recorded = argv0 if invoked[1] and "/" in argv0 else resolved
    return {"resolved_executable": recorded, "sha256": digest}


def _safe_argv(value: Any) -> list[str]:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) for item in value):
        raise ManifestError("argv must be a non-empty string array")
    for index, item in enumerate(value):
        option = item.split("=", 1)[0]
        if SECRET_VALUE_RE.search(item) or (option.startswith("-") and SECRET_OPTION_RE.search(option.lstrip("-"))):
            raise ManifestError(f"argv item {index} is secret-like; redact before capture")
    return value


def _bound_argv_index(value: Any, argv: list[str], path: str, seen: set[int]) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0 or value >= len(argv) or value in seen:
        raise ManifestError("analysis artifact argv_index must be unique, nonzero, and in range")
    if argv[value] != path:
        raise ManifestError("analysis artifact path must equal its argv token")
    seen.add(value)
    return value


def _atomic_write(path: Path, payload: bytes, overwrite: bool) -> None:
    path = path.parent.resolve() / path.name
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp_path = Path(temporary)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        if overwrite:
            os.replace(temp_path, path)
        else:
            try: os.link(temp_path, path)
            except FileExistsError as exc: raise ManifestError("manifest exists; use --overwrite to replace it") from exc
            temp_path.unlink()
        directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try: os.fsync(directory)
        finally: os.close(directory)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def sanitize_environment(value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ManifestError("environment must be an object")
    clean: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or key not in ENV_ALLOWLIST or SECRET_KEY_RE.search(key):
            raise ManifestError(f"environment key is not allowlisted or is secret-like: {key!r}")
        if not isinstance(item, str) or SECRET_VALUE_RE.search(item):
            raise ManifestError(f"environment value is invalid or secret-like for {key}")
        clean[key] = item
    return clean


def _identity(manifest: dict[str, Any]) -> str:
    stable = copy.deepcopy(manifest)
    stable.pop("identity", None)
    for field in ("started_at", "ended_at", "duration_ms"):
        stable["run"].pop(field, None)
    return "sha256:" + hashlib.sha256(canonical_bytes(stable)).hexdigest()


def build_manifest(spec: dict[str, Any], root: Path) -> dict[str, Any]:
    expected = {"schema_version", "input", "tool", "argv", "environment", "run", "stdout_path", "stderr_path", "outputs", "findings", "limitations", "errors", "completeness", "isolation_profile"}
    _keys(spec, expected, "spec")
    if spec["schema_version"] != SCHEMA_VERSION:
        raise ManifestError(f"unknown schema version: {spec['schema_version']!r}")
    root = root.resolve()
    argv = _safe_argv(spec["argv"])
    environment = sanitize_environment(spec["environment"])
    input_spec = _keys(spec["input"], {"path", "detected_type"}, "input spec")
    input_record = _artifact(root, input_spec["path"], "input.path")
    input_record.update(name=PurePosixPath(input_record["path"]).name, detected_type=input_spec["detected_type"])
    if input_record["detected_type"] is not None:
        _text(input_record["detected_type"], "input.detected_type")

    tool_spec = _keys(spec["tool"], {"name", "version", "executable", "artifacts"}, "tool spec")
    if not isinstance(tool_spec["artifacts"], list):
        raise ManifestError("tool.artifacts must be an array")
    tool_artifacts, artifact_indices = [], set()
    for index, value in enumerate(tool_spec["artifacts"]):
        item = _keys(value, {"path", "argv_index"}, f"tool.artifacts[{index}]")
        path = _analysis_artifact_path(item["path"], "analysis artifact path")
        argv_index = _bound_argv_index(item["argv_index"], argv, path, artifact_indices)
        record = _artifact(root, path, f"tool.artifacts[{index}].path", True)
        record["argv_index"] = argv_index
        tool_artifacts.append(record)
    tool = {
        "name": _text(tool_spec["name"], "tool.name"),
        "version": _text(tool_spec["version"], "tool.version"),
        "launcher": _resolve_tool(argv[0], _text(tool_spec["executable"], "tool.executable"), root, environment),
        "artifacts": sorted(tool_artifacts, key=lambda item: item["argv_index"]),
    }
    outputs = [_artifact(root, item, f"outputs[{index}]") for index, item in enumerate(spec["outputs"])] if isinstance(spec["outputs"], list) else None
    if outputs is None:
        raise ManifestError("outputs must be an array")
    findings = copy.deepcopy(spec["findings"])
    if not isinstance(findings, list):
        raise ManifestError("findings must be an array")
    for index, finding in enumerate(findings):
        _keys(finding, {"id", "claim", "evidence_locations"}, f"findings[{index}]")
        finding["id"], finding["claim"] = _text(finding["id"], "finding.id"), _text(finding["claim"], "finding.claim")
        if not isinstance(finding["evidence_locations"], list) or not finding["evidence_locations"]:
            raise ManifestError("finding evidence_locations must be a non-empty array")

    manifest = {
        "schema_version": SCHEMA_VERSION, "identity": "", "input": input_record, "tool": tool,
        "argv": argv, "environment": environment, "run": copy.deepcopy(spec["run"]),
        "stdout": _artifact(root, spec["stdout_path"], "stdout_path"), "stderr": _artifact(root, spec["stderr_path"], "stderr_path"),
        "outputs": sorted(outputs, key=lambda item: item["path"]), "findings": sorted(findings, key=lambda item: item["id"]),
        "limitations": copy.deepcopy(spec["limitations"]), "errors": copy.deepcopy(spec["errors"]), "completeness": spec["completeness"],
        "isolation_profile": copy.deepcopy(spec["isolation_profile"]),
    }
    manifest["identity"] = _identity(manifest)
    validate_manifest(manifest)
    return manifest


def validate_manifest(manifest: dict[str, Any]) -> None:
    top = {"schema_version", "identity", "input", "tool", "argv", "environment", "run", "stdout", "stderr", "outputs", "findings", "limitations", "errors", "completeness", "isolation_profile"}
    _keys(manifest, top, "manifest")
    if manifest["schema_version"] != SCHEMA_VERSION:
        raise ManifestError(f"unknown schema version: {manifest['schema_version']!r}")
    if not isinstance(manifest["identity"], str) or not HASH_RE.fullmatch(manifest["identity"]):
        raise ManifestError("identity is not a SHA-256 identity")
    inp = _keys(manifest["input"], {"path", "name", "size", "sha256", "detected_type"}, "input")
    argv = _safe_argv(manifest["argv"])
    tool = _keys(manifest["tool"], {"name", "version", "launcher", "artifacts"}, "tool")
    launcher = _keys(tool["launcher"], {"resolved_executable", "sha256"}, "tool.launcher")
    artifacts = [inp, _keys(manifest["stdout"], {"path", "size", "sha256"}, "stdout"), _keys(manifest["stderr"], {"path", "size", "sha256"}, "stderr")]
    if not isinstance(manifest["outputs"], list):
        raise ManifestError("outputs must be an array")
    artifacts += [_keys(item, {"path", "size", "sha256"}, "output") for item in manifest["outputs"]]
    if not isinstance(tool["artifacts"], list):
        raise ManifestError("tool.artifacts must be an array")
    artifact_indices: set[int] = set()
    analysis_records = []
    for item in tool["artifacts"]:
        record = _keys(item, {"path", "size", "sha256", "argv_index"}, "tool artifact")
        path = _analysis_artifact_path(record["path"], "analysis artifact path")
        _bound_argv_index(record["argv_index"], argv, path, artifact_indices)
        analysis_records.append(record)
    for item in artifacts:
        _relative(item["path"], "artifact.path")
    for item in [*artifacts, *analysis_records]:
        if isinstance(item["size"], bool) or not isinstance(item["size"], int) or item["size"] < 0 or not isinstance(item["sha256"], str) or not HASH_RE.fullmatch(item["sha256"]):
            raise ManifestError("artifact size or SHA-256 is invalid")
    artifacts += analysis_records
    if inp["name"] != PurePosixPath(inp["path"]).name or (inp["detected_type"] is not None and (not isinstance(inp["detected_type"], str) or not inp["detected_type"].strip())):
        raise ManifestError("input name or detected_type is invalid")
    for field in ("name", "version"):
        _text(tool[field], f"tool.{field}")
    executable = _text(launcher["resolved_executable"], "tool.launcher.resolved_executable")
    if not Path(executable).is_absolute():
        _relative(executable, "tool.launcher.resolved_executable")
    argv0 = argv[0]
    if "/" in argv0 or "\\" in argv0:
        if executable != argv0:
            raise ManifestError("tool launcher is not coherent with argv zero")
    else:
        path_dirs = [Path(item).expanduser().resolve() for item in manifest["environment"].get("PATH", "").split(os.pathsep) if Path(item).is_absolute()]
        if not Path(executable).is_absolute() or Path(executable).name != argv0 or Path(executable).parent not in path_dirs:
            raise ManifestError("PATH launcher is not coherent with argv zero")
    if not isinstance(launcher["sha256"], str) or not HASH_RE.fullmatch(launcher["sha256"]):
        raise ManifestError("tool SHA-256 is invalid")
    sanitize_environment(manifest["environment"])
    run = _keys(manifest["run"], {"started_at", "ended_at", "duration_ms", "exit_code", "signal"}, "run")
    timestamps = []
    for field in ("started_at", "ended_at"):
        if not isinstance(run[field], str) or not run[field].endswith("Z"):
            raise ManifestError(f"run.{field} must be UTC ISO-8601")
        timestamps.append(datetime.fromisoformat(run[field].replace("Z", "+00:00")))
    if timestamps[1] < timestamps[0]:
        raise ManifestError("run.ended_at precedes run.started_at")
    if isinstance(run["duration_ms"], bool) or not isinstance(run["duration_ms"], int) or run["duration_ms"] < 0:
        raise ManifestError("run.duration_ms is invalid")
    if (run["exit_code"] is None) == (run["signal"] is None) or any(value is not None and (isinstance(value, bool) or not isinstance(value, int) or value < 0) for value in (run["exit_code"], run["signal"])):
        raise ManifestError("run requires exactly one non-negative exit_code or signal")
    known_paths = {item["path"] for item in artifacts}
    if not isinstance(manifest["findings"], list):
        raise ManifestError("findings must be an array")
    finding_ids: set[str] = set()
    for finding in manifest["findings"]:
        _keys(finding, {"id", "claim", "evidence_locations"}, "finding")
        finding_id = _text(finding["id"], "finding.id")
        _text(finding["claim"], "finding.claim")
        if finding_id in finding_ids:
            raise ManifestError("finding IDs must be unique")
        finding_ids.add(finding_id)
        if not isinstance(finding["evidence_locations"], list) or not finding["evidence_locations"]:
            raise ManifestError("finding evidence_locations is invalid")
        for location in finding["evidence_locations"]:
            path, start, end = _evidence_location(location)
            if path not in known_paths or end < start:
                raise ManifestError("finding evidence location is invalid or unbound")
    for field in ("limitations", "errors"):
        if not isinstance(manifest[field], list) or not all(isinstance(item, str) and item.strip() for item in manifest[field]):
            raise ManifestError(f"{field} must be a string array")
    if manifest["completeness"] not in {"complete", "partial", "failed"}:
        raise ManifestError("completeness is invalid")
    isolation = _keys(manifest["isolation_profile"], {"name", "static_only", "network_access", "target_execution"}, "isolation_profile")
    _text(isolation["name"], "isolation_profile.name")
    if any(not isinstance(isolation[field], bool) for field in ("static_only", "network_access", "target_execution")) or isolation["target_execution"]:
        raise ManifestError("isolation profile must record target_execution=false")
    if manifest["identity"] != _identity(manifest):
        raise ManifestError("manifest identity does not match canonical stable content")


def verify_artifacts(manifest: dict[str, Any], root: Path) -> None:
    """Rehash every recorded file without launching the target or tool."""
    validate_manifest(manifest)
    root = root.resolve()
    records = [(item, False) for item in [manifest["input"], manifest["stdout"], manifest["stderr"], *manifest["outputs"]]]
    records += [(item, True) for item in manifest["tool"]["artifacts"]]
    line_counts: dict[str, int] = {}
    for index, (recorded, analysis_tool) in enumerate(records):
        current, lines = _artifact_identity(root, recorded["path"], f"recorded artifact[{index}]", analysis_tool)
        if current != {key: recorded[key] for key in ("path", "size", "sha256")}:
            raise ManifestError(f"recorded artifact[{index}] identity changed")
        line_counts[recorded["path"]] = lines
    current_tool = _resolve_tool(
        manifest["argv"][0], manifest["tool"]["launcher"]["resolved_executable"], root, manifest["environment"]
    )
    if current_tool != manifest["tool"]["launcher"]:
        raise ManifestError("file-backed tool identity changed")
    for finding in manifest["findings"]:
        for location in finding["evidence_locations"]:
            path, _, end = _evidence_location(location)
            if end > line_counts[path]:
                raise ManifestError("finding evidence location exceeds file line count")


def _evidence_location(value: Any) -> tuple[str, int, int]:
    match = LOCATION_RE.fullmatch(value) if isinstance(value, str) else None
    if not match:
        raise ManifestError("finding evidence location is invalid")
    path = _relative(match.group("path"), "evidence location")
    start = int(match.group("start"))
    return path, start, int(match.group("end") or start)


def _load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ManifestError("JSON root must be an object")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create"); create.add_argument("--root", type=Path, required=True); create.add_argument("--spec", type=Path, required=True); create.add_argument("--output", type=Path, required=True); create.add_argument("--overwrite", action="store_true")
    validate = commands.add_parser("validate"); validate.add_argument("manifest", type=Path)
    verify = commands.add_parser("verify"); verify.add_argument("--root", type=Path, required=True); verify.add_argument("manifest", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "create":
            manifest = build_manifest(_load(args.spec), args.root)
            _atomic_write(args.output, canonical_bytes(manifest), args.overwrite)
        elif args.command == "validate":
            validate_manifest(_load(args.manifest))
        else:
            verify_artifacts(_load(args.manifest), args.root)
    except (ManifestError, OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"analysis-manifest: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
