package decompile

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// The cases below pin single decisions that the captured scenarios only reach by accident: each one exists
// because a hand-made mutant of exactly that decision survived the table (see the mutant log in the PR notes).

// fallbackDir is the scratch directory of the first fallback engine run (a cfr run: `in --outputdir out`).
func fallbackDir(t *testing.T, w *world) string {
	t.Helper()
	for _, c := range w.calls {
		for i, a := range c.Argv {
			if a == "--outputdir" {
				return filepath.Dir(c.Argv[i+1])
			}
		}
	}
	t.Fatalf("no fallback run: %v", w.calls)
	return ""
}

func TestDefaultTmp(t *testing.T) {
	if defaultTmp != "/tmp" {
		t.Errorf("the scratch parent without TMPDIR is %q", defaultTmp)
	}
}

func TestScratchDir(t *testing.T) {
	for _, tt := range []struct {
		name, tmpdir, dflt string
		wantParent         func(w *world) string
	}{
		{"TMPDIR wins", "set", "default", func(w *world) string { return w.tmp }},
		{"no TMPDIR: the default parent", "", "default", func(w *world) string { return filepath.Join(w.root, "default") }},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.mkdir(filepath.Join(w.root, "default"))
			w.deptmp = filepath.Join(w.root, "default")
			if tt.tmpdir == "" {
				w.env["TMPDIR"] = ""
			}
			w.env["STUB_VF_RC"] = "7"
			w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
			work := fallbackDir(t, w)
			if got := filepath.Dir(work); got != tt.wantParent(w) {
				t.Errorf("scratch parent %q, want %q", got, tt.wantParent(w))
			}
		})
	}
	t.Run("the work dir is named after the program", func(t *testing.T) {
		w := newWorld(t)
		w.env["STUB_VF_RC"] = "7"
		w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
		if re := regexp.MustCompile(`/decompile-java\.[0-9]+$`); !re.MatchString(fallbackDir(t, w)) {
			t.Errorf("scratch dir %q", fallbackDir(t, w))
		}
	})
	t.Run("an unusable default parent aborts with the cause", func(t *testing.T) {
		w := newWorld(t)
		w.deptmp = filepath.Join(w.root, "no", "parent")
		w.env["TMPDIR"] = ""
		_, stderr, rc := w.exec(w.touch("T.class"), filepath.Join(w.root, "out"))
		if rc != 1 || !strings.Contains(stderr, "/no/parent") || !fatalRe.MatchString(stderr) {
			t.Errorf("rc %d: %q", rc, stderr)
		}
	})
	t.Run("the out-dir cannot be made", func(t *testing.T) {
		w := newWorld(t)
		f := w.touch("afile")
		_, stderr, rc := w.exec(w.touch("T.class"), filepath.Join(f, "sub"))
		if want := "rsdd: decompile-java: mkdir " + f + ": not a directory\n"; rc != 1 || stderr != want {
			t.Errorf("rc %d: %q, want %q", rc, stderr, want)
		}
	})
}

// TestFreshnessWindow: the run stamp is backdated exactly 2 s (old suite Q1, S3, S4).
func TestFreshnessWindow(t *testing.T) {
	marked := map[string]string{"STUB_MARKER_CLASSES": "Test"}
	for _, tt := range []struct {
		backdate string
		want     string
	}{
		{"1.5", "DEGRADED"}, // inside the window: this run's own output
		{"2.5", "OK"},       // before the stamp: stale, never this run's
	} {
		w := newWorld(t)
		for k, v := range marked {
			w.env[k] = v
		}
		w.env["STUB_BACKDATE_OUT"] = tt.backdate
		stdout, _, _ := w.exec(w.touch("Test.class"), filepath.Join(w.root, "out"))
		if !strings.HasPrefix(stdout, tt.want+": ") {
			t.Errorf("backdate %ss: %q, want %s", tt.backdate, stdout, tt.want)
		}
	}
}

