package resume

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

const (
	renderUsage = "usage: resume-render.sh [--json FILE|-] [--cwd DIR] [--base-ref REF] [--no-gh]"
	renderProg  = "resume-render.sh"
)

// renderArgs is the parsed command line of resume-render.sh. fwd is what is handed to resume-state.
type renderArgs struct {
	jsonSrc   string
	jsonGiven bool
	fwd       []string
	toolbelt  string // --toolbelt DIR: run the sibling resume-state.sh found there instead of the in-process command
}

// parseRenderArgs is the argument loop of the script, message for message. A non-negative rc ends the run with it.
func parseRenderArgs(args []string, s cli.Stdio) (a renderArgs, rc int) {
	usage := func() (renderArgs, int) { fmt.Fprintln(s.Err, renderUsage); return a, cli.ExitUsage }
	for i := 0; i < len(args); {
		switch arg := args[i]; {
		case arg == "--json":
			if i+1 >= len(args) {
				return usage()
			}
			if args[i+1] == "" {
				fmt.Fprintf(s.Err, "%s: --json requires a non-empty FILE or '-'\n", renderProg)
				return a, cli.ExitUsage
			}
			a.jsonGiven, a.jsonSrc = true, args[i+1]
			i += 2
		case arg == "--cwd" || arg == "--base-ref":
			if i+1 >= len(args) {
				return usage()
			}
			a.fwd = append(a.fwd, arg, args[i+1])
			i += 2
		case arg == "--toolbelt":
			if i+1 >= len(args) {
				return usage()
			}
			a.toolbelt = args[i+1]
			i += 2
		case strings.HasPrefix(arg, "--toolbelt="):
			a.toolbelt = strings.TrimPrefix(arg, "--toolbelt=")
			i++
		case arg == "--no-gh":
			a.fwd = append(a.fwd, arg)
			i++
		case arg == "-h" || arg == "--help":
			fmt.Fprintln(s.Out, renderUsage)
			return a, cli.ExitOK
		default:
			fmt.Fprintf(s.Err, "%s: unknown argument: %s\n", renderProg, arg)
			return usage()
		}
	}
	if a.jsonGiven && len(a.fwd) > 0 {
		fmt.Fprintf(s.Err, "%s: --cwd/--base-ref/--no-gh apply to resume-state.sh and cannot be combined with --json\n", renderProg)
		return a, cli.ExitUsage
	}
	return a, -1
}

// RunRender is `rsdd status resume-render`: the port of resume-render.sh.
func RunRender(args []string, s cli.Stdio) int {
	a, rc := parseRenderArgs(args, s)
	if rc >= 0 {
		return rc
	}
	if !onPath(environ(s), s.Cwd, "jq") {
		fmt.Fprintln(s.Err, "DEGRADED: jq not found; cannot render the resume handoff")
		return cli.ExitDegraded
	}
	fail := func(format string, v ...any) int {
		fmt.Fprintf(s.Err, renderProg+": "+format+"\n", v...)
		return cli.ExitUsage
	}
	var data []byte
	switch {
	case !a.jsonGiven:
		out, code := runSiblingState(a, s)
		if code != 0 {
			fmt.Fprintf(s.Err, "%s: resume-state.sh failed (rc %d)\n", renderProg, code)
			if code == 3 {
				return cli.ExitDegraded
			}
			return cli.ExitUsage
		}
		data = out
	case a.jsonSrc == "-":
		if s.In != nil {
			data, _ = io.ReadAll(s.In)
		}
	default:
		path := abs(s.Cwd, a.jsonSrc)
		if st, err := os.Stat(path); err != nil || !st.Mode().IsRegular() {
			return fail("JSON file absent or unreadable: %s", a.jsonSrc)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return fail("JSON file absent or unreadable: %s", a.jsonSrc)
		}
		data = b
	}
	doc, msg := validateDocument(data)
	if msg != "" {
		return fail("%s", msg)
	}
	text, err := renderHandoff(doc)
	if err != nil {
		return fail("render failed: %s", err)
	}
	_, _ = io.WriteString(s.Out, text)
	return cli.ExitOK
}

// runSiblingState produces the document in self-run mode. With a toolbelt it runs that directory's resume-state.sh
// (the shim, or a stub in a test) and its stderr passes through; without one it runs the command in process. The code
// is the exit code of the run.
func runSiblingState(a renderArgs, s cli.Stdio) ([]byte, int) {
	if a.toolbelt == "" {
		var out bytes.Buffer
		sub := s
		sub.Out = &out
		code := RunState(a.fwd, sub)
		return out.Bytes(), code
	}
	res, err := proc.Run(proc.Spec{
		Argv: append([]string{"bash", filepath.Join(a.toolbelt, "resume-state.sh")}, a.fwd...),
		Dir:  s.Cwd, Env: environ(s), Timeout: 30 * time.Minute, MaxBytes: 256 << 20, Now: s.Clock,
	})
	if err != nil {
		return nil, 127
	}
	_, _ = s.Err.Write(res.Stderr)
	code := res.ReturnCode
	if code < 0 {
		code = 128 - code // the shell's code for a signal
	}
	return res.Stdout, code
}

// validateDocument is the validation chain of the script: exactly one JSON document, a truthy one, of the right schema
// and shape. msg is the typed error line (without the program name) or empty.
func validateDocument(data []byte) (doc *jobj, msg string) {
	if len(data) == 0 {
		return nil, "empty input (no JSON document)"
	}
	docs, err := parseDocs(data)
	switch {
	case err != nil:
		return nil, "malformed JSON input"
	case len(docs) == 0:
		return nil, "empty input (no JSON document)"
	case len(docs) > 1:
		return nil, "multiple JSON documents in the input (want exactly one)"
	case !truthy(docs[0]):
		return nil, "malformed JSON input" // jq -e . exits 1 on null and false
	}
	// `.schema? // "" | tostring`: only an object has a schema, and null and false count as absent.
	got := ""
	if o, ok := docs[0].(*jobj); ok && truthy(o.get("schema")) {
		got = tostring(o.get("schema"))
	}
	if got != stateSchema {
		return nil, fmt.Sprintf("wrong schema: [%s] (want %s)", got, stateSchema)
	}
	o := docs[0].(*jobj)
	if !shapeOK(o) {
		return nil, "malformed document: worktrees/branches must be arrays of objects, repo an object, prs null or an array of objects, base_ref a string"
	}
	return o, ""
}

// allObjects is `all(.[]; type=="object")`.
func allObjects(v jv) bool {
	for _, e := range v.([]jv) {
		if _, ok := e.(*jobj); !ok {
			return false
		}
	}
	return true
}

// shapeOK is the jq -e shape check: worktrees and branches arrays of objects, base_ref a string, repo an object (null
// and false read as {}), prs null or an array of objects.
func shapeOK(o *jobj) bool {
	if jqType(o.get("worktrees")) != "array" || jqType(o.get("branches")) != "array" || jqType(o.get("base_ref")) != "string" {
		return false
	}
	if !allObjects(o.get("worktrees")) || !allObjects(o.get("branches")) {
		return false
	}
	if repo := o.get("repo"); truthy(repo) && jqType(repo) != "object" {
		return false
	}
	prs := o.get("prs")
	return prs == nil || (jqType(prs) == "array" && allObjects(prs))
}
