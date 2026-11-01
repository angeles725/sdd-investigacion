// Package fidelity is `rsdd corroborate java-fidelity`: the port of toolbelt/java-fidelity-experiment.sh
// (kit issue #1488, ported by #2419).
//
// The experiment compiles tiny Java fixtures with javac, decompiles each class through the kit wrapper
// (decompile-java.sh), recompiles the decompiled source and compares the normalised `javap -c -p` of the original
// and the recompiled class, once with -g and once without. The full contract (verdict lines, DEBUGINFO, RESULT,
// exit codes 0/1/2/4, RSDD_FIDELITY_* variables) is the header of the legacy script, embedded as help.txt and
// printed by -h.
//
// javac, javap and the wrapper are run through an injected Runner, so every decision of the experiment is
// testable without a JVM. Deliberate differences from the bash script, none of them visible in a verdict line:
//   - the wrapper is bounded by the process runner (core/proc) instead of `timeout`, so a run never prints the
//     legacy " timeout=unavailable" note; a bound hit is still status 124;
//   - a tool's log file holds its stdout followed by its stderr, not the interleaving a shared pipe gives;
//   - javac and javap are bounded too (one hour), where the script waited for them without limit;
//   - an unstartable program reads as status 127, with the reason in the log, instead of the shell's message.
package fidelity