// TestFallbackResult: a fallback is a success only when it exited 0 AND wrote source, and its own markers count
// (old suite F4, C8) - for any file it wrote that looks like source, not for stray files.
func TestFallbackResult(t *testing.T) {
	for _, tt := range []struct {
		name string
		rc   int
		java bool
		note string // a non-java file with a marker
		want string
	}{
		{"exit 0 with source", 0, true, "", "result=ok"},
		{"exit 0 with no source", 0, false, "", "result=failed"},
		{"source but a failing exit", 1, true, "", "result=failed"},
		{"a marker in a file that is not source is not a marker", 0, true, "notes.txt", "result=ok"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.env["STUB_VF_RC"] = "7"
			w.hook = func(c Cmd) (Result, bool) {
				if c.Argv[len(c.Argv)-2] != "--outputdir" {
					return Result{RC: 7}, true
				}
				out := c.Argv[len(c.Argv)-1]
				if tt.java {
					w.write(filepath.Join(out, "Test.java"), "class Test {}\n")
				}
				if tt.note != "" {
					w.write(filepath.Join(out, tt.note), "    // $VF: Couldn't be decompiled\n")
				}
				return Result{RC: tt.rc}, true
			}
			stdout, _, _ := w.exec(w.touch("Test.class"), filepath.Join(w.root, "out"))
			if !strings.Contains(stdout, tt.want) {
				t.Errorf("%q, want %s", stdout, tt.want)
			}
		})
	}
}

// TestUnzipCommand: the extraction is quiet, overwrites, takes only the class entries, and goes to the scratch dir.
func TestUnzipCommand(t *testing.T) {
	w := newWorld(t)
	w.env["STUB_FAIL_WHOLE"] = "1"
	in := w.input("p.jar", inputs["jarp"])
	w.exec(in, filepath.Join(w.root, "out"))
	for _, c := range w.calls {
		if c.Argv[0] == w.unzip && c.Argv[1] != "-Z1" {
			want := []string{w.unzip, "-q", "-o", in, "*.class", "-d", c.Argv[6]}
			if !reflect.DeepEqual(c.Argv, want) || filepath.Base(c.Argv[6]) != "ext" {
				t.Errorf("unzip argv %q", c.Argv)
			}
			return
		}
	}
	t.Fatalf("unzip never ran: %v", w.calls)
}

// TestSweepReasons: why a whole-jar success cannot prove coverage (old suite H3, K3, M1, mM1-mM3).
func TestSweepReasons(t *testing.T) {
	for _, tt := range []struct {
		name  string
		setup func(w *world)
		jar   string
		want  string
	}{
		{"no unzip", func(w *world) { w.env["RSDD_UNZIP_BIN"] = filepath.Join(w.root, "no-such") }, "jarp", "reason=coverage-sweep-unavailable"},
		{"unzip fails", func(w *world) { w.unzipRC = 9 }, "jarp", "reason=coverage-sweep-unavailable"},
		{"unzip: no class entries", func(w *world) { w.unzipRC = 11 }, "jarp", "reason=no-class-entries"},
		{"unzip warns and extracts nothing", func(w *world) { w.unzipRC = 1 }, "jarp", "reason=no-class-entries"},
		{"a symlink in the jar", func(*world) {}, "jarl", "reason=coverage-sweep-unavailable"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			tt.setup(w)
			stdout, _, rc := w.exec(w.input(tt.jar+".jar", inputs[tt.jar]), filepath.Join(w.root, "out"))
			if rc != 4 || !strings.Contains(stdout, tt.want+")") {
				t.Errorf("rc %d: %q, want %s", rc, stdout, tt.want)
			}
		})
	}
}

// TestFailedExtractionIsForgotten: a jar that could not be extracted is not half-extracted for the next unit.
func TestFailedExtractionIsForgotten(t *testing.T) {
	w := newWorld(t)
	w.unzipRC = 9
	w.env["STUB_MARKER_CLASSES"] = "A1 A2"
	stdout, _, _ := w.exec(w.input("p.jar", inputs["jarp"]), filepath.Join(w.root, "out"))
	want := "UNIT: a/A1 reason=marker fallback=none result=kept-primary isolation=unavailable\n"
	if !strings.Contains(stdout, want) || !strings.Contains(stdout, strings.Replace(want, "A1", "A2", 1)) {
		t.Errorf("both units must say why:\n%s", stdout)
	}
}

