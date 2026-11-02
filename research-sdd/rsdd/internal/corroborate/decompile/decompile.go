// Package decompile is `rsdd corroborate decompile`: the port of toolbelt/decompile-java.sh (kit issues
// #1190, #1194, #1205, #1224, #1320, #1358; ported by #2419). The script's header remains the contract: the typed
// OK / DEGRADED / PARTIAL result and its UNIT lines on stdout, the CLASSFILE line and the reconstruction warning
// on stderr, exit 0 / 1 / 2 / 3 / 4.
//
// Every decision about time is made from an injected clock and an injected process runner (core/proc in
// production), so a test settles a timeout, a kill-after or an isolation budget without sleeping. Deliberate
// differences from the bash script:
//   - the engines are bounded by the process runner (TERM, then KILL after RSDD_KILL_AFTER) instead of
//     timeout(1): the statuses are the same (124 stopped, 137 killed). RSDD_TIMEOUT_BIN still names the binary
//     whose absence is the typed timeout-unavailable / facts-unbounded state, although nothing runs it;
//   - the class-file facts are read in process (internal/corroborate/classfile) under their own budget; there is
//     no Python fallback and no binary to resolve, so reason=facts-unavailable no longer exists;
//   - an engine's output is captured to a cap of 64 MiB and then passed through; a run cut at the cap is an
//     error, never a success;
//   - units found by the marker scan are processed in sorted order, not in directory order;
//   - a missing positional argument or option value exits 1 with a plain message, where bash printed
//     "line N: 1: ..."; integer settings are read as decimal (bash arithmetic read a leading 0 as octal);
//   - packages and classes are walked in byte order whatever the locale.
package decompile

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/classfile"
)

const (
	exitFailed   = 1
	exitUsage    = 2
	exitNoTool   = 3
	exitDegraded = 4

	usageLine = "usage: decompile-java.sh <in.jar|in.class> <out-dir> [--engine vineflower|cfr|procyon] [--jar path] [--thread-count N] [--timeout SECONDS] [--fallback-engine cfr|procyon|vineflower|none]\n       decompile-java.sh --javap <Class.class>\n"

	reconstructionWarning = "WARN: decompiled source is a reconstruction; syntax-level claims (string concatenation, lambdas, switch, records, generics) need bytecode evidence (javap -c -p, see --javap), not the decompiled text"
	classfileUnknown      = "CLASSFILE major=unknown lvt=unknown classes=unknown resugar_risk=unknown unreadable=unknown partial=unknown truncated=unknown"
)

var (
	secondsRe   = regexp.MustCompile(`^[0-9]{1,6}$`)
	killAfterRe = regexp.MustCompile(`^[1-9][0-9]{0,3}$`)
	threadsRe   = regexp.MustCompile(`^[1-9][0-9]{0,3}$`)
	heapRe      = regexp.MustCompile(`^[1-9][0-9]{0,5}[mMgG]$`)
)

// tools resolves the Java installation and the tools around it (core/probe in production).
type tools interface {
	JavaHome() (string, error)
	JavaJar(name string) (string, error)
	LookPath(name string) (string, error)
}

// deps are the process boundaries of a run.
type deps struct {
	run   runner
	facts func(in string, budget time.Duration, s cli.Stdio) factsResult
	tools tools
	tmp   string // scratch parent when TMPDIR is empty
}

// defaultTmp is where the scratch directory goes when TMPDIR is unset.
const defaultTmp = "/tmp"

// Run is the Main contract of `rsdd corroborate decompile`.
func Run(args []string, s cli.Stdio) int {
	return execute(args, s, deps{
		run:   newProcRunner(proc.Run),
		facts: newFactsRunner(classfile.Run, time.After),
		tools: probe.New(s.Environ(), s.Cwd),
		tmp:   defaultTmp,
	})
}

// config is the validated command line and environment.
type config struct {
	in, out, engine, fallback, jarOverride, threadCount string
	unzipBin, timeoutBin                                string
	javaArgs                                            []string
	timeout, isolateBudget, killAfter                   int // seconds
}

