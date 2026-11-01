package maint

import (
	"fmt"
	"io"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// RddStart is `rsdd maint rdd-start [--consent granted] [--base-ref REF] [--agent NAME] <cwd> <outfile>`,
// the Go port of toolbelt/maint/kit-rdd-start.py (kit issue #2212).
//
// It assesses the committed range <REF>..HEAD of <cwd>; when a native review is due it runs the
// provider-issued STATUS, then the provider-issued START, and writes the START output to <outfile>.
// Consent is explicit: without --consent granted a consent envelope is printed losslessly and the tool exits
// 15, running neither a granted nor a declined invocation. A review is "not due" ONLY when
// `gentle-ai review assess` exited 0 and said review_due is the boolean false. The allowlist is exact: the
// assess command, a STATUS whose argv[:3] is gentle-ai review status, `gentle-ai review start` with the
// provider's tokens, and the provider's granted invocation, argv[:3] gentle-ai review start.
//
// Exit states: 0 started, 2 usage, 3 degraded, 10 rdd-not-due, 14 rdd-start-error, 15 consent-required.
// Each non-usage state prints a `kit-rdd-start: <state>` line on stdout, as the legacy tool did.
func RddStart(args []string, s cli.Stdio) int { return rddStart(args, s, newOSTool(s)) }

const startUsage = "usage: rsdd maint rdd-start [-h] [--consent {granted}] [--base-ref BASE_REF] [--agent AGENT] cwd outfile"

func rddStart(args []string, s cli.Stdio, t tool) int {
	p, err := parseArgs(args, []optSpec{
		{name: "consent", choices: []string{"granted"}},
		{name: "base-ref", def: "origin/main"},
		{name: "agent", def: "claude-code"},
	}, "cwd", "outfile")
	if err != nil {
		return usageFail(s.Err, startUsage, "rsdd maint rdd-start", err)
	}
	if p.help {
		fmt.Fprintln(s.Out, startUsage)
		return rddOK
	}
	st := &starter{out: s.Out, t: t, cwd: p.pos[0], outfile: p.pos[1], consent: p.opts["consent"],
		baseRef: p.opts["base-ref"], agent: p.opts["agent"]}
	if t.present() != nil {
		return degraded(s.Out, s.Err, "kit-rdd-start: degraded: degraded: missing runtime dependency: gentle-ai")
	}
	return finish(st.run(), s, "rdd-start")
}

type starter struct {
	out                   io.Writer
	t                     tool
	cwd, outfile, consent string
	baseRef, agent        string
}

func (st *starter) say(state, msg string) {
	if msg != "" {
		msg = ": " + msg
	}
	fmt.Fprintf(st.out, "kit-rdd-start: %s%s\n", state, msg)
}

func (st *starter) fail(code int, state, msg string) error {
	st.say(state, msg)
	return &exit{code}
}

func (st *starter) bad(msg string) error { return st.fail(rddError, "rdd-start-error", msg) }

// runJSON runs argv and returns its JSON object answer and exit code. A command that cannot run is the
// legacy OSError path; non-JSON or a non-object answer is an rdd-start-error.
func (st *starter) runJSON(argv []string) (*obj, int, error) {
	res, err := st.t.run(argv, st.cwd)
	if err != nil {
		return nil, 0, st.bad("malformed provider output or unusable path: OSError: " + err.Error())
	}
	doc, derr := decodeJSON([]byte(res.stdout))
	if derr != nil {
		return nil, 0, st.bad(fmt.Sprintf("non-JSON answer from %s rc=%d stdout=%s stderr=%s",
			strings.Join(argv[:min(len(argv), 4)], " "), res.rc, tail(res.stdout, 300), tail(res.stderr, 300)))
	}
	o, ok := doc.(*obj)
	if !ok {
		return nil, 0, st.bad(fmt.Sprintf("answer from %s is not a JSON object", strings.Join(argv[:min(len(argv), 4)], " ")))
	}
	return o, res.rc, nil
}

// tokens is the ordered token strings of a provider argument list; anything else is malformed.
func (st *starter) tokens(arguments any) ([]string, error) {
	list, ok := arguments.([]any)
	if !ok || len(list) == 0 {
		return nil, st.bad("provider arguments are missing or empty")
	}
	out := make([]string, 0, len(list))
	for _, a := range list {
		o, isObj := a.(*obj)
		var tok string
		if isObj {
			tok, isObj = o.get("token").(string)
		}
		if !isObj {
			return nil, st.bad("provider argument without a string token: " + head(pyDumps(a), 200))
		}
		out = append(out, tok)
	}
	return out, nil
}

func (st *starter) run() error {
	assess, assessRC, err := st.runJSON([]string{"gentle-ai", "review", "assess", "--cwd", st.cwd, "--agent", st.agent,
		"--base-ref", st.baseRef, "--committed-only", "--json"})
	if err != nil {
		return err
	}
	st.say("assess", fmt.Sprintf("rc=%d risk=%s review_due=%s reason=%s", assessRC, pyStr(assess.get("risk")),
		pyStr(assess.get("review_due")), pyStr(assess.get("review_due_reason"))))
	due, isBool := assess.get("review_due").(bool)
	if assessRC == 0 && isBool && !due {
		return st.fail(rddNotDue, "rdd-not-due", pyStr(assess.get("review_due_reason")))
	}
	if assessRC != 0 || !isBool || !due {
		return st.bad(fmt.Sprintf("assessment failed or undecidable (rc=%d); not treated as 'not due'", assessRC))
	}
	var cmd string
	cmdOK := false
	if nt0, ok := assess.get("next_transition").(*obj); ok {
		cmd, cmdOK = nt0.get("command").(string)
	}
	if !cmdOK {
		return st.bad("assess answer has no next_transition.command")
	}
	statusCmd, serr := shlexSplit(cmd)
	if serr != nil {
		return st.bad("next_transition.command is not parseable")
	}
	if !hasPrefix(statusCmd, "gentle-ai", "review", "status") {
		return st.bad("STATUS command is not 'gentle-ai review status'; refused: " + head(cmd, 200))
	}
	status, _, err := st.runJSON(statusCmd)
	if err != nil {
		return err
	}
	nt, _ := status.get("next_transition").(*obj)
	var ex *obj
	if nt != nil {
		ex, _ = nt.get("execute").(*obj)
	}
	if ex == nil || nt.get("kind") != "execute" || ex.get("operation") != "review.start" {
		return st.bad("STATUS is not a review.start execute: " + head(pyDumps(status.get("next_transition")), 600))
	}
	toks, err := st.tokens(ex.get("arguments"))
	if err != nil {
		return err
	}
	env, _, err := st.runJSON(append([]string{"gentle-ai", "review", "start"}, toks...))
	if err != nil {
		return err
	}
	if !strings.HasPrefix(pyStr(env.get("schema")), "gentle-ai.review-integration.consent") {
		return st.writeStarted(env, "no consent envelope")
	}
	if st.consent != "granted" {
		fmt.Fprintln(st.out, pyIndented(env))
		return st.fail(rddConsent, "consent-required", "re-run with --consent granted to record the maintainer's standing grant")
	}
	choices, _ := env.get("choices").([]any)
	var granted []*obj
	for _, c := range choices {
		if o, ok := c.(*obj); ok && o.get("answer") == "granted" {
			granted = append(granted, o)
		}
	}
	if len(granted) != 1 {
		return st.bad(fmt.Sprintf("no unique granted choice (%d)", len(granted)))
	}
	invText, ok := granted[0].get("invocation").(string)
	if !ok {
		return st.bad("granted choice has no usable invocation")
	}
	inv, ierr := shlexSplit(invText)
	if ierr != nil {
		return st.bad("granted invocation is not parseable")
	}
	if !hasPrefix(inv, "gentle-ai", "review", "start") {
		return st.bad("granted invocation is not 'gentle-ai review start'; refused")
	}
	res, _, err := st.runJSON(inv)
	if err != nil {
		return err
	}
	return st.writeStarted(res, "granted START action="+pyStr(res.get("action")))
}

// writeStarted stores the START document. A START that did not start a review carries no continuation
// (for example action=refused): that is an error, never "started".
func (st *starter) writeStarted(doc *obj, note string) error {
	cont := doc.get("next_transition")
	if !truthy(cont) {
		cont = doc.get("status_continuation")
	}
	if _, ok := cont.(*obj); !ok {
		return st.bad(fmt.Sprintf("START did not start a review (action=%s reason=%s)", pyStr(doc.get("action")), pyStr(doc.get("reason_code"))))
	}
	if err := fsx.WriteAtomic(st.outfile, []byte(pyDumps(doc))); err != nil {
		return st.bad("malformed provider output or unusable path: OSError: " + err.Error())
	}
	st.say("started", note)
	return nil
}

func hasPrefix(argv []string, prefix ...string) bool {
	if len(argv) < len(prefix) {
		return false
	}
	for i, p := range prefix {
		if argv[i] != p {
			return false
		}
	}
	return true
}
