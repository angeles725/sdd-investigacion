package sweep

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The five sweep commands find the kit without --kit through one resolution that names no script (#2770). Every
// case runs the public command with a hermetic Stdio (HOME in a temp dir, so no launcher file of the real home is
// read) and compares stdout, stderr and the exit code together.

// siteKit is a kit at <home>/investigacion/sdd-investigacion/research-sdd (the default checkout) with a toolbelt/
// directory, a TARGETS.md without targets and the named toolbelt files (empty).
type siteKit struct {
	home, kit string
}

func newSiteKit(t *testing.T, files ...string) siteKit {
	t.Helper()
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	k := siteKit{home: home, kit: filepath.Join(home, "investigacion", "sdd-investigacion", "research-sdd")}
	for _, f := range append([]string{"TARGETS.md"}, files...) {
		p := filepath.Join(k.kit, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		body := ""
		if f == "TARGETS.md" {
			body = "# targets\n"
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(k.kit, "toolbelt"), 0o755); err != nil {
		t.Fatal(err)
	}
	return k
}

// run executes the command with RESEARCH_SDD_KIT=kitEnv and the working directory cwd.
func (k siteKit) run(run func([]string, cli.Stdio) int, args []string, kitEnv, cwd string) (out, errOut string, rc int) {
	env := map[string]string{"HOME": k.home, "RESEARCH_HOME": filepath.Join(k.home, "rh"), "PATH": "/usr/bin:/bin", "RESEARCH_SDD_KIT": kitEnv}
	var o, e bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Cwd: cwd,
		Env:   func(key string) string { return env[key] },
		Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) },
		Environ: func() []string {
			var l []string
			for key, v := range env {
				l = append(l, key+"="+v)
			}
			return l
		}}
	rc = run(args, s)
	return o.String(), e.String(), rc
}

type siteCmd struct {
	name   string
	run    func([]string, cli.Stdio) int
	script string   // the legacy script the command used to name
	files  []string // what else the command needs under the kit
	out    string   // the expected stdout, "@K@" for the kit root
	err    string   // the expected stderr
	rc     int
}

// allFiles are the eight scripts `sweep all` runs (empty files: each passes).
var allFiles = func() []string {
	var l []string
	for _, n := range allScripts {
		l = append(l, "toolbelt/"+n)
	}
	return l
}()

// allOut is the report of eight passing scripts.
func allOut() string {
	bar := strings.Repeat("=", 40) + "\n"
	var b, sum strings.Builder
	for _, n := range allScripts {
		b.WriteString("\n" + bar + "== " + n + "\n" + bar + "\nPASS  " + n + "\n")
		sum.WriteString("  PASS  " + n + "\n")
	}
	return b.String() + "\n" + bar + "== sweep-all summary\n" + bar + sum.String()
}