// job is one decompilation.
type job struct {
	cfg         config
	s           cli.Stdio
	d           deps
	java        string
	haveTimeout bool // the timeout binary exists; its absence is a typed degraded state
	stamp       time.Time
	pre         map[string]time.Time // files inside the stamp's backdate window when the run began
	work, ext   string

	units          []unit
	partial        int
	handled        map[string]bool // units already recorded (the marker scan must not re-handle them)
	probeDegraded  []string
	primaryState   string
	isolationLevel string
	isolationWhy   string // set when isolation could not run (typed, reported on the unit)
	sweepWhy       string // why the coverage sweep could not run
	resources      string // non-class jar entries the failure path did not copy: N or unknown
	isolating      bool   // run_engine clamps each run to the remaining isolation budget
	isoT0          time.Time
}

// cmd is a Cmd running prog in the caller's environment and directory.
func (j *job) cmd(prog string, args ...string) Cmd {
	return Cmd{Argv: append([]string{prog}, args...), Dir: j.s.Cwd, Env: j.s.Environ()}
}

func (j *job) degrade(token string) { j.probeDegraded = append(j.probeDegraded, token) }

// cliError is a rejected command line: the message goes to stderr, code is the exit status.
type cliError struct {
	code int
	msg  string
}

func execute(args []string, s cli.Stdio, d deps) (code int) {
	defer func() {
		if r := recover(); r != nil {
			f, ok := r.(fatal)
			if !ok {
				panic(r)
			}
			fmt.Fprintf(s.Err, "rsdd: decompile-java: %v\n", f.err)
			code = exitFailed
		}
	}()
	home, err := d.tools.JavaHome()
	if err != nil {
		fmt.Fprintln(s.Err, "Java 21 not usable (set JAVA_HOME or RESEARCH_SDD_JAVA_HOME)")
		return exitNoTool
	}
	java, ok := canonical(filepath.Join(home, "bin", "java"))
	if !ok {
		fmt.Fprintln(s.Err, "Java launcher is not a canonical executable")
		return exitNoTool
	}
	j := &job{s: s, d: d, java: java, handled: map[string]bool{}, resources: "0"}
	if len(args) > 0 && args[0] == "--javap" {
		return j.javap(home, args[1:])
	}
	cfg, cerr := parseConfig(args, s.Env)
	if cerr != nil {
		fmt.Fprintln(s.Err, cerr.msg)
		return cerr.code
	}
	j.cfg = cfg
	return j.run()
}

// javap prints signatures and bytecode: javap -p -c <class>.
func (j *job) javap(home string, args []string) int {
	javap, ok := canonical(filepath.Join(home, "bin", "javap"))
	if !ok {
		fmt.Fprintln(j.s.Err, "javap launcher is not a canonical executable")
		return exitNoTool
	}
	if len(args) == 0 || args[0] == "" {
		fmt.Fprint(j.s.Err, usageLine)
		return exitFailed
	}
	res := j.d.run(j.cmd(javap, "-p", "-c", args[0]))
	_, _ = j.s.Out.Write(res.Stdout)
	_, _ = j.s.Err.Write(res.Stderr)
	return res.RC
}

// optionValue names the option values and their "required" message, which the script printed for a missing value.
var optionValue = map[string]string{
	"--engine": "engine required", "--jar": "jar required", "--timeout": "timeout required",
	"--fallback-engine": "fallback engine required", "--thread-count": "thread count required",
}

