package fidelity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const wantUsage = "usage: java-fidelity-experiment.sh [--fixtures DIR] [--work DIR]\n"

// TestUsage: argument errors are rc 2 on stderr with nothing on stdout, and -h prints the whole header block.
func TestUsage(t *testing.T) {
	cases := []struct {
		name string
		args []string
		err  string
	}{
		{"unknown flag", []string{"--bogus"}, wantUsage},
		{"stray positional", []string{"extra"}, wantUsage},
		{"fixtures needs a value", []string{"--fixtures"}, "usage: --fixtures needs a directory\n"},
		{"work needs a value", []string{"--work"}, "usage: --work needs a directory\n"},
		{"toolbelt needs a value", []string{"--toolbelt"}, "usage: --toolbelt needs a directory\n"},
		{"unknown after valid", []string{"--work", "w", "--bogus"}, wantUsage},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			out, errs, rc := w.exec(c.args)
			if rc != 2 || out != "" || errs != c.err {
				t.Fatalf("rc=%d out=%q err=%q", rc, out, errs)
			}
		})
	}
}

func TestHelp(t *testing.T) {
	want, err := os.ReadFile("help.txt")
	if err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"-h"}, {"--help"}, {"--work", "x", "-h", "--bogus"}} {
		w := newWorld(t)
		out, errs, rc := w.exec(args)
		if rc != 0 || errs != "" || out != string(want) {
			t.Fatalf("%q: rc=%d err=%q out differs from help.txt", args, rc, errs)
		}
	}
	for _, frag := range []string{"# java-fidelity-experiment.sh — the reproducible experiment", "# Limits (stated, not hidden)", "#   java-fidelity-experiment.sh [--fixtures DIR] [--work DIR]"} {
		if !strings.Contains(string(want), frag) {
			t.Errorf("help text lacks %q", frag)
		}
	}
	if strings.Contains(string(want), "set -uo pipefail") {
		t.Error("help text must stop before the script body")
	}
}

// TestFixturesStates: absent (rc 2), empty (rc 1) and non-regular entries stay three distinct states (tooth F).
func TestFixturesStates(t *testing.T) {
	w := newWorld(t)
	out, errs, rc := w.exec([]string{"--fixtures", filepath.Join(w.root, "absent")})
	if rc != 2 || out != "" || errs != "fixtures directory not found: "+filepath.Join(w.root, "absent")+"\n" {
		t.Errorf("absent: rc=%d out=%q err=%q", rc, out, errs)
	}
	out, errs, rc = w.exec([]string{"--fixtures", ""})
	if rc != 2 || errs != "fixtures directory not found: \n" {
		t.Errorf("empty value: rc=%d out=%q err=%q", rc, out, errs)
	}
	// empty: no *.java; a directory named X.java, a symlink to a file, and a non-java file do not count.
	if err := os.Mkdir(filepath.Join(w.fix, "Dir.java"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(w.fix, "notes.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(w.fix, "notes.txt"), filepath.Join(w.fix, "Link.java")); err != nil {
		t.Fatal(err)
	}
	out, errs, rc = w.exec([]string{"--fixtures", w.fix})
	if rc != 1 || out != "" || errs != "no fixtures: "+w.fix+" holds no *.java (nothing measured)\n" {
		t.Errorf("empty: rc=%d out=%q err=%q", rc, out, errs)
	}
	// A fixture in a subdirectory is not found (maxdepth 1); a hidden one is.
	if err := os.WriteFile(filepath.Join(w.fix, ".Hidden.java"), []byte("class H { 1 }"), 0o644); err != nil {
		t.Fatal(err)
	}
	w.decs[".Hidden"] = copyDec(okOut, 0)
	out, _, rc = w.exec(w.args())
	if rc != 0 || !strings.Contains(out, "constructs=1 cells=2") {
		t.Errorf("hidden fixture: rc=%d\n%s", rc, out)
	}
}

// TestFixturesAreSortedByName: the run order is the byte order of the file names.
func TestFixturesAreSortedByName(t *testing.T) {
	w := newWorld(t)
	for _, n := range []string{"b", "B", "a", "_z"} {
		w.fixture(n, "class "+n+" { 1 }")
		w.decs[n] = copyDec(okOut, 0)
	}
	out, _, _ := w.exec(w.args())
	var order []string
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "DEBUGINFO ") {
			order = append(order, strings.Fields(l)[1])
		}
	}
	if got := strings.Join(order, ","); got != "B,_z,a,b" {
		t.Fatalf("order %s", got)
	}
}

