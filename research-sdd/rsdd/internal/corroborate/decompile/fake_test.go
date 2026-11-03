package decompile

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// fakeClock is the injected clock: only a simulated wait moves it, so nothing in these tests sleeps. It starts at
// the real time because the out-dir lives on a real file system and the freshness rules compare its mtimes.
type fakeClock struct{ now time.Time }

func (c *fakeClock) Now() time.Time          { return c.now }
func (c *fakeClock) advance(d time.Duration) { c.now = c.now.Add(d) }

// jarSpec is a fake archive: its entries, a symlink entry unzip would extract, and whether unzip warns (exit 1).
type jarSpec struct {
	entries []string
	symlink string
	warn    bool
}

// fakeTools is core/probe with the Java home pinned (resolving it would run a real `java -version`).
type fakeTools struct {
	*probe.Prober
	home string
	err  error
}

func (f fakeTools) JavaHome() (string, error) { return f.home, f.err }

// world is a JVM-free stand-in for java (the engines), unzip and javap. The engine is a Go port of the bash stub
// the old suite used: the same STUB_* knobs, read from the environment the command got.
type world struct {
	t         *testing.T
	root      string
	home      string
	java      string
	javap     string
	bin       string
	unzip     string
	tmp       string
	clock     *fakeClock
	jars      map[string]jarSpec
	env       map[string]string
	homeErr   error
	calls     []Cmd
	engineLog []string // "<engine> <in> <out>" per engine run, like the bash stub's STUB_LOG
	factsIn   []time.Duration
	facts     func(string, time.Duration, cli.Stdio) factsResult
	unzipRC   int // when set, the exit status of every unzip run
	javapOut  string
	listing   *string // when set, what `unzip -Z1` prints
	listingRC int
	hook      func(Cmd) (Result, bool) // scripts an engine run before the stub sees it
	deptmp    string                   // the injected default scratch parent (w.tmp when empty)
}

func newWorld(t *testing.T) *world {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w := &world{t: t, root: root, clock: &fakeClock{now: time.Now()}, jars: map[string]jarSpec{}}
	w.home, w.bin, w.tmp = filepath.Join(root, "java21"), filepath.Join(root, "bin"), filepath.Join(root, "tmp")
	for _, d := range []string{filepath.Join(w.home, "bin"), w.bin, w.tmp} {
		w.mkdir(d)
	}
	w.java, w.javap = w.exe(filepath.Join(w.home, "bin", "java")), w.exe(filepath.Join(w.home, "bin", "javap"))
	w.unzip = w.exe(filepath.Join(w.bin, "unzip"))
	w.exe(filepath.Join(w.bin, "timeout"))
	w.env = map[string]string{
		"PATH": w.bin, "TMPDIR": w.tmp, "RSDD_DECOMPILE_TIMEOUT": "1",
		"VINEFLOWER_JAR": w.touch("vineflower.jar"), "CFR_JAR": w.touch("cfr.jar"), "PROCYON_JAR": w.touch("procyon.jar"),
	}
	w.facts = func(_ string, budget time.Duration, _ cli.Stdio) factsResult {
		w.factsIn = append(w.factsIn, budget)
		return factsResult{line: "CLASSFILE major=52 lvt=yes classes=1 resugar_risk=no unreadable=0 partial=0 truncated=none"}
	}
	return w
}

func (w *world) mkdir(d string) {
	w.t.Helper()
	if err := os.MkdirAll(d, 0o755); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) write(p, content string) {
	w.t.Helper()
	w.mkdir(filepath.Dir(p))
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) exe(p string) string {
	w.t.Helper()
	w.write(p, "#!/bin/sh\n")
	if err := os.Chmod(p, 0o755); err != nil {
		w.t.Fatal(err)
	}
	return p
}

// touch creates an empty file under the world's root and returns its path.
func (w *world) touch(name string) string {
	w.t.Helper()
	p := filepath.Join(w.root, name)
	w.write(p, "")
	return p
}