// parseConfig validates the command line and the environment, in the order the script did.
func parseConfig(args []string, env func(string) string) (config, *cliError) {
	bad := func(code int, msg string) (config, *cliError) { return config{}, &cliError{code, msg} }
	orDefault := func(key, def string) string {
		if v := env(key); v != "" {
			return v
		}
		return def
	}
	if len(args) < 2 || args[0] == "" || args[1] == "" {
		return bad(exitFailed, strings.TrimSuffix(usageLine, "\n"))
	}
	c := config{in: args[0], out: args[1], engine: "vineflower", unzipBin: orDefault("RSDD_UNZIP_BIN", "unzip"), timeoutBin: orDefault("RSDD_TIMEOUT_BIN", "timeout")}
	timeout, budget, killAfter := orDefault("RSDD_DECOMPILE_TIMEOUT", "240"), orDefault("RSDD_DECOMPILE_ISOLATE_BUDGET", "1800"), orDefault("RSDD_KILL_AFTER", "5")
	targets := map[string]*string{"--engine": &c.engine, "--jar": &c.jarOverride, "--timeout": &timeout, "--fallback-engine": &c.fallback, "--thread-count": &c.threadCount}
	for rest := args[2:]; len(rest) > 0; rest = rest[2:] {
		dst, known := targets[rest[0]]
		switch {
		case !known:
			return bad(exitUsage, "unknown option: "+rest[0])
		case len(rest) < 2 || rest[1] == "":
			return bad(exitFailed, optionValue[rest[0]])
		}
		*dst = rest[1]
		if rest[0] == "--thread-count" && !threadsRe.MatchString(c.threadCount) {
			return bad(exitUsage, "invalid thread count")
		}
	}
	switch {
	case !secondsRe.MatchString(timeout):
		return bad(exitUsage, "invalid timeout (seconds, 0 = unbounded)")
	case !secondsRe.MatchString(budget):
		return bad(exitUsage, "invalid RSDD_DECOMPILE_ISOLATE_BUDGET (seconds, 0 = unlimited)")
	case !killAfterRe.MatchString(killAfter):
		return bad(exitUsage, "invalid RSDD_KILL_AFTER")
	case c.engine != "vineflower" && c.engine != "cfr" && c.engine != "procyon":
		return bad(exitUsage, fmt.Sprintf("unknown engine: %s (use vineflower|cfr|procyon)", c.engine))
	}
	c.timeout, _ = strconv.Atoi(timeout)
	c.isolateBudget, _ = strconv.Atoi(budget)
	c.killAfter, _ = strconv.Atoi(killAfter)
	if c.fallback == "" {
		c.fallback = "cfr"
		if c.engine == "cfr" {
			c.fallback = "procyon"
		}
	}
	if c.fallback != "vineflower" && c.fallback != "cfr" && c.fallback != "procyon" && c.fallback != "none" {
		return bad(exitUsage, "unknown fallback engine: "+c.fallback)
	}
	if heap := env("RSDD_DECOMPILE_MAX_HEAP"); heap != "" {
		if !heapRe.MatchString(heap) {
			return bad(exitUsage, "invalid RSDD_DECOMPILE_MAX_HEAP")
		}
		c.javaArgs = []string{"-Xmx" + heap}
	}
	// A trailing slash would make the freshness snapshot and the marker scan's prefix strip disagree: normalise once.
	for len(c.out) > 1 && strings.HasSuffix(c.out, "/") {
		c.out = strings.TrimSuffix(c.out, "/")
	}
	return c, nil
}

// run is the decompilation itself, after the command line is accepted.
func (j *job) run() int {
	cfg := &j.cfg
	if err := os.MkdirAll(j.outDir(), 0o755); err != nil {
		fmt.Fprintf(j.s.Err, "rsdd: decompile-java: %v\n", err)
		return exitFailed
	}
	// Runtime-dependency probe: a missing timeout binary is a typed degraded state, never a silent unbounded run
	// presented as OK.
	_, terr := j.d.tools.LookPath(cfg.timeoutBin)
	j.haveTimeout = terr == nil
	if cfg.timeout > 0 && !j.haveTimeout {
		j.degrade("timeout-unavailable")
		fmt.Fprintf(j.s.Err, "WARN: '%s' not found; engines run UNBOUNDED (typed degraded)\n", cfg.timeoutBin)
		cfg.timeout = 0
	}
	// Fail fast (exit 3) when the PRIMARY engine cannot run at all.
	if jar, err := j.engineJar(cfg.engine); err != nil || !isFile(j.path(jar)) {
		fmt.Fprintf(j.s.Err, "%s jar not found (set %s_JAR)\n", cfg.engine, strings.ToUpper(cfg.engine))
		return exitNoTool
	}
	j.classfileHeader()
	fmt.Fprintln(j.s.Err, reconstructionWarning)

	base := j.d.tmp
	if t := j.s.Env("TMPDIR"); t != "" {
		base = t
	}
	work, err := os.MkdirTemp(j.path(base), "decompile-java.")
	if err != nil {
		fmt.Fprintf(j.s.Err, "rsdd: decompile-java: %v\n", err)
		return exitFailed
	}
	defer os.RemoveAll(work)
	j.work, j.ext = work, filepath.Join(work, "ext")
	// Backdate the run stamp 2 s: a coarse-mtime filesystem can stamp this run's own output a moment BEFORE the
	// stamp, and a strictly-newer test would then call fresh output stale. The backdate has a side effect: a file
	// already sitting in a REUSED out-dir that was modified inside that window looks fresh. Snapshot those
	// ambiguous files before any engine runs; isFresh then treats one as this run's only if its mtime changed.
	j.stamp = j.s.Clock().Add(-2 * time.Second)
	j.pre = map[string]time.Time{}
	walk(j.outDir(), func(rel string, d fs.DirEntry) {
		fi, err := d.Info()
		if err != nil {
			return
		}
		if fi.ModTime().After(j.stamp) {
			j.pre[filepath.Join(j.outDir(), rel)] = fi.ModTime()
		}
	})

	if j.decompile() {
		return exitFailed
	}
	return j.report()
}

