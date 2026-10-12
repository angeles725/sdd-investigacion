#!/usr/bin/env python3
"""kit-rdd-start.py [--consent granted] [--base-ref REF] [--agent NAME] <cwd> <outfile>

Kit-maintenance tool (kit issue #2212): assess the committed range <REF>..HEAD of <cwd>; when a native review
is due, run the provider-issued STATUS, then the provider-issued START, and write the START output (the
document kit-rdd-drive.py follows) to <outfile>.

Consent is explicit (maintainer decision, issue #2212). The provider answers START with a consent envelope
(gentle-ai.review-integration.consent/*). WITHOUT `--consent granted` this tool prints that envelope
losslessly and exits 15 (consent-required): no granted and no declined invocation is run. WITH it, the tool
runs exactly the provider-issued `granted` choice invocation, verbatim; the flag records the maintainer's
standing grant and is never inferred.

Strict command allowlist: the only commands this tool runs are `gentle-ai review assess` (its own, documented),
the provider's STATUS command (argv[:3] == gentle-ai review status), `gentle-ai review start` with the
provider's argument tokens, and the provider's granted invocation (argv[:3] == gentle-ai review start). Anything
else the provider hands back is refused (exit 14), never run.

A review is "not due" ONLY when `gentle-ai review assess` exits 0 AND its JSON object says `review_due` is the
boolean false. A failed assessment, a missing key or a non-boolean never lowers the tier: exit 14.

Typed exit states (stdout/stderr carry the matching `kit-rdd-start: <state>` line):
  0   started            review started (the START answer carries a continuation); <outfile> written
  2   usage              bad arguments
  3   degraded           gentle-ai missing: `degraded: missing runtime dependency: gentle-ai`
  10  rdd-not-due        assess exited 0 and says review_due is false; nothing written
  14  rdd-start-error    assess failed or is not due-decidable, malformed provider output (non-JSON, non-object,
                         missing keys), a command outside the allowlist, STATUS that is not a review.start
                         execute, no unique granted choice, or a START that did not start a review
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
    """Run cmd; return (JSON object, rc). Non-JSON or a non-object answer is an rdd-start-error."""
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    try:
        doc = json.loads(p.stdout)
    except ValueError:
        fail(14, "rdd-start-error", "non-JSON answer from %s rc=%d stdout=%s stderr=%s"
             % (" ".join(cmd[:4]), p.returncode, p.stdout[-300:], p.stderr[-300:]))
    if not isinstance(doc, dict):
        fail(14, "rdd-start-error", "answer from %s is not a JSON object" % " ".join(cmd[:4]))
    return doc, p.returncode


def tokens(arguments):
    """The ordered token strings of a provider argument list; anything else is malformed."""
    if not isinstance(arguments, list) or not arguments:
        fail(14, "rdd-start-error", "provider arguments are missing or empty")
    out = []
    for a in arguments:
        if not isinstance(a, dict) or not isinstance(a.get("token"), str):
            fail(14, "rdd-start-error", "provider argument without a string token: %s" % json.dumps(a)[:200])
        out.append(a["token"])
    return out


def run(args):
    cwd = args.cwd
    assess, assess_rc = run_json(["gentle-ai", "review", "assess", "--cwd", cwd, "--agent", args.agent,
                                  "--base-ref", args.base_ref, "--committed-only", "--json"], cwd)
    say("assess", "rc=%d risk=%s review_due=%s reason=%s" % (assess_rc, assess.get("risk"), assess.get("review_due"),
                                                           assess.get("review_due_reason")))
    if assess_rc == 0 and assess.get("review_due") is False:
        fail(10, "rdd-not-due", str(assess.get("review_due_reason")))
    if assess_rc != 0 or assess.get("review_due") is not True:
        fail(14, "rdd-start-error", "assessment failed or undecidable (rc=%d); not treated as 'not due'" % assess_rc)
    nt0 = assess.get("next_transition")
    cmd = nt0.get("command") if isinstance(nt0, dict) else None
    if not isinstance(cmd, str):
        fail(14, "rdd-start-error", "assess answer has no next_transition.command")
    try:
        status_cmd = shlex.split(cmd)
    except ValueError:
        fail(14, "rdd-start-error", "next_transition.command is not parseable")
    if status_cmd[:3] != ["gentle-ai", "review", "status"]:
        fail(14, "rdd-start-error", "STATUS command is not 'gentle-ai review status'; refused: " + cmd[:200])
    status, _ = run_json(status_cmd, cwd)
    nt = status.get("next_transition")
    ex = nt.get("execute") if isinstance(nt, dict) else None
    if not isinstance(ex, dict) or nt.get("kind") != "execute" or ex.get("operation") != "review.start":
        fail(14, "rdd-start-error", "STATUS is not a review.start execute: " + json.dumps(nt)[:600])
    env, _ = run_json(["gentle-ai", "review", "start"] + tokens(ex.get("arguments")), cwd)
    if not str(env.get("schema", "")).startswith("gentle-ai.review-integration.consent"):
        return write_started(args.outfile, env, "no consent envelope")
    if args.consent != "granted":
        print(json.dumps(env, indent=2, sort_keys=True))
        fail(15, "consent-required", "re-run with --consent granted to record the maintainer's standing grant")
    choices = env.get("choices")
    granted = [c for c in choices if isinstance(c, dict) and c.get("answer") == "granted"] if isinstance(choices, list) else []
    if len(granted) != 1:
        fail(14, "rdd-start-error", "no unique granted choice (%d)" % len(granted))
    inv_text = granted[0].get("invocation")
    if not isinstance(inv_text, str):
        fail(14, "rdd-start-error", "granted choice has no usable invocation")
    try:
        inv = shlex.split(inv_text)
    except ValueError:
        fail(14, "rdd-start-error", "granted invocation is not parseable")
    if inv[:3] != ["gentle-ai", "review", "start"]:
        fail(14, "rdd-start-error", "granted invocation is not 'gentle-ai review start'; refused")
    res, _ = run_json(inv, cwd)
    return write_started(args.outfile, res, "granted START action=%s" % res.get("action"))


def write_started(outfile, doc, note):
    # a START that did not start a review carries no continuation (e.g. action=refused): that is an error
    if not isinstance(doc.get("next_transition") or doc.get("status_continuation"), dict):
        fail(14, "rdd-start-error", "START did not start a review (action=%s reason=%s)"
             % (doc.get("action"), doc.get("reason_code")))
    with open(outfile, "w") as fh:
        json.dump(doc, fh)
    say("started", note)
    return 0


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
    try:
        sys.exit(run(args))
    except (KeyError, TypeError, AttributeError, IndexError, OSError) as e:
        fail(14, "rdd-start-error", "malformed provider output or unusable path: %s: %s" % (type(e).__name__, e))


if __name__ == "__main__":
    main(sys.argv[1:])