import (
	_ "embed"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

//go:embed help.txt
var helpText string

// Exit statuses of the legacy script (4 is its DEGRADED code, kept for byte parity; see the package doc).
const (
	exitEmptyFixtures = 1
	exitDegraded      = 4
)

const (
	usageLine      = "usage: java-fidelity-experiment.sh [--fixtures DIR] [--work DIR]\n"
	defaultTimeout = 720
	toolBound      = time.Hour
)

var timeoutRe = regexp.MustCompile(`^[1-9][0-9]{0,5}$`)

// Cmd is one external program run.
type Cmd struct {
	Argv    []string
	Dir     string
	Env     []string
	Timeout time.Duration
}

// Result is what a run produced: the exit status (124 = the bound was hit) and stdout followed by stderr.
type Result struct {
	RC     int
	Output []byte
}

// Runner runs one external program.
type Runner func(Cmd) Result

type deps struct {
	run Runner
	tmp string // scratch parent when TMPDIR is empty
}

// Run is the Main contract of `rsdd corroborate java-fidelity`.
func Run(args []string, s cli.Stdio) int { return execute(args, s, deps{run: procRun, tmp: "/tmp"}) }

type experiment struct {
	s    cli.Stdio
	d    deps
	work string

	javac, javap, decompiler string
	timeout                  time.Duration

	engines                      []string
	nFallback, nGood, nDiv, nBad int
}

func execute(args []string, s cli.Stdio, d deps) int {
	var fixtures, work, toolbelt string
	fixturesSet := false
	for i := 0; i < len(args); {
		a := args[i]
		switch a {
		case "--fixtures", "--work", "--toolbelt":
			if len(args)-i < 2 {
				fmt.Fprintf(s.Err, "usage: %s needs a directory\n", a)
				return cli.ExitUsage
			}
			switch v := args[i+1]; a {
			case "--fixtures":
				fixtures, fixturesSet = v, true
			case "--work":
				work = v
			default:
				toolbelt = v
			}
			i += 2
		case "-h", "--help":
			_, _ = io.WriteString(s.Out, helpText)
			return cli.ExitOK
		default:
			fmt.Fprint(s.Err, usageLine)
			return cli.ExitUsage
		}
	}
	e := &experiment{s: s, d: d}

	if !fixturesSet {
		tb, err := toolbeltDir(toolbelt, s)
		if err != nil {
			fmt.Fprintln(s.Err, err)
			return cli.ExitUsage
		}
		fixtures = tb + "/tests/fixtures/java-fidelity-experiment"
	}
	if fi, err := os.Stat(e.at(fixtures)); err != nil || !fi.IsDir() {
		fmt.Fprintf(s.Err, "fixtures directory not found: %s\n", fixtures)
		return cli.ExitUsage
	}
	srcs := javaFiles(e.at(fixtures))
	if len(srcs) == 0 {
		fmt.Fprintf(s.Err, "no fixtures: %s holds no *.java (nothing measured)\n", fixtures)
		return exitEmptyFixtures
	}

	secs, ok := timeoutSecs(s)
	if !ok {
		v, _ := lookupEnv(s, "RSDD_FIDELITY_TIMEOUT")
		fmt.Fprintf(s.Err, "usage: RSDD_FIDELITY_TIMEOUT must be a positive integer (seconds), got '%s'\n", v)
		return cli.ExitUsage
	}
	e.timeout = time.Duration(secs) * time.Second

	e.javac = e.tool("RSDD_FIDELITY_JAVAC", "javac")
	e.javap = e.tool("RSDD_FIDELITY_JAVAP", "javap")
	e.decompiler = s.Env("RSDD_FIDELITY_DECOMPILER")
	if e.decompiler == "" {
		tb, err := toolbeltDir(toolbelt, s)
		if err != nil {
			fmt.Fprintln(s.Err, err)
			return cli.ExitUsage
		}
		e.decompiler = tb + "/decompile-java.sh"
	}
	if !e.usable(e.javac) {
		return e.degraded("javac-missing", "(no usable javac; set RSDD_FIDELITY_JAVAC or put a JDK on PATH)")
	}
	if !e.usable(e.javap) {
		return e.degraded("javap-missing", "(no usable javap; set RSDD_FIDELITY_JAVAP or put a JDK on PATH)")
	}
	if !e.usable(e.decompiler) {
		return e.degraded("decompiler-missing", "("+e.decompiler+" is not executable)")
	}

	if work == "" {
		parent := s.Env("TMPDIR")
		if parent == "" {
			parent = d.tmp
		}
		dir, err := os.MkdirTemp(e.at(parent), "tmp.")
		if err != nil {
			fmt.Fprintln(s.Err, "cannot create a scratch directory")
			return cli.ExitUsage
		}
		defer os.RemoveAll(dir)
		work = dir
	} else if err := os.MkdirAll(e.at(work), 0o755); err != nil {
		fmt.Fprintf(s.Err, "cannot create --work directory: %s\n", work)
		return cli.ExitUsage
	}
	e.work = work

	jdk := jdkVersion(e.exec(e.javac, "-version").Output)
	for _, src := range srcs {
		name := strings.TrimSuffix(filepath.Base(src), ".java")
		if name == "" {
			name = filepath.Base(src)
		}
		if e.cell(name, src, "g", []string{"-g"}) || e.cell(name, src, "nog", nil) {
			return exitDegraded
		}
		fmt.Fprintf(s.Out, "DEBUGINFO %s g_lvt=%s nog_lvt=%s\n", name, e.lvtPresent(name, "g"), e.lvtPresent(name, "nog"))
	}
	engines := "unknown"
	if len(e.engines) > 0 {
		engines = strings.Join(e.engines, ",")
	}
	fmt.Fprintf(s.Out, "RESULT: DONE jdk=%s engines=%s engine_degraded_cells=%d constructs=%d cells=%d good=%d diverged=%d failed=%d\n",
		jdk, engines, e.nFallback, len(srcs), e.nGood+e.nDiv+e.nBad, e.nGood, e.nDiv, e.nBad)
	return cli.ExitOK
}

// degraded prints the typed DEGRADED line and returns its exit status. A degrade after some cells were measured
// says so: those lines are valid, the run is incomplete.
func (e *experiment) degraded(reason, detail string) int {
	if done := e.nGood + e.nDiv + e.nBad; done > 0 {
		fmt.Fprintf(e.s.Out, "DEGRADED: reason=%s %s partial_cells=%d (FIDELITY lines above are valid; the run is INCOMPLETE, no RESULT line)\n", reason, detail, done)
	} else {
		fmt.Fprintf(e.s.Out, "DEGRADED: reason=%s %s\n", reason, detail)
	}
	return exitDegraded
}

// at anchors a relative path at the working directory the command was started in.
func (e *experiment) at(p string) string {
	if p == "" || filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(e.s.Cwd, p)
}

// tool is `${OVERRIDE:-$(command -v name)}`: the override when set, else what PATH resolves, else "".
func (e *experiment) tool(override, name string) string {
	if v := e.s.Env(override); v != "" {
		return v
	}
	p, _ := probe.New(environOf(e.s), e.s.Cwd).LookPath(name) // a miss is ("", error): "" reads as missing
	return p
}

// usable is `[ -f P ] && [ -x P ]`.
func (e *experiment) usable(p string) bool { return usableTool(e.s.Cwd, p) }

func (e *experiment) exec(prog string, args ...string) Result {
	return e.run(prog, toolBound, args...)
}

func (e *experiment) run(prog string, bound time.Duration, args ...string) Result {
	return e.d.run(Cmd{Argv: append([]string{prog}, args...), Dir: e.s.Cwd, Env: environOf(e.s), Timeout: bound})
}

func environOf(s cli.Stdio) []string {
	if s.Environ == nil {
		return nil
	}
	return s.Environ()
}

// lookupEnv is "is KEY set, and to what": Stdio.Env cannot tell unset from empty, the environment list can.
func lookupEnv(s cli.Stdio, key string) (string, bool) {
	if s.Environ == nil {
		v := s.Env(key)
		return v, v != ""
	}
	val, found := "", false
	for _, kv := range s.Environ() {
		if k, v, ok := strings.Cut(kv, "="); ok && k == key {
			val, found = v, true
		}
	}
	return val, found
}

// timeoutSecs is `${RSDD_FIDELITY_TIMEOUT-720}` validated as a positive integer of at most six digits. Unset
// means the default; set but empty is invalid.
func timeoutSecs(s cli.Stdio) (int, bool) {
	v, set := lookupEnv(s, "RSDD_FIDELITY_TIMEOUT")
	if !set {
		return defaultTimeout, true
	}
	if !timeoutRe.MatchString(v) {
		return 0, false
	}
	n, err := strconv.Atoi(v)
	return n, err == nil
}

// toolbeltDir is the directory holding decompile-java.sh and tests/fixtures: --toolbelt, else the resolved kit's.
func toolbeltDir(flagValue string, s cli.Stdio) (string, error) {
	if flagValue != "" {
		return flagValue, nil
	}
	p, _, err := kit.ResolveKitScript("toolbelt/decompile-java.sh", kit.Getenv(s.Env))
	if err != nil {
		return "", fmt.Errorf("cannot resolve the toolbelt directory (pass --toolbelt DIR or set RESEARCH_SDD_KIT): %w", err)
	}
	return filepath.Dir(p), nil
}

// jdkVersion reads the first complete "javac <digit>..." line of `javac -version` output (JVM notices may come
// first); a final fragment without a newline is not a line, as for `read`. Nothing is guessed.
func jdkVersion(out []byte) string {
	s := string(out)
	for {
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			return "unknown"
		}
		line := s[:i]
		s = s[i+1:]
		if v, ok := strings.CutPrefix(line, "javac "); ok && v != "" && v[0] >= '0' && v[0] <= '9' {
			return v
		}
	}
}
