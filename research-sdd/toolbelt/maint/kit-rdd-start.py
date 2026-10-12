#!/usr/bin/env python3
"""kit-rdd-start.py [--consent granted] [--base-ref REF] [--agent NAME] <cwd> <outfile>

Kit-maintenance tool (kit issue #2212): assess the committed range <REF>..HEAD of <cwd>; when a native review
is due, run the provider-issued STATUS, then the provider-issued START, and write the START output (the
document kit-rdd-drive.py follows) to <outfile>.

Consent is explicit (maintainer decision, issue #2212). The provider answers START with a consent envelope
(gentle-ai.review-integration.consent/*). WITHOUT `--consent granted` this tool prints that envelope
losslessly and exits 15 (consent-required): no granted and no declined invocation is run. WITH it, the tool
runs exactly the provider-issued `granted` choice invocation, verbatim, and only when its argv[0] is
`gentle-ai`; the flag records the maintainer's standing grant and is never inferred. Every command run is a
provider-issued token list or invocation: this tool never composes a gentle-ai command of its own beyond the
documented `review assess` call.

Typed exit states (stdout/stderr carry the matching `kit-rdd-start: <state>` line):
  0   started            review started; <outfile> written (a START that needs no consent also lands here)
  2   usage              bad arguments
  3   degraded           gentle-ai (or python3) missing: `degraded: missing runtime dependency: ...`
  10  rdd-not-due        assess says no review is due; nothing written
  14  rdd-start-error    non-JSON answer, STATUS that is not a review.start execute, no unique granted
                         choice, or an invocation that is not a gentle-ai command
  15  consent-required   consent envelope printed; re-run with `--consent granted` to record the grant
"""
import argparse
import json
import shlex
import shutil
import subprocess
import sys


def say(state, msg=""):
    print("kit-rdd-start: %s%s" % (state, (": " + msg) if msg else ""), flush=True)


def fail(code, state, msg):
    say(state, msg)
    sys.exit(code)


def run_json(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    try:
        return json.loads(p.stdout)
    except ValueError:
        fail(14, "rdd-start-error", "non-JSON answer from %s rc=%d stdout=%s stderr=%s"
             % (" ".join(cmd[:4]), p.returncode, p.stdout[-300:], p.stderr[-300:]))


def main(argv):
    ap = argparse.ArgumentParser(prog="kit-rdd-start.py", add_help=True)
    ap.add_argument("--consent", choices=["granted"], default=None)
    ap.add_argument("--base-ref", default="origin/main")
    ap.add_argument("--agent", default="claude-code")
    ap.add_argument("cwd")
    ap.add_argument("outfile")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        sys.exit(2 if e.code else 0)
    if shutil.which("gentle-ai") is None:
        fail(3, "degraded", "degraded: missing runtime dependency: gentle-ai")
    cwd = args.cwd
    assess = run_json(["gentle-ai", "review", "assess", "--cwd", cwd, "--agent", args.agent,
                       "--base-ref", args.base_ref, "--committed-only", "--json"], cwd)
    say("assess", "risk=%s review_due=%s reason=%s" % (assess.get("risk"), assess.get("review_due"),
                                                      assess.get("review_due_reason")))
    if not assess.get("review_due"):
        fail(10, "rdd-not-due", str(assess.get("review_due_reason")))
    try:
        status_cmd = shlex.split(assess["next_transition"]["command"])
    except (KeyError, TypeError, ValueError):
        fail(14, "rdd-start-error", "assess answer has no next_transition.command")
    status = run_json(status_cmd, cwd)
    nt = status.get("next_transition") or {}
    ex = nt.get("execute") or {}
    if nt.get("kind") != "execute" or ex.get("operation") != "review.start":
        fail(14, "rdd-start-error", "STATUS is not a review.start execute: " + json.dumps(nt)[:600])
    env = run_json(["gentle-ai", "review", "start"] + [a["token"] for a in ex.get("arguments", [])], cwd)
    if not str(env.get("schema", "")).startswith("gentle-ai.review-integration.consent"):
        with open(args.outfile, "w") as fh:
            json.dump(env, fh)
        say("started", "no consent envelope")
        sys.exit(0)
    if args.consent != "granted":
        print(json.dumps(env, indent=2, sort_keys=True))
        fail(15, "consent-required", "re-run with --consent granted to record the maintainer's standing grant")
    granted = [c for c in env.get("choices", []) if c.get("answer") == "granted"]
    if len(granted) != 1:
        fail(14, "rdd-start-error", "no unique granted choice (%d)" % len(granted))
    try:
        inv = shlex.split(granted[0]["invocation"])
    except (KeyError, ValueError):
        fail(14, "rdd-start-error", "granted choice has no usable invocation")
    if not inv or inv[0] != "gentle-ai":
        fail(14, "rdd-start-error", "granted invocation is not a gentle-ai command; refused")
    res = run_json(inv, cwd)
    with open(args.outfile, "w") as fh:
        json.dump(res, fh)
    say("started", "granted START action=%s" % res.get("action"))
    sys.exit(0)


if __name__ == "__main__":
    main(sys.argv[1:])
