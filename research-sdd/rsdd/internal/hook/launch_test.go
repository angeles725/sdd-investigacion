package hook

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// launchCase is shared by the table test and the differential test (kit issue #2357).
type launchCase struct {
	name     string
	want     string
	skipRoot bool // permission bits are bypassed for root
	// setup builds the fixture under r and returns the target and the environment (HOME,
	// RSDD_CLAUDE_PROJECTS_DIR, CLAUDE_CONFIG_DIR) the predicate sees.
	setup func(t *testing.T, r string) (target string, env map[string]string)
}

var nonAlnum = regexp.MustCompile(`[^A-Za-z0-9]`)

func encodeDir(p string) string { return nonAlnum.ReplaceAllString(p, "-") }

// transcript makes <hist>/<encoded dir of target>/<file> (a launch record).
func transcript(t *testing.T, hist, target, file string) {
	t.Helper()
	writeFile(t, filepath.Join(hist, encodeDir(target), file), "")
}

// withHist is the common shape: history root r/hist, target r/name, no other variable.
func withHist(name string, build func(t *testing.T, r, target, hist string)) func(t *testing.T, r string) (string, map[string]string) {
	return func(t *testing.T, r string) (string, map[string]string) {
		hist := filepath.Join(r, "hist")
		mkdirs(t, hist)
		target := filepath.Join(r, name)
		if build != nil {
			build(t, r, target, hist)
		}
		return target, map[string]string{"RSDD_CLAUDE_PROJECTS_DIR": hist}
	}
}

