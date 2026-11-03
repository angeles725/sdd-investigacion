package sweep

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

func TestAllScriptsAreTheEight(t *testing.T) {
	if !slices.Equal(allScripts, allNames) {
		t.Errorf("allScripts = %v, want the eight canonical scripts in order %v", allScripts, allNames)
	}
}

func TestParseSweepTimeout(t *testing.T) {
	const def = 30 * time.Second
	for _, c := range []struct {
		raw   string
		d     time.Duration
		shown string
		warn  bool
	}{
		{"", def, "30", false},
		{"1", time.Second, "1", false},
		{"45", 45 * time.Second, "45", false},
		{"0.5", 500 * time.Millisecond, "0.5", false},
		{".5", 500 * time.Millisecond, "0.5", false},
		{"1.50", 1500 * time.Millisecond, "1.5", false},
		{"007", 7 * time.Second, "7", false},
		{"31536000", 31536000 * time.Second, "31536000", false},
		{"31536001", def, "30", true}, // over a year
		{"0", def, "30", true},        // the script ran unbounded
		{"0.0", def, "30", true},
		{"0.0000000001", def, "30", true}, // below one nanosecond: a zero bound
		{"-1", def, "30", true},
		{"abc", def, "30", true}, // the script failed all eight with exit 125
		{"2m", def, "30", true},  // the script printed "timed out after 2ms"
		{"1e3", def, "30", true},
		{"inf", def, "30", true},
		{"0x10", def, "30", true},
		{" 5", def, "30", true},
		{"5 ", def, "30", true},
		{"1.", def, "30", true},
		{"+5", def, "30", true},
	} {
		got, warn := parseSweepTimeout(c.raw)
		if got.d != c.d || got.shown != c.shown || (warn != "") != c.warn {
			t.Errorf("parseSweepTimeout(%q) = %v %q warn=%q; want %v %q warn=%v", c.raw, got.d, got.shown, warn, c.d, c.shown, c.warn)
		}
		if c.warn && !strings.HasPrefix(warn, "sweep-all: degraded: RSDD_SWEEP_TIMEOUT ") {
			t.Errorf("parseSweepTimeout(%q) warning %q is not the typed degraded line", c.raw, warn)
		}
	}
}

// recorder is a runner that notes every spec and answers each script with its canned result.
type recorder struct {
	specs []proc.Spec
	by    map[string]func() (proc.Result, error)
}

func (r *recorder) run(spec proc.Spec) (proc.Result, error) {
	r.specs = append(r.specs, spec)
	if f, ok := r.by[filepath.Base(spec.Argv[len(spec.Argv)-1])]; ok {
		return f()
	}
	return proc.Result{Stdout: []byte("ok\n")}, nil
}

// runWith runs the aggregator over a world of stubs with the runner and returns the output.
func (w *world) runWith(cfg allConfig) result {
	w.t.Helper()
	var o, e bytes.Buffer
	rc := sweepAll(w.kit+"/toolbelt", w.stdio(&o, &e), cfg)
	return result{o.String(), e.String(), rc}
}

