#!/usr/bin/env python3
"""EMBA heavy-firmware-analysis Docker PLAN (dry-run) adapter (U-D17 / item 17).
Produces emba-plan.v1 + vm-determinism.v1. NEVER runs docker.
Live exec gated behind --allow-docker. See gate-authorization.v1.md + emba-plan.v1.md.
"""
from __future__ import annotations
import argparse, os, re, sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent; _LIB = _HERE / "lib"
for _p in (str(_LIB), str(_HERE)):
    if _p not in sys.path: sys.path.insert(0, _p)

from adapter_core import AdapterError, identity as _file_identity, write as _write  # noqa: E402
from adapter_helpers import assert_safe_bind_root, BindScopeError              # noqa: E402
from gate import CAP_DOCKER                                                     # noqa: E402
from vm_plan import build_determinism, VmDeterminismError                      # noqa: E402
from plan_common import (                                                        # noqa: E402
    PlanOnlyExecutor, select_executor, make_dry_run_det_spec,
    run_gate_epilogue, reject_mount_delimiters, validate_token,
    add_max_input_bytes_arg,
)

SCHEMA_VERSION = "emba-plan.v1"
# [A-Za-z0-9._:/@-]: registry/tag/digest chars. Rejects leading dash + shell metacharacters.
_TAG_RE     = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:/@-]*$')
_PROFILE_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
_DEFAULT_IMAGE  = "embeddedanalyzer/emba:latest"
_DEFAULT_CPUS   = "2"; _DEFAULT_MEMORY = "4g"; _DEFAULT_PIDS = 256; _DEFAULT_WALL = 3600


class EmbaPlanError(AdapterError): ...


def _validate_tag(tag: str) -> str:
    return validate_token(tag, "image tag", _TAG_RE, EmbaPlanError)


def _validate_profile(profile: str | None) -> str | None:
    if profile is None: return None
    return validate_token(profile, "profile", _PROFILE_RE, EmbaPlanError)


def build_plan(
    firmware: Path, image_tag: str, profile: str | None,
    cpus: str, memory: str, pids_limit: int, wall_seconds: int,
    *, input_sha: str, input_size: int,
) -> dict[str, Any]:
    """Build emba-plan.v1 (pure planning — no subprocess, no docker)."""
    fw_abs = str(firmware.resolve())
    # -v src:dst:opts is colon-delimited and --mount is comma-delimited, so a source
    # path containing either delimiter cannot be safely expressed; rejecting such paths
    # preserves the read-only least-privilege guarantee.
    reject_mount_delimiters(fw_abs, "firmware path", EmbaPlanError)
    # Discrete list[str] — never a shell string.
    # --privileged EXPLICITLY ABSENT; EMBA privilege requirement is data only.
    argv: list[str] = [
        "docker", "run", "--rm",
        "--network", "none",
        "--cpus", cpus, "--memory", memory, "--pids-limit", str(pids_limit),
        "-v", f"{fw_abs}:/firmware:ro",
        "-v", "/tmp/rsdd:/tmp/rsdd",
    ]
    if profile is not None: argv += ["-e", f"EMBA_PROFILE={profile}"]
    argv += [image_tag, "-f", "/firmware", "-o", "/tmp/rsdd"]
    return {
        "schema_version": SCHEMA_VERSION,
        "firmware": {"path": fw_abs, "sha256": input_sha, "size": input_size},
        "image": {"tag": image_tag, "digest": None},
        "resource_limits": {"cpus": cpus, "memory": memory,
                            "pids_limit": pids_limit, "wall_seconds": wall_seconds},
        "network": "none",
        "mount_plan": {"firmware_ro": "/firmware", "output_writable": "/tmp/rsdd"},
        "profile": profile,
        "planned_argv": argv,
        # --privileged REFUSED. EMBA often needs elevated access; recorded as data.
        # Live executor MUST use specific caps (CAP_SYS_PTRACE etc.), not --privileged.
        "privilege_requirement": {
            "requires_privileged": True, "recorded_as": "limitation",
            "justification": ("EMBA requires elevated privileges for certain analysis modules. "
                              "--privileged is REFUSED. Live executor MUST use specific caps only."),
            "specific_caps_required": [], "status": "refused-in-plan",
        },
        "outputs": [],
        "limitations": [
            "outputs-unknown-until-live-run",
            "emba-requires-elevated-privileges: --privileged refused; live executor must use specific caps only",
            "image-digest-not-pinned-in-dry-run: live executor must pin digest before run",
        ],
    }


def plan_emba(args: Any) -> int:
    """Build plan + determinism record, route through gate. Returns exit code."""
    output_dir = Path(args.output)
    try: assert_safe_bind_root(Path(os.path.realpath(output_dir)))
    except BindScopeError as exc: print(f"emba-plan: unsafe output path: {exc}", file=sys.stderr); return 2
    try: image_tag = _validate_tag(args.image_tag)
    except EmbaPlanError as exc: print(f"emba-plan: {exc}", file=sys.stderr); return 2
    try: profile = _validate_profile(args.profile)
    except EmbaPlanError as exc: print(f"emba-plan: {exc}", file=sys.stderr); return 2
    firmware = Path(args.firmware)
    try: _, input_size, input_sha = _file_identity(firmware, max_bytes=args.max_input_bytes)
    except AdapterError as exc: print(f"emba-plan: {exc}", file=sys.stderr); return 2

    try:
        plan = build_plan(firmware, image_tag, profile,
                          args.cpus, args.memory, args.pids_limit, args.wall_seconds,
                          input_sha=input_sha, input_size=input_size)
    except EmbaPlanError as exc:
        print(f"emba-plan: {exc}", file=sys.stderr); return 2
    try: determinism = build_determinism(make_dry_run_det_spec())
    except VmDeterminismError as exc:
        print(f"emba-plan: determinism error: {exc}", file=sys.stderr); return 2

    executor = select_executor(args.allow_docker, SCHEMA_VERSION)
    output_dir.mkdir(parents=True, exist_ok=True)
    _write(output_dir / "emba-plan.v1.json", plan)
    _write(output_dir / "vm-determinism.v1.json", determinism)
    return run_gate_epilogue(CAP_DOCKER, args.allow_docker, plan, executor, "emba-plan")


def _parser(argv: list[str] | None = None) -> Any:
    ap = argparse.ArgumentParser(prog="emba_plan.py", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="Build emba-plan.v1 (dry-run only)")
    p.add_argument("--firmware",     required=True, metavar="FILE")
    p.add_argument("--image-tag",    default=_DEFAULT_IMAGE, dest="image_tag", metavar="TAG")
    p.add_argument("--profile",      default=None, metavar="NAME")
    p.add_argument("--cpus",         default=_DEFAULT_CPUS)
    p.add_argument("--memory",       default=_DEFAULT_MEMORY)
    p.add_argument("--pids-limit",   type=int, default=_DEFAULT_PIDS, dest="pids_limit")
    p.add_argument("--wall-seconds", type=int, default=_DEFAULT_WALL, dest="wall_seconds")
    p.add_argument("--output",       required=True, metavar="DIR")
    p.add_argument("--allow-docker", action="store_true", default=False, dest="allow_docker",
                   help="authorize live docker run (no live executor → exit 2)")
    add_max_input_bytes_arg(p)
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parser(argv)
    return plan_emba(args) if args.cmd == "plan" else 2


if __name__ == "__main__":
    sys.exit(main())