func launchCases() []launchCase {
	return []launchCase{
		{name: "27a transcript in the encoded history dir -> launched", want: LaunchLaunched,
			setup: withHist("t27a", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "s1.jsonl") })},
		{name: "27b no history dir for the target -> no-sessions", want: LaunchNoSessions, setup: withHist("t27b", nil)},
		{name: "27c history dir without a transcript -> no-sessions", want: LaunchNoSessions,
			setup: withHist("t27c", func(t *testing.T, _, tg, h string) { mkdirs(t, filepath.Join(h, encodeDir(tg), "memory")) })},
		{name: "27c2 empty history dir -> no-sessions", want: LaunchNoSessions,
			setup: withHist("t27c2", func(t *testing.T, _, tg, h string) { mkdirs(t, filepath.Join(h, encodeDir(tg))) })},
		{name: "27d history root absent -> unknown", want: LaunchUnknown,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				return filepath.Join(r, "t27d"), map[string]string{"RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(r, "no-such-root")}
			}},
		{name: "27e HOME empty and no override -> unknown", want: LaunchUnknown,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				return filepath.Join(r, "t27e"), map[string]string{"HOME": ""}
			}},
		{name: "27f default root is $HOME/.claude/projects", want: LaunchLaunched,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				tg := filepath.Join(r, "t27f")
				transcript(t, filepath.Join(r, "home27f", ".claude", "projects"), tg, "s.jsonl")
				return tg, map[string]string{"HOME": filepath.Join(r, "home27f")}
			}},
		{name: "27g dot, underscore and space encode to '-' -> launched", want: LaunchLaunched,
			setup: withHist("t27g.x_y z", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "a.jsonl") })},
		{name: "27g2 upper-case letters and the digits 0 and 9 encode as themselves -> launched", want: LaunchLaunched,
			setup: withHist("Az09AZ-Zz90", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "a.jsonl") })},
		{name: "27h sessions only in a sub or parent directory -> no-sessions", want: LaunchNoSessions,
			setup: withHist("t27h", func(t *testing.T, r, tg, h string) {
				transcript(t, h, tg+"-sub", "s.jsonl")
				transcript(t, h, filepath.Dir(tg), "s.jsonl")
			})},
		{name: "27i dotdot-collapsed target -> launched", want: LaunchLaunched,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				tg, env := withHist("t27i", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "s.jsonl") })(t, r)
				return tg + "/../t27i/.", env
			}},
		{name: "27j only the last entry is a transcript -> launched", want: LaunchLaunched,
			setup: withHist("t27j", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "a.txt"); transcript(t, h, tg, "z.jsonl") })},
		{name: "27k a non-.jsonl entry alone -> no-sessions", want: LaunchNoSessions,
			setup: withHist("t27k", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "a.jsonl.bak") })},
		{name: "27l non-ASCII path -> unknown", want: LaunchUnknown,
			setup: withHist("t27l-ñ", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "a.jsonl") })},
		{name: "27l2 control character (tab) in the path -> unknown", want: LaunchUnknown,
			setup: withHist("t27l\tx", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "a.jsonl") })},
		{name: "27l3 DEL byte in the path -> unknown", want: LaunchUnknown,
			setup: withHist("t27l\x7fx", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "a.jsonl") })},
		{name: "27l4 newline in the path -> unknown", want: LaunchUnknown,
			setup: withHist("t27l\nx", nil)},
		{name: "27m encoded name of 201 characters -> unknown", want: LaunchUnknown,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				return withHist(strings.Repeat("x", 201-len(r)-1), func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "a.jsonl") })(t, r)
			}},
		{name: "27m2 encoded name of exactly 200 characters is still looked up -> launched", want: LaunchLaunched,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				return withHist(strings.Repeat("x", 200-len(r)-1), func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "a.jsonl") })(t, r)
			}},
		{name: "27o CLAUDE_CONFIG_DIR/projects is the default root", want: LaunchLaunched,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				tg := filepath.Join(r, "t27o")
				transcript(t, filepath.Join(r, "cfg27o", "projects"), tg, "s.jsonl")
				return tg, map[string]string{"CLAUDE_CONFIG_DIR": filepath.Join(r, "cfg27o"), "HOME": filepath.Join(r, "nohome")}
			}},
		{name: "27o2 RSDD_CLAUDE_PROJECTS_DIR wins over CLAUDE_CONFIG_DIR", want: LaunchNoSessions,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				tg := filepath.Join(r, "t27o2")
				transcript(t, filepath.Join(r, "cfg27o", "projects"), tg, "s.jsonl")
				mkdirs(t, filepath.Join(r, "hist"))
				return tg, map[string]string{"RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(r, "hist"), "CLAUDE_CONFIG_DIR": filepath.Join(r, "cfg27o")}
			}},
		{name: "27o3 CLAUDE_CONFIG_DIR wins over HOME", want: LaunchNoSessions,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				tg := filepath.Join(r, "t27o3")
				transcript(t, filepath.Join(r, "h", ".claude", "projects"), tg, "s.jsonl")
				mkdirs(t, filepath.Join(r, "cfg", "projects"))
				return tg, map[string]string{"CLAUDE_CONFIG_DIR": filepath.Join(r, "cfg"), "HOME": filepath.Join(r, "h")}
			}},
		{name: "27p symlinked ancestor component -> unknown", want: LaunchUnknown,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				mkdirs(t, filepath.Join(r, "real27p", "sub"))
				symlink(t, filepath.Join(r, "real27p"), filepath.Join(r, "link27p"))
				return withHist("link27p/sub", nil)(t, r)
			}},
		{name: "27p2 symlinked leaf -> unknown", want: LaunchUnknown,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				mkdirs(t, filepath.Join(r, "real27p", "sub"))
				symlink(t, filepath.Join(r, "real27p", "sub"), filepath.Join(r, "leaf27p"))
				return withHist("leaf27p", nil)(t, r)
			}},
		{name: "27p3 real path next to the symlinks -> no-sessions", want: LaunchNoSessions,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				mkdirs(t, filepath.Join(r, "real27p", "sub"))
				return withHist("real27p/sub", nil)(t, r)
			}},
		{name: "27q a hidden .jsonl entry is not a transcript -> no-sessions", want: LaunchNoSessions,
			setup: withHist("t27q", func(t *testing.T, _, tg, h string) {
				transcript(t, h, tg, ".jsonl")
				transcript(t, h, tg, ".hid.jsonl")
			})},
		{name: "27r a directory named x.jsonl counts like the shell glob -> launched", want: LaunchLaunched,
			setup: withHist("t27r", func(t *testing.T, _, tg, h string) { mkdirs(t, filepath.Join(h, encodeDir(tg), "x.jsonl")) })},
		{name: "27s history root is a file -> unknown", want: LaunchUnknown,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				writeFile(t, filepath.Join(r, "afile"), "")
				return filepath.Join(r, "t27s"), map[string]string{"RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(r, "afile")}
			}},
		{name: "27t unreadable history root -> unknown", want: LaunchUnknown, skipRoot: true,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				hist := filepath.Join(r, "hist27t")
				mkdirs(t, hist)
				if err := os.Chmod(hist, 0o000); err != nil {
					t.Fatal(err)
				}
				return filepath.Join(r, "t27t"), map[string]string{"RSDD_CLAUDE_PROJECTS_DIR": hist}
			}},
		{name: "27u history dir not listable -> no-sessions", want: LaunchNoSessions, skipRoot: true,
			setup: withHist("t27u", func(t *testing.T, _, tg, h string) {
				transcript(t, h, tg, "s.jsonl")
				if err := os.Chmod(filepath.Join(h, encodeDir(tg)), 0o000); err != nil {
					t.Fatal(err)
				}
			})},
		{name: "27v root with a trailing slash -> launched", want: LaunchLaunched,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				tg, env := withHist("t27v", func(t *testing.T, _, tg, h string) { transcript(t, h, tg, "s.jsonl") })(t, r)
				env["RSDD_CLAUDE_PROJECTS_DIR"] += "/"
				return tg, env
			}},
		{name: "27w relative target and relative root are taken from the cwd -> launched", want: LaunchLaunched,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				transcript(t, filepath.Join(r, "hist"), filepath.Join(r, "rel27w"), "s.jsonl")
				return "rel27w", map[string]string{"RSDD_CLAUDE_PROJECTS_DIR": "hist"}
			}},
		{name: "27x empty target is the cwd -> launched", want: LaunchLaunched,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				transcript(t, filepath.Join(r, "hist"), r, "s.jsonl")
				return "", map[string]string{"RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(r, "hist")}
			}},
		{name: "27y the history root being a symlink does not matter -> launched", want: LaunchLaunched,
			setup: func(t *testing.T, r string) (string, map[string]string) {
				tg := filepath.Join(r, "t27y")
				transcript(t, filepath.Join(r, "realhist"), tg, "s.jsonl")
				symlink(t, filepath.Join(r, "realhist"), filepath.Join(r, "linkhist"))
				return tg, map[string]string{"RSDD_CLAUDE_PROJECTS_DIR": filepath.Join(r, "linkhist")}
			}},
	}
}