// TestTimeoutValidation: junk is rc 2 (tooth L); the check comes after the fixtures checks and before any probe.
func TestTimeoutValidation(t *testing.T) {
	bad := []string{"abc", "0", "-5", "1.5", "", "01", "1000000", "+3", " 3", "3 ", "1e3"}
	for _, v := range bad {
		w := newWorld(t)
		w.fixture("X", "class X { 1 }")
		out, errs, rc := w.exec(w.args(), "RSDD_FIDELITY_TIMEOUT="+v)
		want := "usage: RSDD_FIDELITY_TIMEOUT must be a positive integer (seconds), got '" + v + "'\n"
		if rc != 2 || out != "" || errs != want {
			t.Errorf("%q: rc=%d out=%q err=%q", v, rc, out, errs)
		}
	}
	for _, v := range []string{"1", "9", "10", "720", "999999"} {
		w := newWorld(t)
		w.fixture("X", "class X { 1 }")
		w.decs["X"] = copyDec(okOut, 0)
		if _, _, rc := w.exec(w.args(), "RSDD_FIDELITY_TIMEOUT="+v); rc != 0 {
			t.Errorf("%q must be accepted, rc=%d", v, rc)
		}
	}
	// The bad timeout wins over a missing javac (validated before any probe) ...
	w := newWorld(t)
	w.fixture("X", "class X { 1 }")
	_, _, rc := w.exec(w.args(), "RSDD_FIDELITY_TIMEOUT=abc", "RSDD_FIDELITY_JAVAC=/nonexistent/javac")
	if rc != 2 {
		t.Errorf("timeout validation must precede the probes, rc=%d", rc)
	}
	// ... and an absent fixtures dir wins over the bad timeout.
	_, _, rc = w.exec([]string{"--fixtures", filepath.Join(w.root, "absent")}, "RSDD_FIDELITY_TIMEOUT=abc")
	if rc != 2 {
		t.Errorf("rc=%d", rc)
	}
	empty := filepath.Join(w.root, "empty")
	if err := os.Mkdir(empty, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, _, rc = w.exec([]string{"--fixtures", empty}, "RSDD_FIDELITY_TIMEOUT=abc"); rc != 1 {
		t.Errorf("empty fixtures must win over the bad timeout, rc=%d", rc)
	}
}

// TestProbes: a missing runtime dependency is a typed DEGRADED, rc 4, no verdict, never DONE (teeth D and K).
func TestProbes(t *testing.T) {
	cases := []struct {
		name  string
		extra []string
		path  string // overrides PATH; "-" means an empty directory
		want  string
	}{
		{"javac override missing", []string{"RSDD_FIDELITY_JAVAC=/nonexistent/javac"}, "", "DEGRADED: reason=javac-missing (no usable javac; set RSDD_FIDELITY_JAVAC or put a JDK on PATH)\n"},
		{"javac override is a directory", []string{"RSDD_FIDELITY_JAVAC=@root"}, "", "DEGRADED: reason=javac-missing (no usable javac; set RSDD_FIDELITY_JAVAC or put a JDK on PATH)\n"},
		{"javac override not executable", []string{"RSDD_FIDELITY_JAVAC=@plain"}, "", "DEGRADED: reason=javac-missing (no usable javac; set RSDD_FIDELITY_JAVAC or put a JDK on PATH)\n"},
		{"javac not on PATH", nil, "-", "DEGRADED: reason=javac-missing (no usable javac; set RSDD_FIDELITY_JAVAC or put a JDK on PATH)\n"},
		{"javap override missing", []string{"RSDD_FIDELITY_JAVAP=/nonexistent/javap"}, "", "DEGRADED: reason=javap-missing (no usable javap; set RSDD_FIDELITY_JAVAP or put a JDK on PATH)\n"},
		{"javap override is a directory", []string{"RSDD_FIDELITY_JAVAP=@root"}, "", "DEGRADED: reason=javap-missing (no usable javap; set RSDD_FIDELITY_JAVAP or put a JDK on PATH)\n"},
		{"javap not on PATH", []string{"RSDD_FIDELITY_JAVAC=@javac"}, "-", "DEGRADED: reason=javap-missing (no usable javap; set RSDD_FIDELITY_JAVAP or put a JDK on PATH)\n"},
		{"decompiler not executable", []string{"RSDD_FIDELITY_DECOMPILER=@plain"}, "", "DEGRADED: reason=decompiler-missing (@plain is not executable)\n"},
		{"decompiler is a directory", []string{"RSDD_FIDELITY_DECOMPILER=@root"}, "", "DEGRADED: reason=decompiler-missing (@root is not executable)\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			w.fixture("X", "class X { 1 }")
			plain := filepath.Join(w.root, "plain")
			if err := os.WriteFile(plain, nil, 0o644); err != nil {
				t.Fatal(err)
			}
			empty := filepath.Join(w.root, "emptybin")
			if err := os.Mkdir(empty, 0o755); err != nil {
				t.Fatal(err)
			}
			rep := strings.NewReplacer("@root", w.root, "@plain", plain, "@javac", w.javac)
			var extra []string
			for _, e := range c.extra {
				extra = append(extra, rep.Replace(e))
			}
			if c.path == "-" {
				extra = append(extra, "PATH="+empty)
			}
			out, errs, rc := w.exec(w.args(), extra...)
			if rc != 4 || errs != "" || out != rep.Replace(c.want) {
				t.Fatalf("rc=%d err=%q out=%q", rc, errs, out)
			}
			if len(w.calls) != 0 {
				t.Fatalf("a degraded probe must run nothing: %v", w.calls)
			}
		})
	}
}

