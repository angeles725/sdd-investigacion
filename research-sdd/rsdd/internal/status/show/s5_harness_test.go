package show

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// The S5 harness: full `research-sdd-status.sh <target> --next ...` invocations whose verdict goes through the two
// sections slice S5 ports: the retro-coverage derivation behind RETRO-DUE and the terminal gate of an exhausted
// walk (ISSUES-DUE, the exhausted STOP and its no-garbage check). The rendering is the golden: every run's rc,
// stdout and stderr, the tree left behind, and the subprocesses the run started.
//
// The subprocesses are authored fakes, one set for both sides: a gh on PATH, the toolbelt's reconcile-issues.sh,
// clean-check.sh and verify-state.sh. Each logs its argv (reconcile also the issue cache it was handed) and
// answers from the world's spec/ directory, so a scenario states what gh, reconcile and clean-check say.
//
//	spec/gh.{out,err,rc,sleep}            the batch prefetch (sleep: the call outlives its bound)
//	spec/r.<retro>[.c].{out,err,rc,sleep} one reconcile probe; ".c" is the call that is handed the issue cache
//	spec/cc.{out,rc,sleep}                clean-check

const goldenS5 = goldenS2Dir + "s5.golden"

type s5Scenario struct {
	s4Scenario
	env  map[string]string // extra environment of the run
	noCC bool              // the toolbelt has no clean-check.sh
}

// withoutCC marks a scenario whose toolbelt lacks clean-check.sh.
func (sc s5Scenario) withoutCC() s5Scenario { sc.noCC = true; return sc }

// n5 is the one-state-file scenario over a corpus: corpus/RESEARCH-STATE.md plus extra files.
func n5(name, want, state string, extra files, env map[string]string, flags ...string) s5Scenario {
	return m5(name, want, merge(files{stateRel: state}, extra), env, flags...)
}

// m5 is a scenario over an arbitrary file set (the target is {ROOT}/corpus).
func m5(name, want string, f files, env map[string]string, flags ...string) s5Scenario {
	return s5Scenario{s4Scenario: m4(name, want, f, flags...), env: env}
}

// s5Env is how one side of a scenario reaches the world: the environment its children and its Env() see.
type s5Env struct {
	environ  []string
	toolbelt string
}

func (e s5Env) lookup(k string) string {
	if k == "RSDD_TOOLBELT_DIR" {
		return e.toolbelt
	}
	for i := len(e.environ) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(e.environ[i], k+"="); ok {
			return v
		}
	}
	return ""
}

// s5Environ is the environment of one run: the fakes first on PATH, the spec and the log directory, and the
// script's own clean-check switched off unless the scenario asks for it.
func (sc s5Scenario) environ(root, logDir, bin string) []string {
	extra := map[string]string{"PATH": bin + ":" + os.Getenv("PATH"), "S5_SPEC": filepath.Join(root, "spec"), "S5_LOG": logDir}
	if _, ok := sc.env["RSDD_STATUS_NO_CLEAN_CHECK"]; !ok {
		extra["RSDD_STATUS_NO_CLEAN_CHECK"] = "1"
	}
	for k, v := range sc.env {
		extra[k] = v
	}
	e := []string{"LC_ALL=C", "HOME=" + root, "TMPDIR=" + root}
	for k, v := range extra {
		e = append(e, k+"="+v)
	}
	return e
}

// ---- recorded subprocess calls -----------------------------------------------------------------------------

// s5Calls are the subprocesses of a run, as the golden records them: one rendered line per call.
type s5Calls struct{ gh, rec, cc []string }

var cacheName = regexp.MustCompile(`<ROOT>/tmp\.[A-Za-z0-9]+`)

func (k s5Calls) scrub(s, root string) string {
	return cacheName.ReplaceAllString(strings.ReplaceAll(s, root, "<ROOT>"), "<CACHE>")
}

func (k s5Calls) render() string {
	var b strings.Builder
	b.WriteString("--- calls\n")
	for _, l := range k.gh {
		b.WriteString("gh: " + l + "\n")
	}
	for _, l := range k.rec {
		b.WriteString("reconcile: " + l + "\n")
	}
	for _, l := range k.cc {
		b.WriteString("clean-check: " + l + "\n")
	}
	b.WriteString("--- end calls\n")
	return b.String()
}

// ---- the port's side -----------------------------------------------------------------------------------------

// s5Drive is how the port reaches its children in one run: the production path with the fake reconcile in place of
// the rsdd binary (the differential), or a replay that answers from the spec and records what was asked.
type s5Drive struct {
	reconcileFake string // differential: the fake script, run through the production runner
	replay        *s5Replay
}

