package decompile

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func TestUsage(t *testing.T) {
	for _, tt := range []struct {
		name string
		args []string // IN and OUT stand for the input and out-dir
		env  map[string]string
		rc   int
		err  string
	}{
		{"no arguments", nil, nil, 1, usageLine},
		{"no out-dir", []string{"IN"}, nil, 1, usageLine},
		{"empty input", []string{"", "OUT"}, nil, 1, usageLine},
		{"empty out-dir", []string{"IN", ""}, nil, 1, usageLine},
		{"unknown option", []string{"IN", "OUT", "--bogus"}, nil, 2, "unknown option: --bogus\n"},
		{"a positional after the out-dir is an unknown option", []string{"IN", "OUT", "extra"}, nil, 2, "unknown option: extra\n"},
		{"--engine without a value", []string{"IN", "OUT", "--engine"}, nil, 1, "engine required\n"},
		{"--engine with an empty value", []string{"IN", "OUT", "--engine", ""}, nil, 1, "engine required\n"},
		{"--jar without a value", []string{"IN", "OUT", "--jar"}, nil, 1, "jar required\n"},
		{"--timeout without a value", []string{"IN", "OUT", "--timeout"}, nil, 1, "timeout required\n"},
		{"--fallback-engine without a value", []string{"IN", "OUT", "--fallback-engine"}, nil, 1, "fallback engine required\n"},
		{"--thread-count without a value", []string{"IN", "OUT", "--thread-count"}, nil, 1, "thread count required\n"},
		{"thread count 0", []string{"IN", "OUT", "--thread-count", "0"}, nil, 2, "invalid thread count\n"},
		{"thread count text", []string{"IN", "OUT", "--thread-count", "x4"}, nil, 2, "invalid thread count\n"},
		{"thread count five digits", []string{"IN", "OUT", "--thread-count", "10000"}, nil, 2, "invalid thread count\n"},
		{"thread count trailing text", []string{"IN", "OUT", "--thread-count", "4x"}, nil, 2, "invalid thread count\n"},
		{"A5 timeout text", []string{"IN", "OUT", "--timeout", "abc"}, nil, 2, "invalid timeout (seconds, 0 = unbounded)\n"},
		{"timeout negative", []string{"IN", "OUT", "--timeout", "-1"}, nil, 2, "invalid timeout (seconds, 0 = unbounded)\n"},
		{"timeout seven digits", []string{"IN", "OUT", "--timeout", "1234567"}, nil, 2, "invalid timeout (seconds, 0 = unbounded)\n"},
		{"timeout trailing text", []string{"IN", "OUT", "--timeout", "12s"}, nil, 2, "invalid timeout (seconds, 0 = unbounded)\n"},
		{"timeout from the environment", []string{"IN", "OUT"}, map[string]string{"RSDD_DECOMPILE_TIMEOUT": "abc"}, 2, "invalid timeout (seconds, 0 = unbounded)\n"},
		{"budget text", []string{"IN", "OUT"}, map[string]string{"RSDD_DECOMPILE_ISOLATE_BUDGET": "x"}, 2, "invalid RSDD_DECOMPILE_ISOLATE_BUDGET (seconds, 0 = unlimited)\n"},
		{"budget seven digits", []string{"IN", "OUT"}, map[string]string{"RSDD_DECOMPILE_ISOLATE_BUDGET": "1234567"}, 2, "invalid RSDD_DECOMPILE_ISOLATE_BUDGET (seconds, 0 = unlimited)\n"},
		{"kill-after 0", []string{"IN", "OUT"}, map[string]string{"RSDD_KILL_AFTER": "0"}, 2, "invalid RSDD_KILL_AFTER\n"},
		{"kill-after five digits", []string{"IN", "OUT"}, map[string]string{"RSDD_KILL_AFTER": "10000"}, 2, "invalid RSDD_KILL_AFTER\n"},
		{"kill-after text", []string{"IN", "OUT"}, map[string]string{"RSDD_KILL_AFTER": "5s"}, 2, "invalid RSDD_KILL_AFTER\n"},
		{"unknown engine", []string{"IN", "OUT", "--engine", "fernflower"}, nil, 2, "unknown engine: fernflower (use vineflower|cfr|procyon)\n"},
		{"none is not an engine", []string{"IN", "OUT", "--engine", "none"}, nil, 2, "unknown engine: none (use vineflower|cfr|procyon)\n"},
		{"unknown fallback engine", []string{"IN", "OUT", "--fallback-engine", "fernflower"}, nil, 2, "unknown fallback engine: fernflower\n"},
		{"heap without a unit", []string{"IN", "OUT"}, map[string]string{"RSDD_DECOMPILE_MAX_HEAP": "512"}, 2, "invalid RSDD_DECOMPILE_MAX_HEAP\n"},
		{"heap zero", []string{"IN", "OUT"}, map[string]string{"RSDD_DECOMPILE_MAX_HEAP": "0m"}, 2, "invalid RSDD_DECOMPILE_MAX_HEAP\n"},
		{"heap seven digits", []string{"IN", "OUT"}, map[string]string{"RSDD_DECOMPILE_MAX_HEAP": "1234567m"}, 2, "invalid RSDD_DECOMPILE_MAX_HEAP\n"},
		{"heap bad unit", []string{"IN", "OUT"}, map[string]string{"RSDD_DECOMPILE_MAX_HEAP": "5k"}, 2, "invalid RSDD_DECOMPILE_MAX_HEAP\n"},
		// The order the script validated in: option errors as they are met, then timeout, budget, kill-after, engine,
		// fallback, heap.
		{"a bad thread count is met before a later unknown option", []string{"IN", "OUT", "--thread-count", "0", "--bogus"}, nil, 2, "invalid thread count\n"},
		{"an unknown option is met before a later bad thread count", []string{"IN", "OUT", "--bogus", "--thread-count", "0"}, nil, 2, "unknown option: --bogus\n"},
		{"a missing value is met before a later unknown option", []string{"IN", "OUT", "--jar", "", "--bogus"}, nil, 1, "jar required\n"},
		{"the thread count is checked while parsing, the timeout after", []string{"IN", "OUT", "--timeout", "x", "--thread-count", "0"}, nil, 2, "invalid thread count\n"},
		{"timeout before budget", []string{"IN", "OUT", "--timeout", "x"}, map[string]string{"RSDD_DECOMPILE_ISOLATE_BUDGET": "x"}, 2, "invalid timeout (seconds, 0 = unbounded)\n"},
		{"budget before kill-after", []string{"IN", "OUT"}, map[string]string{"RSDD_DECOMPILE_ISOLATE_BUDGET": "x", "RSDD_KILL_AFTER": "x"}, 2, "invalid RSDD_DECOMPILE_ISOLATE_BUDGET (seconds, 0 = unlimited)\n"},
		{"kill-after before engine", []string{"IN", "OUT", "--engine", "x"}, map[string]string{"RSDD_KILL_AFTER": "x"}, 2, "invalid RSDD_KILL_AFTER\n"},
		{"engine before fallback", []string{"IN", "OUT", "--engine", "x", "--fallback-engine", "y"}, nil, 2, "unknown engine: x (use vineflower|cfr|procyon)\n"},
		{"fallback before heap", []string{"IN", "OUT", "--fallback-engine", "y"}, map[string]string{"RSDD_DECOMPILE_MAX_HEAP": "x"}, 2, "unknown fallback engine: y\n"},
		{"usage errors come after the Java check", []string{"IN", "OUT", "--bogus"}, map[string]string{"NO_JAVA": "1"}, 3, "Java 21 not usable (set JAVA_HOME or RESEARCH_SDD_JAVA_HOME)\n"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			for k, v := range tt.env {
				w.env[k] = v
			}
			if w.env["NO_JAVA"] != "" {
				w.homeErr = errors.New("no java")
			}
			in, out := w.touch("Test.class"), filepath.Join(w.root, "out")
			args := append([]string(nil), tt.args...)
			for i, a := range args {
				switch a {
				case "IN":
					args[i] = in
				case "OUT":
					args[i] = out
				}
			}
			stdout, stderr, rc := w.exec(args...)
			if rc != tt.rc || stderr != tt.err || stdout != "" {
				t.Errorf("rc %d stderr %q stdout %q, want rc %d stderr %q", rc, stderr, stdout, tt.rc, tt.err)
			}
			if len(w.calls) != 0 {
				t.Errorf("a rejected command line ran %v", w.calls)
			}
		})
	}
}

