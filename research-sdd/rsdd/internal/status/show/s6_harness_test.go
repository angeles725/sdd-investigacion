package show

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// The S6 harness: full `research-sdd-status.sh <target> [flags]` invocations of the DEFAULT report over crafted
// corpora. The rendering is the golden, as in S5: every run's rc, stdout and stderr, the tree it left behind, and
// the subprocesses it started. The §8c campaign block and the document-cycle outline (slice S7) run as the
// script's own on one side and as the port's on the other.
//
// The subprocesses are authored fakes, one set for both sides: a gh on PATH and the toolbelt's verify-state.sh.
// Each logs its argv and answers from the world's spec/ directory:
//
//	spec/gh.{out,rc,sleep}      the visibility probe (sleep: the call outlives its bound)
//	spec/v.{out,err,rc}         verify-state (the consistency footer)
//
// The clock of a run is fixed on both sides: _RSDD_NOW_EPOCH (the script's own hook) is 2026-01-01T00:00:00Z.

const goldenS6 = goldenS2Dir + "s6.golden"

type s6Scenario = s5Scenario

// ---- recorded subprocess calls --------------------------------------------------------------------------------

// s6Calls are the subprocesses of a run, as the golden records them.
type s6Calls struct{ gh, ver []string }

func (k s6Calls) render() string {
	var b strings.Builder
	b.WriteString("--- calls\n")
	for _, l := range k.gh {
		b.WriteString("gh: " + l + "\n")
	}
	for _, l := range k.ver {
		b.WriteString("verify: " + l + "\n")
	}
	b.WriteString("--- end calls\n")
	return b.String()
}

// renderS6 is the golden section of one scenario: the S3 rendering and the subprocesses of the runs. The toolbelt
// the run lived in is written <TOOLBELT>: the footer of a degraded report names it.
func renderS6(t testing.TB, sc s6Scenario, outs []outcome, root, toolbelt string, calls s6Calls) string {
	return strings.ReplaceAll(renderS3(t, sc.s3Scenario, outs, root)+calls.render(), toolbelt, "<TOOLBELT>")
}

// ---- the port's side in a replay -------------------------------------------------------------------------------

// s6Replay answers the port's subprocess calls from the world's spec, in process.
type s6Replay struct {
	root  string
	calls *s6Calls
}

func (r *s6Replay) spec(name string) (string, bool) {
	b, err := os.ReadFile(filepath.Join(r.root, "spec", name))
	return strings.TrimSuffix(string(b), "\n"), err == nil
}

// raw is a spec file as the fake `cat`s it.
func (r *s6Replay) raw(name string) (string, bool) {
	b, err := os.ReadFile(filepath.Join(r.root, "spec", name))
	return string(b), err == nil
}

func (r *s6Replay) rc(prefix string) int {
	v, _ := r.spec(prefix + ".rc")
	n, _ := strconv.Atoi(v)
	return n
}

func (r *s6Replay) scrub(s string) string { return strings.ReplaceAll(s, r.root, "<ROOT>") }

// probe is the visibility probe: gh answers what the spec says.
func (r *s6Replay) probe(_ gh.Options, repo string) (gh.Visibility, error) {
	r.calls.gh = append(r.calls.gh, r.scrub("repo view "+repo+" --json visibility --jq .visibility"))
	if _, ok := r.spec("gh.sleep"); ok {
		return gh.Visibility{State: gh.StateTimeout, RC: 124}, nil
	}
	raw, _ := r.raw("gh.out")
	out := strings.TrimRight(raw, "\n")
	if rc := r.rc("gh"); rc != 0 {
		return gh.Visibility{State: gh.StateError, RC: rc, Raw: strings.ToUpper(out)}, nil
	}
	v := gh.Visibility{State: gh.StateUnrecognised, Raw: strings.ToUpper(out)}
	if s := gh.State(v.Raw); s.Decided() {
		v.State = s
	}
	return v, nil
}

// verify is verify-state: it answers the spec's report and exit code.
func (r *s6Replay) verify(args []string, s cli.Stdio) int {
	asked := make([]string, len(args))
	for i, a := range args {
		asked[i] = r.scrub(a)
	}
	r.calls.ver = append(r.calls.ver, strings.Join(asked, " "))
	out, _ := r.raw("v.out")
	_, _ = io.WriteString(s.Out, out)
	if e, ok := r.raw("v.err"); ok {
		_, _ = io.WriteString(s.Err, e)
	}
	return r.rc("v")
}

// found is `command -v`: the fake gh is on the (unreal) PATH, any other program is looked up for real.
func (r *s6Replay) found(bin string, environ []string, dir string) bool {
	return bin == "gh" || commandFound(bin, environ, dir)
}

// runGoS6 runs the port over one world. The seams are swapped for the run and restored after it.
func runGoS6(t testing.TB, sc s6Scenario, root string, e s5Env, rep *s6Replay) []outcome {
	t.Helper()
	seamMu.Lock()
	defer seamMu.Unlock()
	oldV, oldP, oldF := verifyState, ghProbe, ghFound
	defer func() { verifyState, ghProbe, ghFound = oldV, oldP, oldF }()
	if rep != nil {
		verifyState, ghProbe, ghFound = rep.verify, rep.probe, rep.found
	}
	var res []outcome
	for i := range sc.runs {
		var out, errb bytes.Buffer
		s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: e.lookup, Environ: func() []string { return e.environ },
			Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: filepath.Join(root, sc.cwd)}
		rc := run(sc.argv(i, root), s, syncOr(nextOr(liveSeams, (*ctx).report)))
		res = append(res, outcome{rc, out.String(), errb.String()})
	}
	return res
}
