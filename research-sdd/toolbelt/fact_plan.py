#!/usr/bin/env python3
"""FACT Core firmware-analysis Docker-Compose PLAN (dry-run) adapter (U-D18 / item 18).
Produces fact-plan.v1 + vm-determinism.v1. NEVER runs docker-compose or docker.
Live exec gated behind --allow-docker. See gate-authorization.v1.md + fact-plan.v1.md.
"""
from __future__ import annotations
import argparse, json, os, re, sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent; _LIB = _HERE / "lib"
for _p in (str(_LIB), str(_HERE)):
    if _p not in sys.path: sys.path.insert(0, _p)

from adapter_core import AdapterError, identity as _file_identity, write as _write  # noqa: E402
from adapter_helpers import assert_safe_bind_root, BindScopeError              # noqa: E402
from gate import execute_or_plan, CAP_DOCKER, EXIT_AUTH_REQUIRED, GateError   # noqa: E402
from vm_plan import build_determinism, VmDeterminismError                      # noqa: E402

SCHEMA_VERSION = "fact-plan.v1"
_TAG_RE  = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:/@-]*$')
_NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
_DEFAULT_FRONTEND = "fkiecad/fact_frontend:latest"; _DEFAULT_BACKEND = "fkiecad/fact_core:latest"
_DEFAULT_DB = "fkiecad/fact_db:latest"; _DEFAULT_PROJECT = "fact"
_DEFAULT_CPUS = "2"; _DEFAULT_MEMORY = "4g"; _DEFAULT_PIDS = 256; _DEFAULT_WALL = 7200


class FactPlanError(AdapterError): ...


class PlanOnlyExecutor:
    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:
        return {"schema_version": SCHEMA_VERSION, "executed": False,
                "outputs": [], "limitations": ["outputs-unknown-until-live-run"]}


def select_executor(allow_live: bool) -> PlanOnlyExecutor | None:
    return None if allow_live else PlanOnlyExecutor()


def _validate(v: str, label: str, pat: re.Pattern[str]) -> str:
    """Generic charset + leading-dash validator; raises FactPlanError on violation."""
    if not v: raise FactPlanError(f"{label} must not be empty")
    if v.startswith("-"): raise FactPlanError(f"{label} must not start with '-': {v!r}")
    if not pat.fullmatch(v): raise FactPlanError(f"{label} has unsafe chars: {v!r}")
    return v


def build_plan(
    firmware: Path, compose_file: Path | None, project_name: str,
    frontend_tag: str, backend_tag: str, db_tag: str, plugins: list[str],
    cpus: str, memory: str, pids_limit: int, wall_seconds: int,
    *, input_sha: str, input_size: int,
) -> dict[str, Any]:
    """Build fact-plan.v1 (pure planning — no subprocess, no docker, no network)."""
    fw_abs = str(firmware.resolve())
    # -v src:dst:opts is colon-delimited and --mount is comma-delimited, so a source
    # path containing either cannot be safely expressed; rejecting such paths
    # preserves the read-only least-privilege guarantee (lesson from U-D17).
    if ":" in fw_abs or "," in fw_abs:
        raise FactPlanError(
            f"firmware path contains a character unsafe for a Docker bind-mount spec"
            f" (':' or ','): {fw_abs}")
    cf_abs: str | None = None
    if compose_file is not None:
        cf_abs = str(compose_file.resolve())
        if ":" in cf_abs or "," in cf_abs:
            raise FactPlanError(
                f"compose-file path contains a character unsafe for a Docker bind-mount spec"
                f" (':' or ','): {cf_abs}")
    # docker compose argv — discrete list[str], never a shell string.
    # NO --network host: FACT services communicate via internal bridge only.
    # NO --privileged: recorded as data (see privilege_requirement below).
    argv: list[str] = ["docker", "compose", "-p", project_name]
    if cf_abs is not None: argv += ["-f", cf_abs]
    argv += ["up", "-d"]
    return {
        "schema_version": SCHEMA_VERSION,
        "firmware": {"path": fw_abs, "sha256": input_sha, "size": input_size},
        "deployment": {"planned_argv": argv, "project_name": project_name, "compose_file": cf_abs,
                       "image_tags": {"frontend": frontend_tag, "backend": backend_tag, "db": db_tag}},
        "network": "internal-bridge",  # NEVER --network host; services use internal bridge only
        "submission": {"mode": "rest-api", "firmware_sha256": input_sha,
                       "planned_endpoint": "/rest/firmware", "planned_method": "PUT",
                       "plugins": plugins, "note": "plan-only: no HTTP request made in dry-run"},
        "resource_limits": {"cpus": cpus, "memory": memory, "pids_limit": pids_limit, "wall_seconds": wall_seconds},
        "mount_plan": {"firmware_ro": "/tmp/rsdd/firmware-input", "output_writable": "/tmp/rsdd"},
        "persistent_storage": {"db_volume": f"{project_name}_db", "scope": "compose-project-scoped",
                                "note": "DB volume must be compose-project-scoped; never a raw host mount."},
        # --privileged REFUSED. FACT plugin access recorded as data only.
        "privilege_requirement": {"requires_privileged": False, "recorded_as": "note",
                                   "status": "refused-in-plan",
                                   "justification": "--privileged REFUSED; specific caps only if needed."},
        "outputs": [],
        "limitations": ["outputs-unknown-until-live-run",
                        "image-digest-not-pinned-in-dry-run: live executor must pin digests before run",
                        "fact-rest-submission-plan-only: firmware upload not executed in dry-run",
                        "fact-db-volume-must-be-project-scoped: live executor must verify volume scope",
                        "fact-network-internal-bridge-no-egress: NEVER --network host"],
    }