func TestValidOptionsAreAccepted(t *testing.T) {
	for _, extra := range [][]string{
		{"--thread-count", "1"}, {"--thread-count", "9999"}, {"--timeout", "999999"}, {"--timeout", "0"},
		{"--fallback-engine", "none"}, {"--fallback-engine", "procyon"}, {"--engine", "cfr", "--fallback-engine", "vineflower"},
	} {
		w := newWorld(t)
		w.env["RSDD_KILL_AFTER"], w.env["RSDD_DECOMPILE_MAX_HEAP"], w.env["RSDD_DECOMPILE_ISOLATE_BUDGET"] = "9999", "999999g", "999999"
		_, stderr, rc := w.exec(append([]string{w.touch("Test.class"), filepath.Join(w.root, "out")}, extra...)...)
		if rc != 0 {
			t.Errorf("%v: rc %d: %s", extra, rc, stderr)
		}
	}
}

// TestFallbackDefault: cfr falls back to procyon, everything else to cfr.
func TestFallbackDefault(t *testing.T) {
	for engine, want := range map[string]string{"vineflower": "cfr", "cfr": "procyon", "procyon": "cfr"} {
		c, cerr := parseConfig([]string{"i", "o", "--engine", engine}, func(string) string { return "" })
		if cerr != nil || c.fallback != want {
			t.Errorf("engine %s: fallback %q (%v)", engine, c.fallback, cerr)
		}
	}
}