// input registers an archive (or, with no entries, an empty file) and returns its path.
func (w *world) input(name string, spec jarSpec) string {
	p := w.touch(name)
	w.jars[p] = spec
	return p
}

func (w *world) environ() []string {
	var kv []string
	for k, v := range w.env {
		kv = append(kv, k+"="+v)
	}
	sort.Strings(kv)
	return kv
}

func (w *world) stdio() (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	var out, errb bytes.Buffer
	return cli.Stdio{Out: &out, Err: &errb, Cwd: w.root, Clock: w.clock.Now,
		Env: func(k string) string { return w.env[k] }, Environ: w.environ}, &out, &errb
}

// exec runs the command and returns what it printed.
func (w *world) exec(args ...string) (stdout, stderr string, rc int) {
	w.t.Helper()
	s, out, errb := w.stdio()
	d := deps{run: w.run, facts: func(in string, b time.Duration, st cli.Stdio) factsResult { return w.facts(in, b, st) },
		tools: fakeTools{Prober: probe.New(w.environ(), w.root), home: w.home, err: w.homeErr}, tmp: orStr(w.deptmp, w.tmp)}
	rc = execute(args, s, d)
	return out.String(), errb.String(), rc
}

func (w *world) run(c Cmd) Result {
	w.calls = append(w.calls, c)
	switch c.Argv[0] {
	case w.java:
		if w.hook != nil {
			if r, ok := w.hook(c); ok {
				return r
			}
		}
		return w.engine(c)
	case w.unzip:
		return w.runUnzip(c)
	case w.javap:
		return Result{Stdout: []byte(w.javapOut), RC: 5, Stderr: []byte("javap: boom\n")}
	}
	w.t.Fatalf("unexpected program %q", c.Argv[0])
	return Result{}
}

func (w *world) runUnzip(c Cmd) Result {
	if w.unzipRC != 0 {
		if c.Argv[1] != "-Z1" {
			w.mkdir(c.Argv[6]) // unzip -d makes its target even when it then fails
		}
		return Result{RC: w.unzipRC}
	}
	if c.Argv[1] == "-Z1" {
		if w.listing != nil {
			return Result{RC: w.listingRC, Stdout: []byte(*w.listing)}
		}
		return Result{Stdout: []byte(strings.Join(w.jars[underDir(c.Dir, c.Argv[2])].entries, "\n") + "\n")}
	}
	spec, ext := w.jars[underDir(c.Dir, c.Argv[3])], c.Argv[6]
	n := 0
	for _, e := range spec.entries {
		if strings.HasSuffix(e, ".class") {
			w.write(filepath.Join(ext, e), "x\n")
			n++
		}
	}
	if n == 0 {
		return Result{RC: 11}
	}
	if spec.symlink != "" {
		_ = os.Symlink("/nonexistent-target", filepath.Join(ext, spec.symlink))
	}
	if spec.warn {
		return Result{RC: 1}
	}
	return Result{}
}

// knob is a STUB_* setting.
func (w *world) knob(k string) string { return w.env[k] }

func (w *world) knobList(k string) []string { return strings.Fields(w.env[k]) }