def plan_fact(args: Any) -> int:
    """Build plan + determinism record, route through gate. Returns exit code."""
    output_dir = Path(args.output)
    try: assert_safe_bind_root(Path(os.path.realpath(output_dir)))
    except BindScopeError as exc: print(f"fact-plan: unsafe output path: {exc}", file=sys.stderr); return 2
    try:
        project_name = _validate(args.project_name, "project name", _NAME_RE)
        frontend_tag = _validate(args.frontend_tag, "frontend image tag", _TAG_RE)
        backend_tag  = _validate(args.backend_tag,  "backend image tag",  _TAG_RE)
        db_tag       = _validate(args.db_tag,       "db image tag",       _TAG_RE)
    except FactPlanError as exc: print(f"fact-plan: {exc}", file=sys.stderr); return 2
    plugins: list[str] = []
    for plug in (args.plugin or []):
        try: plugins.append(_validate(plug, f"plugin {plug!r}", _NAME_RE))
        except FactPlanError as exc: print(f"fact-plan: {exc}", file=sys.stderr); return 2
    compose_file = Path(args.compose_file) if args.compose_file else None
    firmware = Path(args.firmware)
    try: _, input_size, input_sha = _file_identity(firmware)
    except AdapterError as exc: print(f"fact-plan: {exc}", file=sys.stderr); return 2
    try:
        plan = build_plan(firmware, compose_file, project_name,
                          frontend_tag, backend_tag, db_tag, plugins,
                          args.cpus, args.memory, args.pids_limit, args.wall_seconds,
                          input_sha=input_sha, input_size=input_size)
    except FactPlanError as exc: print(f"fact-plan: {exc}", file=sys.stderr); return 2
    det_spec: dict[str, Any] = {
        "schema_version": "vm-determinism.v1", "receipt_identity": None, "seed": 0,
        "clock": {"mode": "pinned", "epoch": "1970-01-01T00:00:00Z"},
        "limits_conformance": {"cpu_within": False, "mem_within": False,
                               "wall_within": False, "output_within": False},
        "reproducible": {"basis": "dry-run-plan", "replicate_identity": None},
    }
    try: determinism = build_determinism(det_spec)
    except VmDeterminismError as exc:
        print(f"fact-plan: determinism error: {exc}", file=sys.stderr); return 2
    executor = select_executor(args.allow_docker)
    output_dir.mkdir(parents=True, exist_ok=True)
    _write(output_dir / "fact-plan.v1.json", plan)
    _write(output_dir / "vm-determinism.v1.json", determinism)
    try:
        result = execute_or_plan(
            CAP_DOCKER, args.allow_docker, plan,
            live_executor=executor.evaluate if executor is not None else None,
            would_be_receipt_spec=None, output_dir=None)
    except GateError as exc: print(f"fact-plan: {exc}", file=sys.stderr); return 2
    if result.get("outcome") == "authorization-required": return EXIT_AUTH_REQUIRED  # 3
    print(json.dumps(result, indent=2, sort_keys=True)); return 0


def _parser(argv: list[str] | None = None) -> Any:
    ap = argparse.ArgumentParser(prog="fact_plan.py", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="Build fact-plan.v1 (dry-run only)")
    p.add_argument("--firmware",     required=True, metavar="FILE")
    p.add_argument("--compose-file", default=None, dest="compose_file", metavar="FILE")
    p.add_argument("--project-name", default=_DEFAULT_PROJECT,  dest="project_name", metavar="NAME")
    p.add_argument("--frontend-tag", default=_DEFAULT_FRONTEND, dest="frontend_tag", metavar="TAG")
    p.add_argument("--backend-tag",  default=_DEFAULT_BACKEND,  dest="backend_tag",  metavar="TAG")
    p.add_argument("--db-tag",       default=_DEFAULT_DB,       dest="db_tag",       metavar="TAG")
    p.add_argument("--plugin",       action="append", default=None, metavar="NAME")
    p.add_argument("--cpus",         default=_DEFAULT_CPUS); p.add_argument("--memory", default=_DEFAULT_MEMORY)
    p.add_argument("--pids-limit",   type=int, default=_DEFAULT_PIDS, dest="pids_limit")
    p.add_argument("--wall-seconds", type=int, default=_DEFAULT_WALL, dest="wall_seconds")
    p.add_argument("--output",       required=True, metavar="DIR")
    p.add_argument("--allow-docker", action="store_true", default=False, dest="allow_docker",
                   help="authorize live docker-compose run (no live executor → exit 2)")
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parser(argv)
    return plan_fact(args) if args.cmd == "plan" else 2


if __name__ == "__main__":
    sys.exit(main())