func TestOutDirNormalisation(t *testing.T) {
	for in, want := range map[string]string{"out": "out", "out/": "out", "out///": "out", "/": "/", "//": "/", "a/b/": "a/b"} {
		c, _ := parseConfig([]string{"i", in}, func(string) string { return "" })
		if c.out != want {
			t.Errorf("out-dir %q -> %q, want %q", in, c.out, want)
		}
	}
}

func TestJavaResolution(t *testing.T) {
	t.Run("no Java 21", func(t *testing.T) {
		w := newWorld(t)
		w.homeErr = errors.New("none")
		_, stderr, rc := w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
		if rc != 3 || stderr != "Java 21 not usable (set JAVA_HOME or RESEARCH_SDD_JAVA_HOME)\n" {
			t.Errorf("rc %d: %q", rc, stderr)
		}
	})
	for name, breakJava := range map[string]func(w *world){
		"launcher missing":        func(w *world) { os.Remove(w.java) },
		"launcher not executable": func(w *world) { os.Chmod(w.java, 0o644) },
	} {
		t.Run(name, func(t *testing.T) {
			w := newWorld(t)
			breakJava(w)
			_, stderr, rc := w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
			if rc != 3 || stderr != "Java launcher is not a canonical executable\n" {
				t.Errorf("rc %d: %q", rc, stderr)
			}
		})
	}
	t.Run("the engine runs the resolved launcher", func(t *testing.T) {
		w := newWorld(t)
		real := w.exe(filepath.Join(w.root, "real-java"))
		link := filepath.Join(w.root, "java-link")
		if err := os.Symlink(real, link); err != nil {
			t.Fatal(err)
		}
		os.Remove(w.java)
		if err := os.Symlink(link, w.java); err != nil {
			t.Fatal(err)
		}
		w.java = real
		w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
		if cs := engineCalls(w); len(cs) != 1 {
			t.Fatalf("the engine must run the resolved launcher: %v", w.calls)
		}
	})
}

