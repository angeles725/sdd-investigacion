package kit

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// memKit is an in-memory KitFS: dirs and files are sets of absolute paths.
func memKit(dirs []string, files map[string]string) KitFS {
	ds := map[string]bool{}
	for _, d := range dirs {
		ds[d] = true
	}
	return KitFS{
		IsDir:  func(p string) bool { return ds[p] },
		IsFile: func(p string) bool { _, ok := files[p]; return ok || ds[p+"#file"] },
		ReadFile: func(p string) ([]byte, error) {
			if s, ok := files[p]; ok {
				return []byte(s), nil
			}
			return nil, os.ErrNotExist
		},
	}
}

func TestResolveKitOrder(t *testing.T) {
	const home = "/home/u"
	def := home + "/investigacion/sdd-investigacion/research-sdd"
	launcher := func(body string) map[string]string { return map[string]string{home + "/.claude/CLAUDE.md": body} }
	cases := []struct {
		name   string
		env    map[string]string
		dirs   []string
		files  map[string]string
		want   string
		source string
		notes  int
	}{
		{"1 env wins", map[string]string{"RESEARCH_SDD_KIT": "/k/env"}, []string{"/k/env/toolbelt", "/k/launch/toolbelt", def + "/toolbelt"}, launcher("Kit path: /k/launch\n"), "/k/env", "env", 0},
		{"2 launcher beats default", nil, []string{"/k/launch/toolbelt", def + "/toolbelt"}, launcher("Kit path: /k/launch\n"), "/k/launch", "launcher:" + home + "/.claude/CLAUDE.md", 0},
		{"3 default", nil, []string{def + "/toolbelt"}, nil, def, "default", 0},
		{"4 invalid env is reported then falls through", map[string]string{"RESEARCH_SDD_KIT": "/k/bad"}, []string{def + "/toolbelt"}, nil, def, "default", 1},
		{"5 Kit checkout is read before Kit path in the same file", nil, []string{"/k/co/toolbelt", "/k/p/toolbelt"}, launcher("Kit path: /k/p\nKit checkout: /k/co\n"), "/k/co", "launcher:" + home + "/.claude/CLAUDE.md", 0},
		{"6 backticks and tilde", nil, []string{home + "/kit/toolbelt"}, launcher("Kit path: `~/kit`\n"), home + "/kit", "launcher:" + home + "/.claude/CLAUDE.md", 0},
		{"7 first matching line only, trimmed", nil, []string{"/k/a/toolbelt", "/k/b/toolbelt"}, launcher("Kit path:   /k/a  \t\nKit path: /k/b\n"), "/k/a", "launcher:" + home + "/.claude/CLAUDE.md", 0},
		{"8 value-less line stops the scan of that key", nil, []string{"/k/b/toolbelt", def + "/toolbelt"}, launcher("Kit path:\nKit path: /k/b\n"), def, "default", 0},
		{"9 no trailing newline", nil, []string{"/k/last/toolbelt"}, launcher("x\nKit path: /k/last"), "/k/last", "launcher:" + home + "/.claude/CLAUDE.md", 0},
		{"10 GENTLE_PI first, then PI dir, then fixed files", map[string]string{"GENTLE_PI_AGENT_HOME": "/g", "PI_CODING_AGENT_DIR": "/p"},
			[]string{"/k/g/toolbelt", "/k/p/toolbelt", "/k/gs/toolbelt"},
			map[string]string{"/g/AGENTS.md": "Kit path: /k/g\n", "/p/AGENTS.md": "Kit path: /k/p\n", home + "/.gentle-shell/agent/AGENTS.md": "Kit path: /k/gs\n"}, "/k/g", "launcher:/g/AGENTS.md", 0},
		{"11 later launcher when the first names a dead kit", map[string]string{"PI_CODING_AGENT_DIR": "/p"}, []string{"/k/ok/toolbelt"},
			map[string]string{"/p/AGENTS.md": "Kit path: /k/dead\n", home + "/.pi/agent/AGENTS.md": "Kit path: /k/ok\n"}, "/k/ok", "launcher:" + home + "/.pi/agent/AGENTS.md", 0},
	}
	for _, c := range cases {
		env := map[string]string{"HOME": home}
		for k, v := range c.env {
			env[k] = v
		}
		got, err := ResolveKit(envOf(env), memKit(c.dirs, c.files))
		if err != nil || got.Path != c.want || got.Source != c.source || len(got.Notes) != c.notes {
			t.Errorf("%s: %+v err=%v", c.name, got, err)
		}
	}
	// invalid env note text
	got, _ := ResolveKit(envOf(map[string]string{"HOME": home, "RESEARCH_SDD_KIT": "/k/bad"}), memKit([]string{def + "/toolbelt"}, nil))
	if len(got.Notes) != 1 || got.Notes[0] != "kit-run: DEGRADED: RESEARCH_SDD_KIT=/k/bad invalid (no toolbelt/ directory); trying the launcher files and the default checkout" {
		t.Errorf("note: %q", got.Notes)
	}
}

