package maint

import (
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// RddDrive is `rsdd maint rdd-drive [--max-steps N] <cwd> <first-json-file>`, the Go port of
// the former toolbelt/maint/kit-rdd-drive.py (kit issue #2212; now the shim maint/kit-rdd-drive.sh).
//
// It follows gentle-ai next_transition / status_continuation from the document rdd-start wrote until the
// review is acknowledged or something needs a human. Only provider-issued operations named review.<name>
// run, with their ordered argument tokens. Reviewer captures (review.capture-result) are launched
// concurrently, in provider order; when one or more carry a continuation the LAST one in provider order
// decides, otherwise the last bound STATUS command is asked again. Any other collect is not driven:
// `rdd-stop: non-capture-collect (<capture_operation>)`. A reason code is printed only when the provider
// supplied it.
//
// Exit states: 0 acknowledged (or target_already_acknowledged), 2 usage, 3 degraded, 13 rdd-not-approved,
// 14 rdd-protocol-error, 15 consent-required.
func RddDrive(args []string, s cli.Stdio) int { return rddDrive(args, s, newOSTool(s)) }

const driveUsage = "usage: rsdd maint rdd-drive [-h] [--max-steps MAX_STEPS] cwd first"

func rddDrive(args []string, s cli.Stdio, t tool) int {
	p, err := parseArgs(args, []optSpec{{name: "max-steps", integer: true, def: "40"}}, "cwd", "first")
	if err != nil {
		return usageFail(s.Err, driveUsage, "rsdd maint rdd-drive", err)
	}
	if p.help {
		fmt.Fprintln(s.Out, driveUsage)
		return rddOK
	}
	if t.present() != nil {
		return degraded(s.Out, s.Err, "kit-rdd-drive: degraded: missing runtime dependency: gentle-ai")
	}
	steps, _ := strconv.Atoi(strings.TrimSpace(p.opts["max-steps"]))
	d := &driver{out: s.Out, t: t, cwd: p.pos[0], first: p.pos[1], maxSteps: steps, read: readFile}
	return finish(d.drive(), s, "rdd-drive")
}

type driver struct {
	out      io.Writer
	t        tool
	cwd      string
	first    string
	maxSteps int
	read     func(path string) ([]byte, error)
}

func (d *driver) log(a ...string) { fmt.Fprintln(d.out, strings.Join(a, " ")) }

func (d *driver) stop(reason, detail string) error {
	d.log("rdd-stop: " + reason)
	if detail != "" {
		d.log(detail)
	}
	if reason == "target_already_acknowledged" {
		return &exit{rddOK}
	}
	return &exit{rddNotApprove}
}

func (d *driver) protocolError(detail string) error {
	d.log("kit-rdd-drive: rdd-protocol-error: " + detail)
	return &exit{rddError}
}

// opCmd is the command for a provider-issued operation: `gentle-ai review <name> <tokens...>`.
func (d *driver) opCmd(op, args any) ([]string, error) {
	name, ok := op.(string)
	if !ok || !strings.HasPrefix(name, "review.") || len(name) == len("review.") {
		return nil, d.protocolError("operation is not review.<name>: " + pyRepr(op))
	}
	list, ok := args.([]any)
	if !ok {
		return nil, d.protocolError("operation " + name + " has no arguments list")
	}
	cmd := []string{"gentle-ai", "review", strings.SplitN(name, ".", 2)[1]}
	for _, a := range list {
		o, isObj := a.(*obj)
		var tok string
		if isObj {
			tok, isObj = o.get("token").(string)
		}
		if !isObj {
			return nil, d.protocolError("operation " + name + " has an argument without a string token: " + head(pyDumps(a), 200))
		}
		cmd = append(cmd, tok)
	}
	return cmd, nil
}

// runDoc runs cmd and returns its JSON answer (the last JSON object of the output when the whole is not
// JSON) and exit code. A nil document with a non-empty note is the NON-JSON diagnostic line.
func (d *driver) runDoc(cmd []string) (doc any, rc int, note string, err error) {
	res, err := d.t.run(cmd, d.cwd)
	if err != nil {
		return nil, 0, "", err
	}
	out := strings.TrimSpace(res.stdout)
	if v, derr := decodeJSON([]byte(out)); derr == nil {
		return v, res.rc, "", nil
	}
	cand := out
	if i := strings.LastIndex(out, "\n{"); i >= 0 {
		cand = out[i+1:]
	}
	if v, derr := decodeJSON([]byte(cand)); derr == nil {
		return v, res.rc, "", nil
	}
	return nil, res.rc, fmt.Sprintf("NON-JSON rc=%d stdout=%s stderr=%s", res.rc, tail(out, 800), tail(strings.TrimSpace(res.stderr), 800)), nil
}

// step runs one command sequentially, logging a NON-JSON note at once.
func (d *driver) step(cmd []string) (any, error) {
	d.log("RUN", head(strings.Join(cmd, " "), 300))
	doc, _, note, err := d.runDoc(cmd)
	if note != "" {
		d.log(note)
	}
	return doc, err
}

func (d *driver) drive() error {
	raw, rerr := d.read(d.first)
	if rerr != nil {
		return d.protocolError("first document unreadable: " + rerr.Error())
	}
	doc, jerr := decodeJSON(raw)
	if jerr != nil {
		return d.protocolError("first document unreadable: " + jerr.Error())
	}
	var lastStatus []string
	for i := 0; i < d.maxSteps; i++ {
		if doc == nil {
			return d.stop("non-json", "")
		}
		o, ok := doc.(*obj)
		if !ok {
			return d.protocolError("document is not a JSON object: " + head(pyDumps(doc), 200))
		}
		schema := ""
		if o.has("schema") {
			schema = pyStr(o.get("schema"))
		}
		if strings.HasPrefix(schema, "gentle-ai.review-acknowledged") {
			ack := &obj{m: map[string]any{}}
			for _, k := range []string{"schema", "lineage_id", "target_identity", "outcome", "action"} {
				ack.set(k, o.get(k))
			}
			d.log("ACKNOWLEDGED", pyDumps(ack))
			return &exit{rddOK}
		}
		if strings.HasPrefix(schema, "gentle-ai.review-integration.consent") {
			d.log("kit-rdd-drive: consent-required: the document is a consent envelope; nothing was run")
			d.log(pyIndented(o))
			return &exit{rddConsent}
		}
		if f := o.get("forecast"); truthy(f) {
			d.log("FORECAST", head(pyDumps(f), 600))
		}
		ntv := o.get("status_continuation")
		if !truthy(ntv) {
			ntv = o.get("next_transition")
		}
		if !truthy(ntv) {
			return d.stop("no-transition", head(pyDumps(o), 1500))
		}
		nt, ok := ntv.(*obj)
		if !ok {
			return d.protocolError("transition is not an object: " + head(pyDumps(ntv), 200))
		}
		switch nt.get("kind") {
		case "stop":
			if !truthy(nt.get("reason_code")) {
				return d.stop("stop-without-reason", head(pyDumps(nt), 800))
			}
			return d.stop(pyStr(nt.get("reason_code")), head(pyDumps(nt), 800))
		case "execute":
			ex, ok := nt.get("execute").(*obj)
			if !ok {
				return d.protocolError("execute transition without an execute object")
			}
			cmd, err := d.opCmd(ex.get("operation"), ex.get("arguments"))
			if err != nil {
				return err
			}
			if ex.get("operation") == "review.status" {
				lastStatus = cmd
			}
			if doc, err = d.step(cmd); err != nil {
				return err
			}
		case "collect":
			next, status, err := d.collect(nt, lastStatus)
			if err != nil {
				return err
			}
			lastStatus = status
			doc = next
		default:
			return d.stop("unknown-transition", head(pyDumps(nt), 1500))
		}
	}
	return d.stop("step-limit", "")
}

// collect drives one collect transition and returns the next document.
func (d *driver) collect(nt *obj, lastStatus []string) (any, []string, error) {
	coll, _ := nt.get("collect").(*obj)
	var inputs []any
	if coll != nil {
		inputs, _ = coll.get("inputs").([]any)
	}
	if len(inputs) == 0 {
		return nil, nil, d.protocolError("collect transition without a non-empty inputs list")
	}
	objs := make([]*obj, len(inputs))
	for i, in := range inputs {
		o, ok := in.(*obj)
		if !ok {
			return nil, nil, d.protocolError("collect inputs are not objects")
		}
		objs[i] = o
	}
	var odd []string
	for _, i := range objs {
		if i.get("capture_operation") != "review.capture-result" {
			odd = append(odd, pyStr(i.get("capture_operation")))
		}
	}
	if len(odd) > 0 {
		var detail any = nt
		if nt.has("correction_request") {
			detail = nt.get("correction_request")
		}
		return nil, nil, d.stop("non-capture-collect ("+strings.Join(odd, ", ")+")", head(pyDumps(detail), 3000))
	}
	cmds := make([][]string, len(objs))
	lenses := make([]any, len(objs))
	for n, i := range objs {
		c, err := d.opCmd(i.get("capture_operation"), i.get("arguments"))
		if err != nil {
			return nil, nil, err
		}
		cmds[n] = c
		var lens any
		if sub := i.get("artifact_subject"); truthy(sub) {
			so, ok := sub.(*obj)
			if !ok {
				return nil, nil, d.protocolError("malformed provider output: AttributeError: artifact_subject is not an object")
			}
			lens = so.get("lens")
		}
		if !truthy(lens) {
			lens = i.get("name")
		}
		lenses[n] = lens
	}
	d.log(fmt.Sprintf("COLLECT %d inputs: %s", len(cmds), pyRepr(lenses)))
	for _, c := range cmds {
		d.log("LAUNCH", head(strings.Join(c, " "), 300))
	}
	type capture struct {
		doc  any
		rc   int
		note string
		err  error
	}
	res := make([]capture, len(cmds))
	var wg sync.WaitGroup
	for n := range cmds {
		wg.Add(1)
		go func() {
			defer wg.Done()
			doc, rc, note, err := d.runDoc(cmds[n])
			res[n] = capture{doc, rc, note, err}
		}()
	}
	wg.Wait()
	var terminal any
	var firstErr error
	for _, r := range res {
		if r.err != nil {
			// Report every sibling's result before failing: a crashed capture must not hide the others.
			if firstErr == nil {
				firstErr = r.err
			}
			continue
		}
		if r.note != "" {
			d.log(r.note)
		}
		shown := "None"
		if truthy(r.doc) {
			shown = head(pyDumps(r.doc), 400)
		}
		d.log(fmt.Sprintf("CAPTURE rc=%d %s", r.rc, shown))
		cd, ok := r.doc.(*obj)
		if !ok {
			continue
		}
		term := truthy(cd.get("status_continuation"))
		if !term {
			ntv := cd.get("next_transition")
			if truthy(ntv) {
				no, ok := ntv.(*obj)
				if !ok {
					return nil, nil, d.protocolError("malformed provider output: AttributeError: next_transition is not an object")
				}
				term = no.get("kind") == "execute" || no.get("kind") == "stop"
			}
		}
		if term {
			terminal = cd
		}
	}
	if firstErr != nil {
		return nil, nil, firstErr
	}
	if terminal != nil {
		return terminal, lastStatus, nil
	}
	if lastStatus == nil {
		return nil, nil, d.stop("no-bound-status", "")
	}
	next, err := d.step(lastStatus)
	return next, lastStatus, err
}