// TestProbeOrder: javac is judged before javap before the decompiler; PATH resolves both tools by name.
func TestProbeOrder(t *testing.T) {
	w := newWorld(t)
	w.fixture("X", "class X { 1 }")
	w.decs["X"] = copyDec(okOut, 0)
	out, _, rc := w.exec(w.args(), "RSDD_FIDELITY_JAVAC=/nonexistent/javac", "RSDD_FIDELITY_JAVAP=/nonexistent/javap", "RSDD_FIDELITY_DECOMPILER=/nonexistent/d")
	if rc != 4 || !strings.Contains(out, "javac-missing") {
		t.Errorf("javac first: %q", out)
	}
	out, _, _ = w.exec(w.args(), "RSDD_FIDELITY_JAVAP=/nonexistent/javap", "RSDD_FIDELITY_DECOMPILER=/nonexistent/d")
	if !strings.Contains(out, "javap-missing") {
		t.Errorf("javap second: %q", out)
	}
	out, _, _ = w.exec(w.args(), "RSDD_FIDELITY_DECOMPILER=/nonexistent/d")
	if out != "DEGRADED: reason=decompiler-missing (/nonexistent/d is not executable)\n" {
		t.Errorf("decompiler third: %q", out)
	}
	// An override beats PATH, and the run uses the override path.
	other := filepath.Join(w.root, "other-javac")
	if err := os.WriteFile(other, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	w.javac = other
	w.calls = nil
	w.exec(w.args(), "RSDD_FIDELITY_JAVAC="+other)
	if len(w.callsTo(other)) == 0 || len(w.callsTo(filepath.Join(w.bin, "javac"))) != 0 {
		t.Errorf("override not used: %v", w.calls)
	}
}

// TestDecompilerDefault: without RSDD_FIDELITY_DECOMPILER (or with an empty one) the wrapper beside the toolbelt is used.
func TestDecompilerDefault(t *testing.T) {
	w := newWorld(t)
	w.fixture("X", "class X { 1 }")
	tb := filepath.Join(w.root, "tb")
	if err := os.MkdirAll(tb, 0o755); err != nil {
		t.Fatal(err)
	}
	w.dec = filepath.Join(tb, "decompile-java.sh")
	if err := os.WriteFile(w.dec, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	w.decs["X"] = copyDec(okOut, 0)
	for _, env := range []string{"RSDD_FIDELITY_DECOMPILER=", "RSDD_FIDELITY_DECOMPILER_UNSET="} {
		w.calls = nil
		out, _, rc := w.exec(append(w.args(), "--toolbelt", tb), env)
		if rc != 0 || !strings.HasPrefix(out, "FIDELITY X mode=g verdict=GOOD") {
			t.Errorf("%s: rc=%d %s", env, rc, out)
		}
	}
	// The last --toolbelt wins, as the shim's own comes first.
	w.calls = nil
	_, _, rc := w.exec(append(w.args(), "--toolbelt", filepath.Join(w.root, "wrong"), "--toolbelt", tb), "RSDD_FIDELITY_DECOMPILER=")
	if rc != 0 {
		t.Errorf("last --toolbelt must win, rc=%d", rc)
	}
}

// TestDefaultFixturesFollowTheToolbelt: --fixtures defaults to <toolbelt>/tests/fixtures/java-fidelity-experiment.
func TestDefaultFixturesFollowTheToolbelt(t *testing.T) {
	w := newWorld(t)
	tb := filepath.Join(w.root, "tb")
	def := filepath.Join(tb, "tests", "fixtures", "java-fidelity-experiment")
	if err := os.MkdirAll(def, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(def, "D.java"), []byte("class D { 1 }"), 0o644); err != nil {
		t.Fatal(err)
	}
	w.decs["D"] = copyDec(okOut, 0)
	out, _, rc := w.exec([]string{"--toolbelt", tb, "--work", filepath.Join(w.root, "wk")})
	if rc != 0 || !strings.Contains(out, "FIDELITY D mode=g verdict=GOOD") {
		t.Fatalf("rc=%d %s", rc, out)
	}
	out, errs, rc := w.exec([]string{"--toolbelt", filepath.Join(w.root, "none")})
	if rc != 2 || out != "" || !strings.HasPrefix(errs, "fixtures directory not found: "+filepath.Join(w.root, "none", "tests", "fixtures", "java-fidelity-experiment")) {
		t.Fatalf("rc=%d err=%q", rc, errs)
	}
}

// TestJDKVersion: the first complete "javac <digit>..." line wins; notices before it are skipped; nothing guessed.
func TestJDKVersion(t *testing.T) {
	cases := []struct{ name, out, want string }{
		{"plain", "javac 21.0.1\n", "21.0.1"},
		{"notice first", "Picked up JAVA_TOOL_OPTIONS: -Xmx1m\njavac 17.0.9\n", "17.0.9"},
		{"first of two", "javac 11\njavac 12\n", "11"},
		{"not a version", "javac: error\njavac abc\n", "unknown"},
		{"empty", "", "unknown"},
		{"no trailing newline is not a line", "javac 21.0.1", "unknown"},
		{"trailing fragment ignored", "javac 8\njavac 9", "8"},
		{"suffix kept", "javac 21-ea\n", "21-ea"},
		{"digit 0", "javac 0\n", "0"},
		{"digit 9", "javac 9\n", "9"},
		{"char before 0", "javac /\n", "unknown"},
		{"char after 9", "javac :\n", "unknown"},
		{"empty version", "javac \n", "unknown"},
		{"no space", "javac21\n", "unknown"},
		{"indented", " javac 21\n", "unknown"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := jdkVersion([]byte(c.out)); got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
	w := newWorld(t)
	w.fixture("X", "class X { 1 }")
	w.decs["X"] = copyDec(okOut, 0)
	w.version = "javac 17.0.9\n"
	if out, _, _ := w.exec(w.args()); !strings.Contains(out, "jdk=17.0.9 ") {
		t.Fatalf("jdk not reported: %s", out)
	}
}

// TestLookupEnv: presence is judged on the environment list (last entry wins); without one, on the value.
func TestLookupEnv(t *testing.T) {
	w := newWorld(t)
	s, _, _ := w.stdio("K=first", "K=second", "E=")
	for _, c := range []struct {
		key, want string
		set       bool
	}{{"K", "second", true}, {"E", "", true}, {"NOPE", "", false}} {
		if v, ok := lookupEnv(s, c.key); v != c.want || ok != c.set {
			t.Errorf("%s: %q %v", c.key, v, ok)
		}
	}
	s.Environ = nil
	s.Env = func(k string) string { return map[string]string{"A": "x"}[k] }
	if v, ok := lookupEnv(s, "A"); v != "x" || !ok {
		t.Errorf("no list, set: %q %v", v, ok)
	}
	if v, ok := lookupEnv(s, "B"); v != "" || ok {
		t.Errorf("no list, unset: %q %v", v, ok)
	}
	if n, ok := timeoutSecs(s); n != defaultTimeout || !ok {
		t.Errorf("default timeout: %d %v", n, ok)
	}
}

// TestFixturesIsAFile: --fixtures naming a regular file is "not found", not an empty directory.
func TestFixturesIsAFile(t *testing.T) {
	w := newWorld(t)
	file := filepath.Join(w.root, "afile")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	_, errs, rc := w.exec([]string{"--fixtures", file})
	if rc != 2 || errs != "fixtures directory not found: "+file+"\n" {
		t.Fatalf("rc=%d err=%q", rc, errs)
	}
}