// TestMarkerScanIgnoresOtherFiles: only .java sources are scanned, never other files in the out-dir.
func TestMarkerScanIgnoresOtherFiles(t *testing.T) {
	w := newWorld(t)
	w.hook = func(c Cmd) (Result, bool) {
		r := w.engine(c)
		w.write(filepath.Join(c.Argv[len(c.Argv)-1], "readme.txt"), "    // $VF: Couldn't be decompiled\n")
		return r, true
	}
	stdout, _, rc := w.exec(w.touch("Test.class"), filepath.Join(w.root, "out"))
	if rc != 0 || stdout != "OK: "+w.touch("Test.class")+" -> "+filepath.Join(w.root, "out")+"  (engine=vineflower)\n" {
		t.Errorf("rc %d: %q", rc, stdout)
	}
}

// TestReportDetail: the degraded reasons are listed in the order they arose, comma-separated, after the other fields.
func TestReportDetail(t *testing.T) {
	w := newWorld(t)
	w.env["RSDD_TIMEOUT_BIN"] = filepath.Join(w.root, "no-such")
	w.env["RSDD_DECOMPILE_ISOLATE_BUDGET"] = "1"
	w.env["STUB_OMIT_CLASSES"] = "A1 A2"
	w.env["STUB_CFR_UNIT_SLEEP"] = "15"
	in, out := w.input("p.jar", inputs["jarp"]), filepath.Join(w.root, "out")
	stdout, _, _ := w.exec(in, out)
	want := "DEGRADED: " + in + " -> " + out + "  (engine=vineflower units=1 reason=timeout-unavailable,total_budget_exhausted)\n"
	if !strings.HasPrefix(stdout, want) {
		t.Errorf("%q\nwant prefix %q", stdout, want)
	}
}

// TestNoSourceWarnings: the exact texts of the two ways a run ends with no source at all.
func TestNoSourceWarnings(t *testing.T) {
	t.Run("exit 0, nothing written", func(t *testing.T) {
		w := newWorld(t)
		w.env["STUB_SILENT"] = "1"
		out := filepath.Join(w.root, "out")
		_, stderr, rc := w.exec(w.touch("T.class"), out)
		want := "WARN: vineflower decompiler exited 0 but produced no .java files in " + out + " (input may be obfuscated or unsupported)\n"
		if rc != 1 || !strings.HasSuffix(stderr, want) {
			t.Errorf("rc %d: %q", rc, stderr)
		}
	})
	t.Run("every engine failed", func(t *testing.T) {
		w := newWorld(t)
		w.env["STUB_VF_RC"] = "7"
		w.env["CFR_JAR"] = filepath.Join(w.root, "no-such.jar")
		out := filepath.Join(w.root, "out")
		stdout, stderr, rc := w.exec(w.touch("T.class"), out)
		if rc != 1 || !strings.HasPrefix(stdout, "PARTIAL: ") || !strings.HasSuffix(stderr, "WARN: no .java files produced in "+out+"\n") {
			t.Errorf("rc %d: %q / %q", rc, stdout, stderr)
		}
	})
}