func TestLaunchState(t *testing.T) {
	for _, tt := range launchCases() {
		t.Run(tt.name, func(t *testing.T) {
			if tt.skipRoot && os.Geteuid() == 0 {
				t.Skip("running as root: permission bits are bypassed")
			}
			r, _ := sandbox(t)
			target, env := tt.setup(t, r)
			if got := LaunchState(envOf(r, env), target); got != tt.want {
				t.Errorf("LaunchState(%q) = %q, want %q", target, got, tt.want)
			}
		})
	}
}

// The documented tokens are part of the contract with verify-registry (kit issue #2357).
func TestLaunchStateTokens(t *testing.T) {
	if LaunchLaunched != "launched" || LaunchNoSessions != "no-sessions" || LaunchUnknown != "unknown" {
		t.Errorf("tokens drifted: %q %q %q", LaunchLaunched, LaunchNoSessions, LaunchUnknown)
	}
}

func TestDifferentialLaunchFixtures(t *testing.T) {
	for _, tt := range launchCases() {
		t.Run(tt.name, func(t *testing.T) {
			if tt.skipRoot && os.Geteuid() == 0 {
				t.Skip("running as root: permission bits are bypassed")
			}
			r, _ := sandbox(t)
			target, env := tt.setup(t, r)
			legacy := map[string]string{envCeiling: filepath.Dir(r), "LC_ALL": "C.utf8"}
			for k, v := range env {
				legacy[k] = v
			}
			want := legacyAsk(t, r, legacy, "launch", target)
			if got := LaunchState(envOf(r, env), target); len(want) != 1 || got != want[0] {
				t.Errorf("LaunchState(%q) = %q, bash says %q", target, got, want)
			}
		})
	}
}