func TestResolveKitNothingResolvesIsTypedDegraded(t *testing.T) {
	_, err := ResolveKit(envOf(map[string]string{"HOME": "/h"}), memKit(nil, nil))
	if !errors.Is(err, ErrKitDegraded) || err.Error() != "kit-run: DEGRADED: research-sdd kit not found (set RESEARCH_SDD_KIT)" {
		t.Errorf("%v", err)
	}
}

func TestResolveKitScriptValidation(t *testing.T) {
	const kit = "/k/ok"
	fs := memKit([]string{kit + "/toolbelt"}, map[string]string{kit + "/toolbelt/x.sh": ""})
	env := envOf(map[string]string{"HOME": "/h", "RESEARCH_SDD_KIT": kit})
	if r, err := ResolveKitScript("toolbelt/x.sh", env, fs); err != nil || r.Path != kit {
		t.Errorf("ok: %+v %v", r, err)
	}
	for rel, want := range map[string]string{
		"":                 "kit-run: DEGRADED: no script given",
		"/abs/x.sh":        "kit-run: DEGRADED: script path '/abs/x.sh' must be kit-relative without '..'; /abs/x.sh did NOT run",
		"../x.sh":          "kit-run: DEGRADED: script path '../x.sh' must be kit-relative without '..'; ../x.sh did NOT run",
		"a/../x.sh":        "kit-run: DEGRADED: script path 'a/../x.sh' must be kit-relative without '..'; a/../x.sh did NOT run",
		"a/..":             "kit-run: DEGRADED: script path 'a/..' must be kit-relative without '..'; a/.. did NOT run",
		"toolbelt/none.sh": "kit-run: DEGRADED: " + kit + "/toolbelt/none.sh is missing; toolbelt/none.sh did NOT run",
	} {
		_, err := ResolveKitScript(rel, env, fs)
		if !errors.Is(err, ErrKitDegraded) || err.Error() != want {
			t.Errorf("%q: %v", rel, err)
		}
	}
	// a name that merely CONTAINS dots is fine
	if _, err := ResolveKitScript("toolbelt/..x.sh", env, memKit([]string{kit + "/toolbelt"}, map[string]string{kit + "/toolbelt/..x.sh": ""})); err != nil {
		t.Errorf("dotted name: %v", err)
	}
	if _, err := ResolveKitScript("toolbelt/x.sh", envOf(map[string]string{"HOME": "/h"}), memKit(nil, nil)); !errors.Is(err, ErrKitDegraded) ||
		!strings.HasSuffix(err.Error(), "; toolbelt/x.sh did NOT run") {
		t.Errorf("unresolved kit: %v", err)
	}
}