// path is p for the file system: a relative path is relative to the command's working directory (the one the
// children run in), not to the process's. Messages keep the path as the user gave it.
func (j *job) path(p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(j.s.Cwd, p)
}

// outDir is the out-dir for the file system.
func (j *job) outDir() string { return j.path(j.cfg.out) }

// decompile runs the primary engine and the recoveries. failed is true when the run ended without a report.
func (j *job) decompile() (failed bool) {
	cfg := &j.cfg
	isJar := strings.HasSuffix(strings.ToLower(cfg.in), ".jar")
	noScan := false // a whole-input fallback's output is final: never re-scan the fallback engine's files
	switch rc := j.runEngine(cfg.engine, cfg.in, cfg.out); {
	case rc != 0:
		reason := reasonOf(rc)
		j.primaryState = reason
		j.discardRunOutput() // a killed/failed run's partial output is untrustworthy
		if !isJar {
			j.fallbackUnit(j.unitName(), reason, cfg.in, "")
			break
		}
		j.countResources()
		irc := j.isolateJar()
		j.isolating = false // later runs (whole-artifact fallback, marker scan) are not budget-clamped
		switch irc {
		case 1:
			noScan = true
			j.fallbackUnit(j.unitName(), reason, cfg.in, j.isolationWhy)
		case 2: // budget exhausted: discard the half-isolated state; the whole artifact falls back, typed
			noScan = true
			j.isolationLevel, j.units, j.partial, j.handled = "", nil, 0, map[string]bool{}
			j.discardRunOutput()
			j.fallbackUnit(j.unitName(), "total_budget_exhausted", cfg.in, "")
		}
	case !hasJava(j.outDir()):
		// All three engines return 0 for obfuscated/empty/unsupported input without writing any source.
		fmt.Fprintf(j.s.Err, "WARN: %s decompiler exited 0 but produced no .java files in %s (input may be obfuscated or unsupported)\n", cfg.engine, cfg.out)
		return true
	case isJar:
		// Whole-jar success: still prove every unit class has output. When the sweep cannot run that is a typed
		// degraded state, never a silent OK; a spent budget is typed too and the good primary output is kept.
		if !j.ensureExt() {
			j.degrade(j.sweepWhy)
			break
		}
		j.isoT0, j.isolating = j.s.Clock(), true
		src := j.sweepCoverage()
		j.isolating = false
		if src == 2 {
			j.degrade("total_budget_exhausted")
		}
	}
	if !noScan {
		j.scanMarkers()
	}
	return false
}

// report prints the typed result: OK only when no unit fell back and nothing was degraded.
func (j *job) report() int {
	cfg := &j.cfg
	if len(j.units) == 0 && len(j.probeDegraded) == 0 && j.primaryState == "" {
		fmt.Fprintf(j.s.Out, "OK: %s -> %s  (engine=%s)\n", cfg.in, cfg.out, cfg.engine)
		return 0
	}
	status := "DEGRADED"
	if j.partial > 0 {
		status = "PARTIAL"
	}
	detail := fmt.Sprintf("units=%d", len(j.units))
	if j.primaryState != "" {
		detail += " primary=" + j.primaryState
		if j.isolationLevel != "" {
			detail += " isolation=" + j.isolationLevel
		}
	}
	if j.resources != "0" {
		detail += " resources_not_copied=" + j.resources
	}
	if len(j.probeDegraded) > 0 {
		detail += " reason=" + strings.Join(j.probeDegraded, ",")
	}
	fmt.Fprintf(j.s.Out, "%s: %s -> %s  (engine=%s %s)\n", status, cfg.in, cfg.out, cfg.engine, detail)
	for _, u := range j.units {
		fmt.Fprintf(j.s.Out, "UNIT: %s reason=%s fallback=%s result=%s", u.name, u.reason, u.fallback, u.result)
		if u.note != "" {
			fmt.Fprint(j.s.Out, " "+u.note)
		}
		fmt.Fprintln(j.s.Out)
	}
	if !hasJava(j.outDir()) {
		fmt.Fprintf(j.s.Err, "WARN: no .java files produced in %s\n", cfg.out)
		return exitFailed
	}
	return exitDegraded
}
