package kit

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Ports of the kit-resolution order of templates/hook-kit-run.sh (kit #2175) and toolbelt/tests/hook-kit-run.test.sh.

// kitEnv is one resolution scenario: a scratch HOME with optional launcher files and kit checkouts.
type kitEnv struct {
	t    *testing.T
	home string
	env  map[string]string
}

func newKitEnv(t *testing.T) *kitEnv {
	h := physical(t, t.TempDir())
	return &kitEnv{t, h, map[string]string{"HOME": h}}
}

// kit creates a checkout with a toolbelt/ directory (and the probe script) and returns its path.
func (e *kitEnv) kit(rel string) string {
	p := filepath.Join(e.home, rel)
	write(e.t, p+"/toolbelt/probe.sh", "printf '%s\\n' \"$0\"\n")
	return p
}

func (e *kitEnv) launcher(rel, content string) { write(e.t, filepath.Join(e.home, rel), content) }

type kitCase struct {
	label  string
	setup  func(e *kitEnv)
	rel    string
	want   string // kit path relative to HOME, "" when resolution fails
	warns  int
	reason string // the degraded <why> ("" on success); "$H" stands for HOME
}

// kitCases is shared with the differential test.
var kitCases = []kitCase{
	{"env var wins", func(e *kitEnv) {
		e.env["RESEARCH_SDD_KIT"] = e.kit("envkit")
		e.kit("investigacion/sdd-investigacion/research-sdd")
	}, "toolbelt/probe.sh", "envkit", 0, ""},
	{"invalid env var is reported, then the default", func(e *kitEnv) {
		e.env["RESEARCH_SDD_KIT"] = e.home + "/nokit"
		e.kit("investigacion/sdd-investigacion/research-sdd")
	}, "toolbelt/probe.sh", "investigacion/sdd-investigacion/research-sdd", 1, ""},
	{"gentle-pi launcher, backticks and tilde", func(e *kitEnv) {
		e.kit("k2")
		e.env["GENTLE_PI_AGENT_HOME"] = e.home + "/gp"
		e.launcher("gp/AGENTS.md", "# x\nKit checkout:   `~/k2`  \n")
	}, "toolbelt/probe.sh", "k2", 0, ""},
	{"pi dir launcher, Kit path key", func(e *kitEnv) {
		e.kit("k3")
		e.env["PI_CODING_AGENT_DIR"] = e.home + "/pi"
		e.launcher("pi/AGENTS.md", "Kit path: "+e.home+"/k3\t\n")
	}, "toolbelt/probe.sh", "k3", 0, ""},
	{"only the first key line counts", func(e *kitEnv) {
		e.kit("k4")
		e.kit("investigacion/sdd-investigacion/research-sdd")
		e.launcher(".claude/CLAUDE.md", "Kit checkout:   \nKit checkout: ~/k4\n")
	}, "toolbelt/probe.sh", "investigacion/sdd-investigacion/research-sdd", 0, ""},
	{"Kit checkout is tried before Kit path in one file", func(e *kitEnv) {
		e.kit("kp")
		e.kit("kc")
		e.launcher(".claude/CLAUDE.md", "Kit path: ~/kp\nKit checkout: ~/kc\n")
	}, "toolbelt/probe.sh", "kc", 0, ""},
	{"a candidate without toolbelt falls through, file order", func(e *kitEnv) {
		e.kit("k5")
		e.launcher(".gentle-shell/agent/AGENTS.md", "Kit checkout: ~/missing\n")
		e.launcher(".pi/agent/AGENTS.md", "  Kit checkout: ~/indented-is-ignored\n")
		e.launcher(".claude/CLAUDE.md", "Kit path: ~/k5\n")
	}, "toolbelt/probe.sh", "k5", 0, ""},
	{"the gentle-shell launcher precedes the pi one and CLAUDE.md", func(e *kitEnv) {
		e.kit("ka")
		e.kit("kb")
		e.kit("kc")
		e.launcher(".claude/CLAUDE.md", "Kit checkout: ~/kc\n")
		e.launcher(".pi/agent/AGENTS.md", "Kit checkout: ~/kb\n")
		e.launcher(".gentle-shell/agent/AGENTS.md", "Kit checkout: ~/ka\n")
	}, "toolbelt/probe.sh", "ka", 0, ""},
	{"the pi launcher precedes CLAUDE.md", func(e *kitEnv) {
		e.kit("kb")
		e.kit("kc")
		e.launcher(".claude/CLAUDE.md", "Kit checkout: ~/kc\n")
		e.launcher(".pi/agent/AGENTS.md", "Kit checkout: ~/kb\n")
	}, "toolbelt/probe.sh", "kb", 0, ""},
	{"a tilde not followed by a slash still expands", func(e *kitEnv) {
		e.env["HOME"] = e.home + "/h" // ~x/k is $HOME + "x/k"
		e.kit("hx/k")
		e.launcher("h/.claude/CLAUDE.md", "Kit path: ~x/k\n")
	}, "toolbelt/probe.sh", "hx/k", 0, ""},
	{"nothing resolves", func(e *kitEnv) {}, "toolbelt/probe.sh", "", 0, "research-sdd kit not found (set RESEARCH_SDD_KIT)"},
	{"nothing resolves after an invalid env var", func(e *kitEnv) { e.env["RESEARCH_SDD_KIT"] = "rel/nokit" }, "toolbelt/probe.sh", "", 1, "research-sdd kit not found (set RESEARCH_SDD_KIT)"},
	{"missing script", func(e *kitEnv) { e.kit("investigacion/sdd-investigacion/research-sdd") }, "toolbelt/none.sh", "", 0, "$H/investigacion/sdd-investigacion/research-sdd/toolbelt/none.sh is missing"},
	{"absolute script", func(e *kitEnv) { e.env["RESEARCH_SDD_KIT"] = "/nokit" }, "/etc/x.sh", "", 0, "script path '/etc/x.sh' must be kit-relative without '..'"},
	{"dot-dot script", func(e *kitEnv) { e.kit("investigacion/sdd-investigacion/research-sdd") }, "toolbelt/../../x.sh", "", 0, "script path 'toolbelt/../../x.sh' must be kit-relative without '..'"},
	{"a dot-dot inside a name is fine", func(e *kitEnv) {
		k := e.kit("investigacion/sdd-investigacion/research-sdd")
		write(e.t, k+"/toolbelt/a..b.sh", "printf '%s\\n' \"$0\"\n")
	}, "toolbelt/a..b.sh", "investigacion/sdd-investigacion/research-sdd", 0, ""},
}

func TestResolveKitScript(t *testing.T) {
	for _, c := range kitCases {
		t.Run(c.label, func(t *testing.T) {
			e := newKitEnv(t)
			c.setup(e)
			got, warns, err := ResolveKitScript(c.rel, envOf(e.env))
			want := ""
			if c.want != "" {
				want = e.home + "/" + c.want + "/" + c.rel
			}
			reason := ""
			if err != nil {
				reason = err.Error()
			}
			if got != want || len(warns) != c.warns || reason != expandH(c.reason, e.home) {
				t.Fatalf("got %q warns=%q err=%q, want %q (%d warns) %q", got, warns, reason, want, c.warns, c.reason)
			}
			if err != nil && !errors.Is(err, ErrKitUnresolved) {
				t.Fatalf("not typed: %v", err)
			}
		})
	}
}

func expandH(s, home string) string {
	if len(s) >= 2 && s[:2] == "$H" {
		return home + s[2:]
	}
	return s
}

func TestResolveKitScriptNoScript(t *testing.T) {
	if _, _, err := ResolveKitScript("", envOf(nil)); !errors.Is(err, ErrUsage) || err.Error() != "no script given" {
		t.Fatalf("%v", err)
	}
}

func TestKitCandidatesOrder(t *testing.T) {
	e := newKitEnv(t)
	e.env["RESEARCH_SDD_KIT"] = "/env"
	e.env["GENTLE_PI_AGENT_HOME"] = e.home + "/gp"
	e.launcher("gp/AGENTS.md", "Kit checkout: /a\nKit path: /b\n")
	e.launcher(".claude/CLAUDE.md", "Kit path: /c\n")
	if err := os.MkdirAll(e.home+"/.pi/agent/AGENTS.md", 0o755); err != nil { // a directory is not [ -f ]
		t.Fatal(err)
	}
	want := []string{"/env", "/a", "/b", "/c", e.home + "/investigacion/sdd-investigacion/research-sdd"}
	if got := kitCandidates(envOf(e.env)); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}
