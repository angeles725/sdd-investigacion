#!/usr/bin/env python3
"""kit-rdd-drive.py [--max-steps N] <cwd> <first-json-file>

Kit-maintenance tool (kit issue #2212): follow gentle-ai `next_transition` / `status_continuation` from the
document kit-rdd-start.py wrote until the review is acknowledged or something needs a human.

Runs ONLY provider-issued operations with their ordered argument tokens (`gentle-ai review <op> <tokens...>`);
nothing is reconstructed from prose. `collect` inputs that are reviewer captures (review.capture-result) are
launched concurrently, in provider order, and the first capture that carries a continuation decides the next
step; otherwise the last bound STATUS command is asked again. Any other collect (a correction plan) is NOT
driven: there is no automatic recovery, the run stops and prints the reason.

Typed exit states (the matching `kit-rdd-drive: ...` / `rdd-stop: <reason>` line is printed):
  0   acknowledged       the review was acknowledged, or the target had already been (target_already_acknowledged)
  2   usage              bad arguments
  3   degraded           gentle-ai missing: `degraded: missing runtime dependency: gentle-ai`
  13  rdd-not-approved   a stop that is not an acknowledgement: `rdd-stop: <reason_code>` (correction_required,
                         lens_context_budget_exceeded, corrected_candidate_unavailable, ...), a non-capture collect,
                         non-JSON output, no transition, an unknown transition, or the step limit
  15  consent-required   the document is a consent envelope; it is printed and nothing is run (use
                         kit-rdd-start.py --consent granted)
"""
import argparse
import concurrent.futures as cf
import json
import shutil
import subprocess
import sys


def log(*a):
    print(*a, flush=True)


def stop(reason, detail=""):
    log("rdd-stop: %s" % reason)
    if detail:
        log(detail)
    sys.exit(0 if reason == "target_already_acknowledged" else 13)


def op_cmd(op, args):
    return ["gentle-ai", "review", op.split(".", 1)[1]] + [a["token"] for a in args]


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    out = p.stdout.strip()
    try:
        return json.loads(out), p.returncode
    except ValueError:
        i = out.rfind("\n{")  # the last JSON object in the output
        try:
            return json.loads(out[i + 1:] if i >= 0 else out), p.returncode
        except ValueError:
            log("NON-JSON rc=%d stdout=%s stderr=%s" % (p.returncode, out[-800:], p.stderr[-800:]))
            return None, p.returncode


def main(argv):
    ap = argparse.ArgumentParser(prog="kit-rdd-drive.py")
    ap.add_argument("--max-steps", type=int, default=40)
    ap.add_argument("cwd")
    ap.add_argument("first")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        sys.exit(2 if e.code else 0)
    if shutil.which("gentle-ai") is None:
        log("kit-rdd-drive: degraded: missing runtime dependency: gentle-ai")
        sys.exit(3)
    cwd = args.cwd
    try:
        with open(args.first) as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as e:
        stop("first-document-unreadable", str(e))
    last_status = None
    for step in range(args.max_steps):
        if doc is None:
            stop("non-json")
        schema = str(doc.get("schema", ""))
        if schema.startswith("gentle-ai.review-acknowledged"):
            log("ACKNOWLEDGED", json.dumps({k: doc.get(k) for k in ("schema", "lineage_id", "target_identity", "outcome", "action")}))
            sys.exit(0)
        if schema.startswith("gentle-ai.review-integration.consent"):
            log("kit-rdd-drive: consent-required: the document is a consent envelope; nothing was run")
            log(json.dumps(doc, indent=2, sort_keys=True))
            sys.exit(15)
        if doc.get("forecast"):
            log("FORECAST", json.dumps(doc["forecast"])[:600])
        nt = doc.get("status_continuation") or doc.get("next_transition")
        if not nt:
            stop("no-transition", json.dumps(doc)[:1500])
        kind = nt.get("kind") or ("execute" if nt.get("operation") else None)
        if kind == "stop":
            stop(str(nt.get("reason_code")), json.dumps(nt)[:800])
        if kind == "execute":
            ex = nt.get("execute", nt)
            cmd = op_cmd(ex["operation"], ex["arguments"])
            if ex["operation"] == "review.status":
                last_status = cmd
            log("RUN", " ".join(cmd)[:300])
            doc, _rc = run(cmd, cwd)
            continue
        if kind == "collect":
            inputs = nt["collect"]["inputs"]
            if any(i.get("capture_operation") != "review.capture-result" for i in inputs):
                stop("correction_required", json.dumps(nt.get("correction_request", nt))[:3000])
            cmds = [op_cmd(i["capture_operation"], i["arguments"]) for i in inputs]
            lenses = [(i.get("artifact_subject") or {}).get("lens") or i.get("name") for i in inputs]
            log("COLLECT %d inputs: %s" % (len(cmds), lenses))
            for c in cmds:  # launched in provider order, logged before any result can race it
                log("LAUNCH", " ".join(c)[:300])
            with cf.ThreadPoolExecutor(max_workers=len(cmds)) as pool:
                res = list(pool.map(lambda c: run(c, cwd), cmds))
            terminal = None
            for d, rc in res:
                log("CAPTURE rc=%d %s" % (rc, json.dumps(d)[:400] if d else "None"))
                if d and (d.get("status_continuation") or (d.get("next_transition") or {}).get("kind") in ("execute", "stop")):
                    terminal = d
            if terminal is not None:
                doc = terminal
                continue
            if last_status is None:
                stop("no-bound-status")
            log("RUN", " ".join(last_status)[:300])
            doc, _rc = run(last_status, cwd)
            continue
        stop("unknown-transition", json.dumps(nt)[:1500])
    stop("step-limit")


if __name__ == "__main__":
    main(sys.argv[1:])