// s5Replay answers the port's subprocess calls from the world's spec, in process.
type s5Replay struct {
	root  string
	calls *s5Calls
}

func (r *s5Replay) spec(name string) (string, bool) {
	b, err := os.ReadFile(filepath.Join(r.root, "spec", name))
	return strings.TrimSuffix(string(b), "\n"), err == nil
}

func (r *s5Replay) rc(prefix string) int {
	if v, ok := r.spec(prefix + ".rc"); ok {
		n, _ := strconv.Atoi(v)
		return n
	}
	return 0
}

func (r *s5Replay) ghList(_ gh.Options, args ...string) (gh.RunResult, error) {
	r.calls.gh = append(r.calls.gh, r.calls.scrub(strings.Join(args, " "), r.root))
	if _, ok := r.spec("gh.sleep"); ok {
		return gh.RunResult{State: gh.StateTimeout, RC: 124}, nil
	}
	out, _ := r.spec("gh.out")
	if _, ok := r.spec("gh.out"); ok {
		out += "\n"
	}
	if rc := r.rc("gh"); rc != 0 {
		return gh.RunResult{State: gh.StateError, RC: rc, Stdout: []byte(out)}, nil
	}
	return gh.RunResult{State: gh.StateOK, Stdout: []byte(out)}, nil
}

func (r *s5Replay) reconcile(args []string, _ time.Duration, _ cli.Stdio) probeResult {
	line := r.calls.scrub(strings.Join(args, " "), r.root)
	key := filepath.Base(args[len(args)-1])
	if len(args) >= 3 && args[0] == "--issues-cache" {
		key += ".c"
		if b, err := os.ReadFile(args[1]); err == nil {
			line += " | cache=" + strconv.Quote(string(b))
		}
	}
	r.calls.rec = append(r.calls.rec, line)
	p := "r." + key
	if _, ok := r.spec(p + ".sleep"); ok {
		return probeResult{rc: 124}
	}
	out, outOK := r.spec(p + ".out")
	if outOK {
		out += "\n"
	}
	errs, errOK := r.spec(p + ".err")
	if errOK {
		errs += "\n"
	}
	return probeResult{out: out, err: errs, rc: r.rc(p)}
}

func (r *s5Replay) cleanCheck(_, target string, _ time.Duration, _ cli.Stdio) probeResult {
	r.calls.cc = append(r.calls.cc, r.calls.scrub("--target "+target, r.root))
	if _, ok := r.spec("cc.sleep"); ok {
		return probeResult{rc: 124}
	}
	out, ok := r.spec("cc.out")
	if ok {
		out += "\n"
	}
	return probeResult{out: out, rc: r.rc("cc")}
}

// s5SeamMu serializes the runs that swap the package-level seams, so parallel scenarios never see another run's
// fakes: only the port's side holds it, and the frozen script's side (the slow one) runs concurrently.
var s5SeamMu sync.Mutex

// runGoS5 runs the port over one world. The seams are swapped for the run and restored after it.
func runGoS5(t testing.TB, sc s5Scenario, root string, e s5Env, d s5Drive) []outcome {
	t.Helper()
	s5SeamMu.Lock()
	defer s5SeamMu.Unlock()
	oldV, oldG, oldR, oldP, oldC := verifyState, ghList, reconcileRun, reconcilePrefix, cleanCheckRun
	defer func() {
		verifyState, ghList, reconcileRun, reconcilePrefix, cleanCheckRun = oldV, oldG, oldR, oldP, oldC
	}()
	verifyState = func([]string, cli.Stdio) int { return 0 }
	switch {
	case d.replay != nil:
		ghList, reconcileRun, cleanCheckRun = d.replay.ghList, d.replay.reconcile, d.replay.cleanCheck
	case d.reconcileFake != "":
		reconcilePrefix = func(string, func() (string, error)) ([]string, error) { return []string{d.reconcileFake}, nil }
	}
	var res []outcome
	for i := range sc.runs {
		var out, errb bytes.Buffer
		s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: e.lookup, Environ: func() []string { return e.environ },
			Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: filepath.Join(root, sc.cwd)}
		rc := run(sc.argv(i, root), s, syncOr(nextOr(liveSeams, s4Tail)))
		res = append(res, outcome{rc, out.String(), errb.String()})
	}
	return res
}

// renderS5 is the golden section of one scenario: the S3 rendering and the subprocesses of the runs.
func renderS5(t testing.TB, sc s5Scenario, outs []outcome, root string, calls s5Calls) string {
	return renderS3(t, sc.s3Scenario, outs, root) + calls.render()
}