// TestEngineJarMissing: exit 3 before anything is decompiled, naming the variable to set; the out-dir exists.
func TestEngineJarMissing(t *testing.T) {
	for _, tt := range []struct {
		name string
		args []string
		env  map[string]string
		err  string
	}{
		{"vineflower", nil, map[string]string{"VINEFLOWER_JAR": "@missing"}, "vineflower jar not found (set VINEFLOWER_JAR)\n"},
		{"cfr", []string{"--engine", "cfr"}, map[string]string{"CFR_JAR": "@missing"}, "cfr jar not found (set CFR_JAR)\n"},
		{"procyon", []string{"--engine", "procyon"}, map[string]string{"PROCYON_JAR": "@missing"}, "procyon jar not found (set PROCYON_JAR)\n"},
		{"--jar override that is not a file", []string{"--jar", "@missing"}, nil, "vineflower jar not found (set VINEFLOWER_JAR)\n"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			for k, v := range tt.env {
				w.env[k] = strings.ReplaceAll(v, "@missing", filepath.Join(w.root, "no-such"))
			}
			out := filepath.Join(w.root, "out")
			args := []string{w.touch("T.class"), out}
			for _, a := range tt.args {
				args = append(args, strings.ReplaceAll(a, "@missing", filepath.Join(w.root, "no-such")))
			}
			stdout, stderr, rc := w.exec(args...)
			if rc != 3 || stderr != tt.err || stdout != "" {
				t.Errorf("rc %d stderr %q", rc, stderr)
			}
			if !isDir(out) {
				t.Error("the out-dir must exist even when the engine is missing")
			}
			if len(w.factsIn) != 0 {
				t.Error("the class-file facts must not be read before the engine check")
			}
		})
	}
}

func TestJavap(t *testing.T) {
	t.Run("pass-through", func(t *testing.T) {
		w := newWorld(t)
		w.javapOut = "Compiled from X\n"
		stdout, stderr, rc := w.exec("--javap", "X.class")
		if rc != 5 || stdout != "Compiled from X\n" || stderr != "javap: boom\n" {
			t.Errorf("rc %d out %q err %q", rc, stdout, stderr)
		}
		if got := strings.Join(w.calls[0].Argv[1:], " "); got != "-p -c X.class" || w.calls[0].Argv[0] != w.javap {
			t.Errorf("javap argv: %q", w.calls[0].Argv)
		}
		if w.calls[0].Timeout != 0 {
			t.Error("javap is not bounded")
		}
	})
	for name, args := range map[string][]string{"no class": {"--javap"}, "empty class": {"--javap", ""}} {
		t.Run(name, func(t *testing.T) {
			w := newWorld(t)
			_, stderr, rc := w.exec(args...)
			if rc != 1 || stderr != usageLine || len(w.calls) != 0 {
				t.Errorf("rc %d: %q", rc, stderr)
			}
		})
	}
	t.Run("javap missing", func(t *testing.T) {
		w := newWorld(t)
		os.Remove(w.javap)
		_, stderr, rc := w.exec("--javap")
		if rc != 3 || stderr != "javap launcher is not a canonical executable\n" {
			t.Errorf("rc %d: %q", rc, stderr)
		}
	})
	t.Run("only as the first argument", func(t *testing.T) {
		w := newWorld(t)
		_, stderr, rc := w.exec("a", "b", "--javap")
		if rc != 2 || stderr != "unknown option: --javap\n" {
			t.Errorf("rc %d: %q", rc, stderr)
		}
	})
}

// TestFatal: a failed mkdir aborts with exit 1, as `set -e` did, and says what failed.
// fatalRe is the last line of an aborted run: the program's name, the cause, and nothing after the newline.
var fatalRe = regexp.MustCompile(`(^|\n)rsdd: decompile-java: [^\n]+: (not a directory|no such file or directory)\n$`)

