#!/usr/bin/env python3
"""kit-rdd-drive.py [--max-steps N] <cwd> <first-json-file>

Kit-maintenance tool (kit issue #2212): follow gentle-ai `next_transition` / `status_continuation` from the
document kit-rdd-start.py wrote until the review is acknowledged or something needs a human.

Runs ONLY provider-issued operations with their ordered argument tokens (`gentle-ai review <op> <tokens...>`);
nothing is reconstructed from prose. Allowlist: an operation must be named `review.<name>`; anything else is a
protocol error and is never turned into a command. `collect` inputs that are reviewer captures
(review.capture-result) are launched concurrently, in provider order; if one or more captures carry a
continuation, the LAST one in provider order decides the next step, otherwise the last bound STATUS command is
asked again. Any other collect (for example a correction plan) is NOT driven: there is no automatic recovery,
the run stops with `rdd-stop: non-capture-collect (<capture_operation>)`. A reason code is printed only when
the provider supplied it; this tool never invents one.

Typed exit states (the matching `kit-rdd-drive: ...` / `rdd-stop: <reason>` line is printed):
  0   acknowledged        the review was acknowledged, or the target had already been (target_already_acknowledged)
  2   usage               bad arguments
  3   degraded            gentle-ai missing: `degraded: missing runtime dependency: gentle-ai`
  13  rdd-not-approved    a stop that is not an acknowledgement: `rdd-stop: <reason_code>` (the provider's own:
                          correction_required, lens_context_budget_exceeded, ...), `non-capture-collect (<op>)`,
                          non-json, no-transition, unknown-transition, no-bound-status or step-limit
  14  rdd-protocol-error  malformed provider output (non-object JSON, missing or mistyped keys, an operation
                          without a `review.` prefix, an empty capture list): printed as
                          `kit-rdd-drive: rdd-protocol-error: <detail>`; never a raw traceback
  15  consent-required    the document is a consent envelope; it is printed and nothing is run (use
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


def protocol_error(detail):
    log("kit-rdd-drive: rdd-protocol-error: %s" % detail)
    sys.exit(14)


def op_cmd(op, args):
    """The command for a provider-issued operation: `gentle-ai review <name> <tokens...>`; anything else is refused."""
    if not isinstance(op, str) or not op.startswith("review.") or len(op) == len("review."):
        protocol_error("operation is not review.<name>: %r" % (op,))
    if not isinstance(args, list):
        protocol_error("operation %s has no arguments list" % op)
    toks = []
    for a in args:
        if not isinstance(a, dict) or not isinstance(a.get("token"), str):
            protocol_error("operation %s has an argument without a string token: %s" % (op, json.dumps(a)[:200]))
        toks.append(a["token"])
    return ["gentle-ai", "review", op.split(".", 1)[1]] + toks


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


def drive(args):
    cwd = args.cwd
    try:
        with open(args.first) as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as e:
        protocol_error("first document unreadable: %s" % e)
    last_status = None
    for step in range(args.max_steps):
        if doc is None:
            stop("non-json")
        if not isinstance(doc, dict):
            protocol_error("document is not a JSON object: %s" % json.dumps(doc)[:200])
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
        if not isinstance(nt, dict):
            protocol_error("transition is not an object: %s" % json.dumps(nt)[:200])
        kind = nt.get("kind")
        if kind == "stop":
            if not nt.get("reason_code"):
                stop("stop-without-reason", json.dumps(nt)[:800])
            stop(str(nt["reason_code"]), json.dumps(nt)[:800])
        if kind == "execute":
            ex = nt.get("execute")
            if not isinstance(ex, dict):
                protocol_error("execute transition without an execute object")
            cmd = op_cmd(ex.get("operation"), ex.get("arguments"))
            if ex["operation"] == "review.status":
                last_status = cmd
            log("RUN", " ".join(cmd)[:300])
            doc, _rc = run(cmd, cwd)
            continue
        if kind == "collect":
            coll = nt.get("collect")
            inputs = coll.get("inputs") if isinstance(coll, dict) else None
            if not isinstance(inputs, list) or not inputs:
                protocol_error("collect transition without a non-empty inputs list")
            if not all(isinstance(i, dict) for i in inputs):
                protocol_error("collect inputs are not objects")
            odd = [str(i.get("capture_operation")) for i in inputs if i.get("capture_operation") != "review.capture-result"]
            if odd:
                stop("non-capture-collect (%s)" % ", ".join(odd), json.dumps(nt.get("correction_request", nt))[:3000])
            cmds = [op_cmd(i["capture_operation"], i.get("arguments")) for i in inputs]
            lenses = [(i.get("artifact_subject") or {}).get("lens") or i.get("name") for i in inputs]
            log("COLLECT %d inputs: %s" % (len(cmds), lenses))
            for c in cmds:  # launched in provider order, logged before any result can race it
                log("LAUNCH", " ".join(c)[:300])
            with cf.ThreadPoolExecutor(max_workers=len(cmds)) as pool:
                res = list(pool.map(lambda c: run(c, cwd), cmds))
            terminal = None
            for d, rc in res:
                log("CAPTURE rc=%d %s" % (rc, json.dumps(d)[:400] if d else "None"))
                if isinstance(d, dict) and (d.get("status_continuation") or (d.get("next_transition") or {}).get("kind") in ("execute", "stop")):
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
    try:
        drive(args)
    except (KeyError, TypeError, AttributeError, IndexError, ValueError) as e:
        protocol_error("malformed provider output: %s: %s" % (type(e).__name__, e))


if __name__ == "__main__":
    main(sys.argv[1:])