func has(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// sleepFor simulates the engine sleeping: when the bound ends it first the clock moves by the bound (plus the
// grace when TERM is ignored) and the status is the one timeout(1) gives (124, or 137 after the KILL).
func (w *world) sleepFor(c Cmd, secs int, ignoreTerm bool) (Result, bool) {
	d := time.Duration(secs) * time.Second
	if c.Timeout > 0 && c.Timeout <= d {
		w.clock.advance(c.Timeout)
		if ignoreTerm {
			w.clock.advance(c.Grace)
			return Result{RC: statusKilled}, true
		}
		return Result{RC: statusTimeout}, true
	}
	w.clock.advance(d)
	return Result{}, false
}

func (w *world) sleepSecs() int {
	n := 3
	if v := w.knob("STUB_SLEEP"); v != "" {
		fmt.Sscan(v, &n)
	}
	return n
}

// classesOf is the list of class entries the engine is given.
func (w *world) classesOf(in string) []string {
	var cs []string
	switch {
	case isDir(in):
		cs = find(in, isClassName)
	case strings.HasSuffix(in, ".jar"):
		for _, e := range append([]string{w.jars[in].symlink}, w.jars[in].entries...) {
			if strings.HasSuffix(e, ".class") {
				cs = append(cs, e)
			}
		}
		sort.Strings(cs)
	default:
		r := in
		if _, after, ok := strings.Cut(in, "/ext/"); ok {
			r = after
		} else {
			r = filepath.Base(in)
		}
		cs = []string{r}
	}
	return cs
}

// engine is the Go port of the bash engine stub.
func (w *world) engine(c Cmd) Result {
	argv := c.Argv
	n := len(argv)
	jar := ""
	for i := 0; i < n-1; i++ {
		if argv[i] == "-jar" {
			jar = argv[i+1]
		}
	}
	eng, in, out := "unknown", argv[n-1], argv[n-1]
	switch {
	case strings.Contains(jar, "vineflower"):
		eng, in = "vineflower", argv[n-2]
	case strings.Contains(jar, "cfr"):
		eng, in = "cfr", argv[n-3]
	case strings.Contains(jar, "procyon"):
		eng = "procyon"
	}
	w.engineLog = append(w.engineLog, eng+" "+in+" "+out)
	in, out = underDir(c.Dir, in), underDir(c.Dir, out) // a child resolves relative paths against ITS directory
	classes := w.classesOf(in)
	if w.knob("STUB_LOG_CLASSES") != "" {
		w.engineLog = append(w.engineLog, "classes "+strings.Join(classes, " "))
	}
	vf := eng == "vineflower"
	isJar := strings.HasSuffix(in, ".jar")
	if rc := w.knob("STUB_VF_RC"); vf && rc != "" {
		var n int
		fmt.Sscan(rc, &n)
		return Result{RC: n}
	}
	if vf && w.knob("STUB_FAIL_WHOLE") != "" && isJar {
		return Result{RC: 1}
	}
	ncls := 0
	for _, cl := range classes {
		if !strings.Contains(cl, "$") {
			ncls++
		}
	}
	if w.knob("STUB_SILENT") != "" {
		return Result{}
	}
	if eng == "cfr" && w.knob("STUB_CFR_SLEEP") != "" {
		var s int
		fmt.Sscan(w.knob("STUB_CFR_SLEEP"), &s)
		if r, timedOut := w.sleepFor(c, s, false); timedOut {
			return r
		}
	}
	if eng == "cfr" && w.knob("STUB_CFR_UNIT_SLEEP") != "" && !isJar {
		var s int
		fmt.Sscan(w.knob("STUB_CFR_UNIT_SLEEP"), &s)
		if r, timedOut := w.sleepFor(c, s, false); timedOut {
			return r
		}
	}
	if m := w.knob("STUB_SLEEP_MIN"); vf && m != "" {
		var min int
		fmt.Sscan(m, &min)
		if ncls >= min {
			r, _ := w.sleepFor(c, w.sleepSecs(), false)
			return r
		}
	}
	if m := w.knob("STUB_EMPTY_MIN"); vf && m != "" && isDir(in) {
		var min int
		fmt.Sscan(m, &min)
		if ncls >= min {
			return Result{}
		}
	}
	if vf {
		for _, cl := range classes {
			b := strings.TrimSuffix(filepath.Base(cl), ".class")
			if has(w.knobList("STUB_SLEEP_CLASSES"), b) {
				if w.knob("STUB_IGNORE_TERM") != "" {
					r, _ := w.sleepFor(c, 20, true)
					return r
				}
				r, _ := w.sleepFor(c, w.sleepSecs(), false)
				return r
			}
		}
	}
	w.writeSources(eng, classes, out)
	return Result{}
}

// writeSources writes one .java per top-level class, like the stub: inner classes (any non-empty prefix before a '$'
// has a class beside it) are skipped, an omitted class is silently left out, markers go into marked classes.
func (w *world) writeSources(eng string, classes []string, out string) {
	list := map[string]bool{}
	for _, cl := range classes {
		list[cl] = true
	}
	for _, cl := range classes {
		b := strings.TrimSuffix(filepath.Base(cl), ".class")
		dn := filepath.Dir(cl)
		inner := false
		for k := 1; k < len(b); k++ {
			if b[k] == '$' && (list[dn+"/"+b[:k]+".class"] || list[b[:k]+".class"]) {
				inner = true
			}
		}
		if has(w.knobList("STUB_STANDALONE_CLASSES"), b) {
			inner = false
		}
		if inner || (eng == "vineflower" && has(w.knobList("STUB_OMIT_CLASSES"), b)) {
			continue
		}
		oc := cl
		if w.knob("STUB_STRIP_LAYOUT") != "" {
			oc = strings.TrimPrefix(strings.TrimPrefix(oc, "BOOT-INF/classes/"), "WEB-INF/classes/")
			if rest, ok := strings.CutPrefix(oc, "META-INF/versions/"); ok {
				_, oc, _ = strings.Cut(rest, "/")
			}
		}
		body := "// engine=" + eng + "\nclass " + b + " {\n"
		if eng == "vineflower" || w.knob("STUB_CFR_MARKER") != "" {
			text := w.knob("STUB_MARKER_TEXT")
			if text == "" {
				text = "    // $VF: Couldn't be decompiled"
			}
			if has(w.knobList("STUB_MARKER_CLASSES"), b) {
				body += text + "\n"
			}
		}
		p := filepath.Join(out, strings.TrimSuffix(oc, ".class")+".java")
		w.write(p, body+"}\n")
		mt := w.clock.Now()
		if v := w.knob("STUB_BACKDATE_OUT"); v != "" { // seconds before now, fractions allowed
			var secs float64
			fmt.Sscan(v, &secs)
			mt = mt.Add(-time.Duration(secs * float64(time.Second)))
		}
		if err := os.Chtimes(p, mt, mt); err != nil {
			w.t.Fatal(err)
		}
	}
	if extra := w.knob("STUB_EXTRA_MARKED"); eng == "vineflower" && extra != "" {
		w.write(filepath.Join(out, extra+".java"), "// engine=vineflower\nclass Ghost {\n    // $VF: Couldn't be decompiled\n}\n")
	}
	if w.knob("STUB_FORCE_JAVA") != "" {
		w.write(filepath.Join(out, "Forced.java"), "class Forced {}\n")
	}
}

// tree lists dir the way the golden captures do: "rel/" for a directory, "rel: <first line>" for a file.
func tree(t *testing.T, dir string) []string {
	t.Helper()
	var out []string
	walk(dir, func(rel string, d fs.DirEntry) {
		if d.IsDir() {
			out = append(out, rel+"/")
			return
		}
		b, err := os.ReadFile(filepath.Join(dir, rel))
		if err != nil {
			t.Fatal(err)
		}
		first, _, _ := strings.Cut(string(b), "\n")
		out = append(out, rel+": "+first)
	})
	sort.Strings(out)
	return orEmpty(out)
}

var fbRe = regexp.MustCompile(`W/(tmp\.[A-Za-z0-9]+|fb[0-9]+)`)

// norm rewrites the world's paths to the placeholders the goldens use.
func (w *world) norm(s, in, out string) string {
	s = strings.ReplaceAll(strings.ReplaceAll(s, out, "OUT"), in, "IN")
	s = regexp.MustCompile(regexp.QuoteMeta(w.tmp)+`/[^/ ]+/`).ReplaceAllString(s, "W/")
	return fbRe.ReplaceAllString(s, "W/FB")
}

func orStr(s, d string) string {
	if s != "" {
		return s
	}
	return d
}

// underDir resolves p the way a child process started in dir would.
func underDir(dir, p string) string {
	if filepath.IsAbs(p) || dir == "" {
		return p
	}
	return filepath.Join(dir, p)
}
