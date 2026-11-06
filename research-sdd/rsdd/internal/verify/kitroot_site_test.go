package verify

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

// The commands below find the kit without a flag through one resolution that names no script (#2770). Every case
// runs the public command with a hermetic Stdio (HOME in a temp dir, so no launcher file of the real home is
// read) and compares stdout, stderr and the exit code together.

// siteKit is a kit at <home>/investigacion/sdd-investigacion/research-sdd (the default checkout) with a toolbelt/
// directory and the named files (empty unless siteBodies holds a body).
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
	if err := os.MkdirAll(filepath.Join(k.kit, "toolbelt"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		p := filepath.Join(k.kit, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(siteBodies[f]), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return k
}

// run executes the command with RESEARCH_SDD_KIT=kitEnv and the working directory cwd.
func (k siteKit) run(run func([]string, cli.Stdio) int, args []string, kitEnv, cwd string) (out, errOut string, rc int) {
	env := map[string]string{"HOME": k.home, "RESEARCH_HOME": filepath.Join(k.home, "rh"), "PATH": filepath.Join(k.home, "nobin"),
		"RESEARCH_SDD_KIT": kitEnv, "RESEARCH_SDD_KIT_STALE_CHECK": "off", "TMPDIR": k.home}
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
	args   func(siteKit) []string
	script string   // the legacy script the command used to name
	files  []string // what else the command needs under the kit
	out    string   // the expected stdout: "@K@" the kit root, "@T@" its toolbelt, "@P@" its parent, "@H@" the home
	err    string   // the expected stderr
	rc     int
	warn   bool // the invalid-RESEARCH_SDD_KIT line is printed on stderr
}

func (c siteCmd) want(k siteKit, text string) string {
	r := strings.NewReplacer("@T@", k.kit+"/toolbelt", "@K@", k.kit, "@P@", filepath.Dir(k.kit), "@H@", k.home)
	return r.Replace(text)
}

func (c siteCmd) check(t *testing.T, k siteKit, kitEnv, cwd, warn string) {
	t.Helper()
	var args []string
	if c.args != nil {
		args = c.args(k)
	}
	out, errOut, rc := k.run(c.run, args, kitEnv, cwd)
	if !c.warn {
		warn = ""
	}
	if out != c.want(k, c.out) || errOut != warn+c.want(k, c.err) || rc != c.rc {
		t.Fatalf("got rc=%d\nstdout %q\nstderr %q\nwant rc=%d\nstdout %q\nstderr %q", rc, out, errOut, c.rc, c.want(k, c.out), warn+c.want(k, c.err))
	}
}

func TestKitFoundWithoutAFlag(t *testing.T) {
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
			t.Run("invalid RESEARCH_SDD_KIT: the line is on stderr, the output and exit code are the same", func(t *testing.T) {
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

var siteBodies = map[string]string{"TARGETS.md": "# targets\n"}

var siteCmds = []siteCmd{
	{name: "registry", run: RunRegistry, script: "toolbelt/verify-registry.sh", files: []string{"TARGETS.md"}, warn: true, rc: 0, err: "verify-registry: ERROR — no usable target paths in @K@/TARGETS.md\nverify-registry: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
	{name: "skill-drift", run: RunSkillDrift, script: "toolbelt/verify-skill-drift.sh", files: []string{"install/keep"}, warn: true, rc: 2, err: "verify-skill-drift: ERROR: adapters.sh not found: @K@/install/adapters.sh\n"},
}

// An invalid RESEARCH_SDD_KIT changes neither the stdout nor the exit code of a --json or --hook run; the line is on
// stderr (the hook of skill-drift writes its own stderr apart from the context it hands the model).
func TestKitWarningStaysOutOfStdout(t *testing.T) {
	for _, c := range siteCmds {
		mode := map[string]string{"registry": "--json", "skill-drift": "--hook"}[c.name]
		t.Run(c.name+" "+mode, func(t *testing.T) {
			k := newSiteKit(t, append([]string{c.script}, c.files...)...)
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
			if errOut != warn+wantErr {
				t.Fatalf("stderr %q, want %q", errOut, warn+wantErr)
			}
		})
	}
}