var siteCmds = []siteCmd{
	{name: "all", run: RunAll, script: "toolbelt/sweep-all.sh", files: allFiles, out: allOut()},
	{name: "retros", run: RunRetros, script: "toolbelt/sweep-retros.sh", rc: 1,
		err: "sweep-retros: ERROR — no usable target paths in @K@/TARGETS.md\nsweep-retros: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
	{name: "audits", run: RunAudits, script: "toolbelt/sweep-audits.sh", rc: 1,
		err: "sweep-audits: ERROR — no usable target paths in @K@/TARGETS.md\nsweep-audits: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
	{name: "breakthroughs", run: RunBreakthroughs, script: "toolbelt/sweep-breakthroughs.sh", rc: 1,
		err: "sweep-breakthroughs: cannot find @K@/BREAKTHROUGHS.md\n"},
	{name: "tools", run: RunTools, script: "toolbelt/sweep-tools.sh", rc: 1,
		err: "sweep-tools: ERROR — no usable target paths in @K@/TARGETS.md\nsweep-tools: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
}

func (c siteCmd) want(k siteKit, text string) string { return strings.ReplaceAll(text, "@K@", k.kit) }

func (c siteCmd) check(t *testing.T, k siteKit, kitEnv, cwd, warn string) {
	t.Helper()
	out, errOut, rc := k.run(c.run, nil, kitEnv, cwd)
	if out != c.want(k, c.out) || errOut != warn+c.want(k, c.err) || rc != c.rc {
		t.Fatalf("got rc=%d\nstdout %q\nstderr %q\nwant rc=%d\nstdout %q\nstderr %q", rc, out, errOut, c.rc, c.want(k, c.out), warn+c.want(k, c.err))
	}
}

func TestSweepKitFound(t *testing.T) {
	for _, c := range siteCmds {
		t.Run(c.name, func(t *testing.T) {
			t.Run("script present: the previous output", func(t *testing.T) {
				k := newSiteKit(t, append([]string{c.script}, c.files...)...)
				c.check(t, k, k.kit, k.home, "")
			})
			t.Run("legacy script missing: the same output", func(t *testing.T) {
				k := newSiteKit(t, c.files...)
				c.check(t, k, k.kit, k.home, "")
			})
			t.Run("kit path with a trailing slash", func(t *testing.T) {
				k := newSiteKit(t, append([]string{c.script}, c.files...)...)
				c.check(t, k, k.kit+"/", k.home, "")
			})
			t.Run("kit path with a dot segment", func(t *testing.T) {
				k := newSiteKit(t, append([]string{c.script}, c.files...)...)
				c.check(t, k, filepath.Dir(k.kit)+"/./research-sdd", k.home, "")
			})
			t.Run("relative kit path", func(t *testing.T) {
				k := newSiteKit(t, append([]string{c.script}, c.files...)...)
				t.Chdir(filepath.Dir(k.kit))
				c.check(t, k, "research-sdd", filepath.Dir(k.kit), "")
			})
			t.Run("invalid RESEARCH_SDD_KIT is reported on stderr, then the default checkout", func(t *testing.T) {
				k := newSiteKit(t, append([]string{c.script}, c.files...)...)
				bare := filepath.Join(k.home, "bare")
				if err := os.MkdirAll(bare, 0o755); err != nil {
					t.Fatal(err)
				}
				warn := "kit-run: DEGRADED: RESEARCH_SDD_KIT=" + bare + " invalid (no toolbelt/ directory); trying the launcher files and the default checkout\n"
				c.check(t, k, bare, k.home, warn)
			})
		})
	}
}

// A hook run hands stderr to the model as context and a --json run promises one JSON document on stdout: an
// invalid RESEARCH_SDD_KIT changes neither stdout nor the exit code; in a hook run the warning is not printed, in a
// --json run it is on stderr.
func TestSweepKitWarningStaysOutOfStdout(t *testing.T) {
	for _, c := range siteCmds[1:] { // sweep all has no hook or --json mode
		for _, mode := range []string{"--hook", "--json"} {
			t.Run(c.name+" "+mode, func(t *testing.T) {
				k := newSiteKit(t, c.script)
				bare := filepath.Join(k.home, "bare")
				if err := os.MkdirAll(bare, 0o755); err != nil {
					t.Fatal(err)
				}
				wantOut, wantErr, wantRC := k.run(c.run, []string{mode}, "", k.home)
				out, errOut, rc := k.run(c.run, []string{mode}, bare, k.home)
				if out != wantOut || rc != wantRC {
					t.Fatalf("rc=%d stdout %q, want rc=%d stdout %q", rc, out, wantRC, wantOut)
				}
				if out != "" && !json.Valid([]byte(out)) {
					t.Fatalf("stdout is not one JSON document: %q", out)
				}
				warn := "kit-run: DEGRADED: RESEARCH_SDD_KIT=" + bare + " invalid (no toolbelt/ directory); trying the launcher files and the default checkout\n"
				if mode == "--json" {
					warn += wantErr
				} else if wantErr != "" {
					t.Fatalf("the hook baseline wrote stderr: %q", wantErr)
				} else {
					warn = ""
				}
				if errOut != warn {
					t.Fatalf("stderr %q, want %q", errOut, warn)
				}
			})
		}
	}
}