// TestEngineRun: how one engine run reaches the process runner.
func TestEngineRun(t *testing.T) {
	t.Run("the out-dir exists before the engine starts", func(t *testing.T) {
		w := newWorld(t)
		var seen bool
		w.hook = func(c Cmd) (Result, bool) {
			seen = isDir(c.Argv[len(c.Argv)-1])
			return w.engine(c), true
		}
		w.exec(w.touch("Test.class"), filepath.Join(w.root, "out"))
		if !seen {
			t.Error("the engine's output directory was missing when it started")
		}
	})
	t.Run("an isolation run's output directory exists too", func(t *testing.T) {
		w := newWorld(t)
		w.env["STUB_FAIL_WHOLE"] = "1"
		var seen []bool
		w.hook = func(c Cmd) (Result, bool) {
			if strings.Contains(c.Argv[len(c.Argv)-1], "/pout/") {
				seen = append(seen, isDir(c.Argv[len(c.Argv)-1]))
			}
			return w.engine(c), true
		}
		w.exec(w.input("p.jar", inputs["jarp"]), filepath.Join(w.root, "out"))
		if !reflect.DeepEqual(seen, []bool{true}) {
			t.Errorf("per-package output directories at start: %v", seen)
		}
	})
}

// TestProcRunnerSpec: the limits every program runs under.
func TestProcRunnerSpec(t *testing.T) {
	var got proc.Spec
	run := newProcRunner(func(s proc.Spec) (proc.Result, error) { got = s; return proc.Result{}, nil })
	run(Cmd{Argv: []string{"x"}})
	if got.Timeout != 365*24*time.Hour || got.MaxBytes != 64<<20 {
		t.Errorf("spec %+v", got)
	}
	run(Cmd{Argv: []string{"x"}, Timeout: 3 * time.Second, Grace: 2 * time.Second})
	if got.Timeout != 3*time.Second || got.Grace != 2*time.Second {
		t.Errorf("spec %+v", got)
	}
	if r := newProcRunner(func(proc.Spec) (proc.Result, error) { return proc.Result{}, &proc.SpawnError{} })(Cmd{}); r.RC != 127 {
		t.Errorf("a program that cannot start reads as %d", r.RC)
	}
}

// TestRelativePathsFollowTheCommandCwd: every file-system operation resolves a relative input / out-dir against the
// command's working directory (where the children run), never the process's; the messages keep the path as given.
func TestRelativePathsFollowTheCommandCwd(t *testing.T) {
	procCwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	listing := func() []string {
		ents, err := os.ReadDir(procCwd)
		if err != nil {
			t.Fatal(err)
		}
		var names []string
		for _, e := range ents {
			names = append(names, e.Name())
		}
		return names
	}
	before := listing()
	for _, tt := range []struct {
		name, in string
		env      map[string]string
		jar      string
		want     []string // files expected under the out-dir
	}{
		{"class run with a fallback", "in/T.class", map[string]string{"STUB_VF_RC": "7"}, "", []string{"T.java"}},
		{"jar run through isolation", "in/p.jar", map[string]string{"STUB_FAIL_WHOLE": "1"}, "jarp", []string{"a/A1.java", "a/A2.java", "a/A3.java"}},
		{"jar run with a marker", "in/p.jar", map[string]string{"STUB_MARKER_CLASSES": "A2"}, "jarp", []string{"a/A1.java", "a/A2.java", "a/A3.java"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			for k, v := range tt.env {
				w.env[k] = v
			}
			if tt.jar == "" {
				w.write(filepath.Join(w.root, tt.in), "")
			} else {
				w.jars[filepath.Join(w.root, tt.in)] = inputs[tt.jar]
				w.write(filepath.Join(w.root, tt.in), "")
			}
			w.write(filepath.Join(w.root, "my-vineflower.jar"), "") // the relative --jar override
			stdout, _, rc := w.exec(tt.in, "out/sub", "--jar", "my-vineflower.jar")
			if rc != 0 && rc != 4 {
				t.Fatalf("rc %d\n%s", rc, stdout)
			}
			if !strings.Contains(stdout, ": "+tt.in+" -> out/sub  (engine=vineflower") {
				t.Errorf("the messages must show the paths as given:\n%s", stdout)
			}
			for _, f := range tt.want {
				if !isFile(filepath.Join(w.root, "out", "sub", f)) {
					t.Errorf("%s is not under the command's directory: %s", f, tree(t, w.root))
				}
			}
			if after := listing(); !reflect.DeepEqual(before, after) {
				t.Errorf("the process's own directory changed: %v -> %v", before, after)
			}
		})
	}
}