func TestFatal(t *testing.T) {
	t.Run("out-dir under a file", func(t *testing.T) {
		w := newWorld(t)
		_, stderr, rc := w.exec(w.touch("T.class"), filepath.Join(w.touch("afile"), "sub"))
		if rc != 1 || !fatalRe.MatchString(stderr) {
			t.Errorf("rc %d: %q", rc, stderr)
		}
	})
	t.Run("scratch dir cannot be made", func(t *testing.T) {
		w := newWorld(t)
		w.env["TMPDIR"] = filepath.Join(w.root, "no", "such", "dir")
		_, stderr, rc := w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
		if rc != 1 || !fatalRe.MatchString(stderr) {
			t.Errorf("rc %d: %q", rc, stderr)
		}
	})
	t.Run("scratch falls back to the default parent", func(t *testing.T) {
		w := newWorld(t)
		delete(w.env, "TMPDIR")
		_, stderr, rc := w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
		if rc != 0 {
			t.Errorf("rc %d: %q", rc, stderr)
		}
		if ents, _ := os.ReadDir(w.tmp); len(ents) != 0 {
			t.Errorf("the scratch dir was not removed: %v", ents)
		}
	})
	t.Run("a failure while a unit falls back", func(t *testing.T) {
		w := newWorld(t)
		w.env["STUB_VF_RC"] = "7"
		w.hook = func(Cmd) (Result, bool) { os.RemoveAll(w.tmp); return Result{RC: 7}, true }
		_, stderr, rc := w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
		if rc != 1 || !fatalRe.MatchString(stderr) {
			t.Errorf("rc %d: %q", rc, stderr)
		}
	})
	t.Run("another panic is not swallowed", func(t *testing.T) {
		w := newWorld(t)
		w.facts = func(string, time.Duration, cli.Stdio) factsResult { panic("boom") }
		defer func() {
			if r := recover(); r != "boom" {
				t.Errorf("recovered %v", r)
			}
		}()
		w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
	})
}

// TestScratchRemoved: nothing is left behind in the scratch dir on any exit.
func TestScratchRemoved(t *testing.T) {
	for _, env := range []map[string]string{nil, {"STUB_FAIL_WHOLE": "1"}, {"STUB_SILENT": "1"}} {
		w := newWorld(t)
		for k, v := range env {
			w.env[k] = v
		}
		w.exec(w.input("p.jar", inputs["jarp"]), filepath.Join(w.root, "out"))
		if ents, _ := os.ReadDir(w.tmp); len(ents) != 0 {
			t.Errorf("%v left %v", env, ents)
		}
	}
}

// TestEnginePassThrough: an engine's own output reaches the caller's streams, in the order it was produced.
func TestEnginePassThrough(t *testing.T) {
	w := newWorld(t)
	w.hook = func(Cmd) (Result, bool) {
		return Result{Stdout: []byte("engine says hi\n"), Stderr: []byte("engine warns\n")}, true
	}
	w.env["STUB_SILENT"] = "1"
	stdout, stderr, _ := w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
	if stdout != "engine says hi\n" || !strings.Contains(stderr, "engine warns\n") {
		t.Errorf("stdout %q stderr %q", stdout, stderr)
	}
}

// TestRunWiring: the production entry point builds its own dependencies; a host with a Java 21 stops at the
// unknown option, a host without one at the Java check.
func TestRunWiring(t *testing.T) {
	var out, errb bytes.Buffer
	s := cli.Stdio{Out: &out, Err: &errb, Env: func(string) string { return "" }, Environ: func() []string { return []string{"PATH=/nonexistent"} }, Clock: time.Now, Cwd: t.TempDir()}
	if rc := Run([]string{"x", "y", "--bogus"}, s); rc != 2 && rc != 3 {
		t.Errorf("rc %d: %s", rc, errb.String())
	}
}