// The subprocess list of the port (L29): eight children, in the canonical order, each `bash` run through the
// fd-merging wrapper with the script path as its only data argument, in the caller's directory, under the bound.
func TestAllSubprocessRecord(t *testing.T) {
	w := newWorld(t)
	w.stubs(nil)
	rec := &recorder{}
	r := w.runWith(allConfig{run: rec.run, maxBytes: 1234})
	if r.rc != 0 || r.err != "" {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
	if len(rec.specs) != 8 {
		t.Fatalf("%d subprocesses, want 8", len(rec.specs))
	}
	for i, spec := range rec.specs {
		name := allNames[i]
		want := []string{"bash", "-c", `exec 2>&1; exec bash "$1"`, "sweep-all", w.kit + "/toolbelt/" + name}
		if !slices.Equal(spec.Argv, want) {
			t.Errorf("subprocess %d argv = %q, want %q", i, spec.Argv, want)
		}
		if spec.Dir != w.root {
			t.Errorf("subprocess %d runs in %q, want the caller's directory %q", i, spec.Dir, w.root)
		}
		if spec.Timeout != 30*time.Second || spec.MaxBytes != 1234 || len(spec.Limits) != 0 {
			t.Errorf("subprocess %d bounds = %v / %d / %v, want 30s / 1234 / none", i, spec.Timeout, spec.MaxBytes, spec.Limits)
		}
	}
}

// The children get the caller's whole environment plus RSDD_BIN (kit.ShimEnv), so the shims they are skip the
// source-fingerprint check; a preset RSDD_BIN is kept as it is.
func TestAllChildEnvironment(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	exe, _ = filepath.EvalSymlinks(exe)
	count := func(env []string, prefix string) (n int) {
		for _, kv := range env {
			if strings.HasPrefix(kv, prefix) {
				n++
			}
		}
		return n
	}
	w := newWorld(t)
	w.stubs(nil)
	rec := &recorder{}
	w.runWith(allConfig{run: rec.run, maxBytes: allMaxBytes})
	env := rec.specs[0].Env
	if !slices.Contains(env, "RSDD_BIN="+exe) || count(env, "RSDD_BIN=") != 1 {
		t.Errorf("env has no single RSDD_BIN=%s: %q", exe, env)
	}
	if !slices.Contains(env, "PATH="+w.env["PATH"]) || !slices.Contains(env, "HOME="+w.env["HOME"]) {
		t.Errorf("env lost the caller's variables: %q", env)
	}

	w = newWorld(t)
	w.stubs(nil)
	w.env["RSDD_BIN"] = "/preset/rsdd"
	rec = &recorder{}
	w.runWith(allConfig{run: rec.run, maxBytes: allMaxBytes})
	if env := rec.specs[0].Env; !slices.Contains(env, "RSDD_BIN=/preset/rsdd") || count(env, "RSDD_BIN=") != 1 {
		t.Errorf("a preset RSDD_BIN was not kept: %q", env)
	}

	// A caller with no environment function still hands the children an explicit, non-nil environment.
	w = newWorld(t)
	w.stubs(nil)
	rec = &recorder{}
	var o, e bytes.Buffer
	s := w.stdio(&o, &e)
	s.Environ = func() []string { return nil }
	sweepAll(w.kit+"/toolbelt", s, allConfig{run: rec.run, maxBytes: allMaxBytes})
	if env := rec.specs[0].Env; env == nil {
		t.Errorf("the children got a nil environment")
	}
}

func TestAllReportsEveryKindOfFailure(t *testing.T) {
	w := newWorld(t)
	w.stubs(nil)
	boom := errors.New("boom")
	rec := &recorder{by: map[string]func() (proc.Result, error){
		allNames[0]: func() (proc.Result, error) { return proc.Result{Reason: proc.ReasonTimeout, ReturnCode: -9}, nil },
		allNames[1]: func() (proc.Result, error) {
			return proc.Result{Reason: proc.ReasonOutputCap, Stdout: []byte("cut")}, nil
		},
		allNames[2]: func() (proc.Result, error) { return proc.Result{ReturnCode: 124, Stdout: []byte("124\n")}, nil },
		allNames[3]: func() (proc.Result, error) { return proc.Result{ReturnCode: -11}, nil },
		allNames[4]: func() (proc.Result, error) { return proc.Result{}, &proc.SpawnError{Path: "bash", Err: boom} },
		allNames[5]: func() (proc.Result, error) { return proc.Result{}, proc.ErrInvalidSpec },
		allNames[6]: func() (proc.Result, error) { return proc.Result{ReturnCode: 0, Stdout: []byte("late\n")}, boom },
	}}
	r := w.runWith(allConfig{run: rec.run, maxBytes: 77})
	if r.rc != 1 || r.err != "" {
		t.Fatalf("rc=%d stderr=%q, want 1 and empty", r.rc, r.err)
	}
	for _, want := range []string{
		banner(allNames[0]) + "\nFAIL  " + allNames[0] + " (timed out after 30s)\n",
		banner(allNames[1]) + "cut\nFAIL  " + allNames[1] + " (output exceeded 77 bytes)\n",
		banner(allNames[2]) + "124\n\nFAIL  " + allNames[2] + " (exit 124)\n",
		"\nFAIL  " + allNames[3] + " (killed by signal 11)\n",
		"\nFAIL  " + allNames[4] + " (cannot start: boom)\n",
		"\nFAIL  " + allNames[5] + " (cannot run: proc: invalid spec)\n",
		banner(allNames[6]) + "late\n\nFAIL  " + allNames[6] + " (its process group could not be stopped: boom)\n",
		"\nPASS  " + allNames[7] + "\n",
		summaryHead + "  FAIL  " + allNames[0] + " (timed out)\n  FAIL  " + allNames[1] + " (output cap)\n  FAIL  " + allNames[2] + " (exit 124)\n" +
			"  FAIL  " + allNames[3] + " (signal 11)\n  FAIL  " + allNames[4] + " (cannot start)\n  FAIL  " + allNames[5] + " (cannot run)\n" +
			"  FAIL  " + allNames[6] + " (not stopped)\n  PASS  " + allNames[7] + "\n",
	} {
		if !strings.Contains(r.out, want) {
			t.Errorf("stdout lacks %q\nstdout:\n%s", want, r.out)
		}
	}
}

// RSDD_SWEEP_TIMEOUT reaches the bound of every run; a value that is not a positive number of seconds is the
// default plus one typed line on stderr, ahead of the first banner, and does not change the exit code.
func TestAllTimeoutReachesTheRunner(t *testing.T) {
	for _, c := range []struct {
		raw  string
		want time.Duration
		warn bool
	}{{"7", 7 * time.Second, false}, {"0.25", 250 * time.Millisecond, false}, {"", 30 * time.Second, false},
		{"abc", 30 * time.Second, true}, {"0", 30 * time.Second, true}, {"2m", 30 * time.Second, true}, {"-3", 30 * time.Second, true}} {
		w := newWorld(t)
		w.stubs(nil)
		w.env["RSDD_SWEEP_TIMEOUT"] = c.raw
		rec := &recorder{}
		r := w.runWith(allConfig{run: rec.run, maxBytes: allMaxBytes})
		for i, spec := range rec.specs {
			if spec.Timeout != c.want {
				t.Errorf("RSDD_SWEEP_TIMEOUT=%q: run %d bound %v, want %v", c.raw, i, spec.Timeout, c.want)
			}
		}
		if r.rc != 0 {
			t.Errorf("RSDD_SWEEP_TIMEOUT=%q: rc=%d, a bad timeout must not fail a passing sweep", c.raw, r.rc)
		}
		if got := strings.HasPrefix(r.err, "sweep-all: degraded: RSDD_SWEEP_TIMEOUT "); got != c.warn || (c.warn && strings.Count(r.err, "\n") != 1) {
			t.Errorf("RSDD_SWEEP_TIMEOUT=%q: stderr %q, want the single degraded line=%v", c.raw, r.err, c.warn)
		}
	}
}

// The command line: --kit needs a value (usage error), a relative kit is read against the caller's directory, and
// a run with no resolvable kit stops before any banner.
func TestAllCommandLine(t *testing.T) {
	w := newWorld(t)
	w.stubs(nil)

	var o, e bytes.Buffer
	if rc := cli.Run(Commands, []string{"sweep", "all", "--kit"}, w.stdio(&o, &e)); rc != cli.ExitUsage || o.Len() != 0 || e.String() != "sweep-all: --kit needs a directory\n" {
		t.Errorf("--kit without a value: rc=%d stdout=%q stderr=%q", rc, o.String(), e.String())
	}

	o.Reset()
	e.Reset()
	if rc := cli.Run(Commands, []string{"sweep", "all", "--kit", "kit", "ignored", "--json"}, w.stdio(&o, &e)); rc != 0 || !strings.Contains(o.String(), "PASS  "+allNames[7]+"\n") || e.Len() != 0 {
		t.Errorf("relative kit: rc=%d stderr=%q", rc, e.String())
	}

	w = newWorld(t) // no kit anywhere: HOME is an empty directory and RESEARCH_SDD_KIT is unset
	o.Reset()
	e.Reset()
	s := w.stdio(&o, &e)
	if rc := cli.Run(Commands, []string{"sweep", "all"}, s); rc != cli.ExitOperational || o.Len() != 0 || !strings.HasPrefix(e.String(), "sweep-all: ") {
		t.Errorf("no kit: rc=%d stdout=%q stderr=%q", rc, o.String(), e.String())
	}
}