// The real template, run for real in a fake HOME, must choose the same kit as ResolveKit over the same disk.
func TestDifferentialKitRun(t *testing.T) {
	mkKit := func(root string) string {
		write(t, filepath.Join(root, "toolbelt", "id.sh"), "echo KIT=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"\n")
		return root
	}
	type sc struct {
		name  string
		build func(home, tmp string) map[string]string // returns extra env
		rel   string
	}
	scenarios := []sc{
		{"env", func(h, tmp string) map[string]string { return map[string]string{"RESEARCH_SDD_KIT": mkKit(tmp + "/e")} }, "toolbelt/id.sh"},
		{"invalid-env-then-default", func(h, tmp string) map[string]string {
			mkKit(h + "/investigacion/sdd-investigacion/research-sdd")
			return map[string]string{"RESEARCH_SDD_KIT": tmp + "/none"}
		}, "toolbelt/id.sh"},
		{"claude-launcher-backtick-tilde", func(h, tmp string) map[string]string {
			mkKit(h + "/lk")
			write(t, h+"/.claude/CLAUDE.md", "x\nKit path: `~/lk`\n")
			return nil
		}, "toolbelt/id.sh"},
		{"checkout-before-path", func(h, tmp string) map[string]string {
			mkKit(tmp + "/co")
			mkKit(tmp + "/pa")
			write(t, h+"/.pi/agent/AGENTS.md", "Kit path: "+tmp+"/pa\nKit checkout: "+tmp+"/co\n")
			return nil
		}, "toolbelt/id.sh"},
		{"gentle-pi-first", func(h, tmp string) map[string]string {
			mkKit(tmp + "/g")
			mkKit(tmp + "/s")
			write(t, tmp+"/gh/AGENTS.md", "Kit path: "+tmp+"/g\n")
			write(t, h+"/.gentle-shell/agent/AGENTS.md", "Kit path: "+tmp+"/s\n")
			return map[string]string{"GENTLE_PI_AGENT_HOME": tmp + "/gh"}
		}, "toolbelt/id.sh"},
		{"valueless-line", func(h, tmp string) map[string]string {
			mkKit(tmp + "/b")
			write(t, h+"/.claude/CLAUDE.md", "Kit path:\nKit path: "+tmp+"/b\n")
			return nil
		}, "toolbelt/id.sh"},
		{"nothing", func(h, tmp string) map[string]string { return nil }, "toolbelt/id.sh"},
		{"missing-script", func(h, tmp string) map[string]string { return map[string]string{"RESEARCH_SDD_KIT": mkKit(tmp + "/e")} }, "toolbelt/zz.sh"},
		{"dotdot", func(h, tmp string) map[string]string { return map[string]string{"RESEARCH_SDD_KIT": mkKit(tmp + "/e")} }, "toolbelt/../x.sh"},
		{"absolute", func(h, tmp string) map[string]string { return nil }, "/etc/passwd"},
	}
	for _, s := range scenarios {
		t.Run(s.name, func(t *testing.T) {
			tmp := physical(t, t.TempDir())
			home := tmp + "/home"
			extra := s.build(home, tmp)
			env := map[string]string{"HOME": home}
			for k, v := range extra {
				env[k] = v
			}
			b := bashDriver(t, env, "", "kitrun", s.rel)
			res, err := ResolveKitScript(s.rel, envOf(env), OSKitFS)
			var gotErr, gotOut string
			rc := 0
			if err != nil {
				gotErr, rc = err.Error()+"\n", 1
			} else {
				gotErr = strings.Join(res.Notes, "\n")
				if gotErr != "" {
					gotErr += "\n"
				}
				gotOut = fmt.Sprintf("KIT=%s\n", res.Path)
			}
			if err != nil {
				gotErr = strings.Join(res.Notes, "\n") + map[bool]string{true: "\n", false: ""}[len(res.Notes) > 0] + gotErr
			}
			if rc != b.rc || gotOut != b.stdout || gotErr != b.stderr {
				t.Errorf("go rc=%d out=%q err=%q\nbash rc=%d out=%q err=%q", rc, gotOut, gotErr, b.rc, b.stdout, b.stderr)
			}
		})
	}
}
