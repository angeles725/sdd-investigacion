package hook

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

const stopWired = `{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}`

// wiringCase is shared by the table test and the differential test.
type wiringCase struct {
	name     string
	setup    func(t *testing.T, r string) string // returns the target as the caller spells it
	want     string
	skipRoot bool // permission bits do not bind root
}

func settingsAt(rel, json string) func(t *testing.T, r string) string {
	return func(t *testing.T, r string) string {
		d := filepath.Join(r, rel)
		mkdirs(t, d)
		wireSettings(t, d, json)
		return d
	}
}

func nestedInRepo(json string) func(t *testing.T, r string) string {
	return func(t *testing.T, r string) string {
		gitInit(t, filepath.Join(r, "root"))
		d := filepath.Join(r, "root", "nested")
		mkdirs(t, d)
		if json != "" {
			wireSettings(t, d, json)
		}
		return d
	}
}

func wiringCases() []wiringCase {
	return []wiringCase{
		{name: "1 no settings.json -> absent-settings", want: WiringAbsentSettings,
			setup: func(t *testing.T, r string) string { d := filepath.Join(r, "t1"); mkdirs(t, d); return d }},
		{name: "2 Stop registers retro-gate -> wired", want: WiringWired, setup: settingsAt("t2", stopWired)},
		{name: "3 Stop present, no retro-gate -> unwired", want: WiringUnwired,
			setup: settingsAt("t3", `{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/other-hook.sh"}]}]}}`)},
		{name: "4 retro-gate under SessionStart only -> unwired", want: WiringUnwired,
			setup: settingsAt("t4", `{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"/x/retro-gate.sh"}]}]}}`)},
		{name: "5 retro-gate in permissions.deny -> unwired", want: WiringUnwired,
			setup: settingsAt("t5", `{"permissions":{"deny":["Bash(retro-gate:*)"]},"hooks":{"Stop":[]}}`)},
		{name: "6 unreadable settings.json -> unreadable", want: WiringUnreadable, skipRoot: true,
			setup: func(t *testing.T, r string) string {
				d := settingsAt("t6", `{"hooks":{"Stop":[]}}`)(t, r)
				if err := os.Chmod(filepath.Join(d, ".claude", "settings.json"), 0); err != nil {
					t.Fatal(err)
				}
				return d
			}},
		{name: "7 non-existent target -> absent-settings", want: WiringAbsentSettings,
			setup: func(t *testing.T, r string) string { return filepath.Join(r, "t7-absent") }},
		{name: "8 own git root, wired -> wired", want: WiringWired,
			setup: func(t *testing.T, r string) string {
				d := settingsAt("t8", stopWired)(t, r)
				gitInit(t, d)
				return d
			}},
		{name: "9 nested non-root, wired -> wired-off-root", want: WiringWiredOffRoot, setup: nestedInRepo(stopWired)},
		{name: "10 nested non-root, unwired -> unwired", want: WiringUnwired,
			setup: nestedInRepo(`{"hooks":{"Stop":[{"hooks":[{"command":"/x/other-hook.sh"}]}]}}`)},
		{name: "11 nested non-root, no settings -> absent-settings", want: WiringAbsentSettings, setup: nestedInRepo("")},
		{name: "12 no git repository at all, wired -> wired", want: WiringWired, setup: settingsAt("t12", stopWired)},
		{name: "14a leaf symlink to a nested dir stays wired (documented limitation)", want: WiringWired,
			setup: func(t *testing.T, r string) string {
				gitInit(t, filepath.Join(r, "Q"))
				real := filepath.Join(r, "Q", "z")
				mkdirs(t, real)
				wireSettings(t, real, stopWired)
				link := filepath.Join(r, "link14a")
				symlink(t, real, link)
				return link
			}},
		{name: "14b leaf symlink to a git root stays wired", want: WiringWired,
			setup: func(t *testing.T, r string) string {
				real := filepath.Join(r, "Q", "y")
				gitInit(t, real)
				wireSettings(t, real, stopWired)
				link := filepath.Join(r, "link14b")
				symlink(t, real, link)
				return link
			}},
		{name: "16 dotdot distractor stays wired", want: WiringWired,
			setup: func(t *testing.T, r string) string {
				gitInit(t, filepath.Join(r, "A", "B"))
				wireSettings(t, filepath.Join(r, "A"), stopWired)
				return filepath.Join(r, "A", "B", "..")
			}},
		{name: "18 symlink before dotdot onto a real root stays wired", want: WiringWired,
			setup: func(t *testing.T, r string) string {
				gitInit(t, filepath.Join(r, "P"))
				q := filepath.Join(r, "Q", "y")
				gitInit(t, q)
				mkdirs(t, filepath.Join(q, "z"), filepath.Join(r, "P", "sub"))
				wireSettings(t, q, stopWired)
				symlink(t, filepath.Join(q, "z"), filepath.Join(r, "P", "sub", "link"))
				return filepath.Join(r, "P", "sub", "link") + "/.."
			}},
		{name: "19 embedded newline nested in a repo -> wired-off-root", want: WiringWiredOffRoot,
			setup: func(t *testing.T, r string) string {
				gitInit(t, filepath.Join(r, "t19"))
				gitInit(t, filepath.Join(r, "t19", "a"))
				d := filepath.Join(r, "t19", "a\nb")
				mkdirs(t, d)
				wireSettings(t, d, stopWired)
				return d
			}},
		{name: "dangling settings.json symlink -> absent-settings", want: WiringAbsentSettings,
			setup: func(t *testing.T, r string) string {
				d := filepath.Join(r, "dangling")
				mkdirs(t, filepath.Join(d, ".claude"))
				symlink(t, filepath.Join(r, "nowhere"), filepath.Join(d, ".claude", "settings.json"))
				return d
			}},
		{name: "settings.json is a directory -> unwired (awk reads no record)", want: WiringUnwired,
			setup: func(t *testing.T, r string) string {
				d := filepath.Join(r, "dirsettings")
				mkdirs(t, filepath.Join(d, ".claude", "settings.json"))
				return d
			}},
		{name: "pretty-printed Stop block spanning lines -> wired", want: WiringWired,
			setup: settingsAt("pretty", "{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\"command\": \"/x/retro-gate.sh\"}\n        ]\n      }\n    ]\n  }\n}\n")},
		{name: "Stop key with blanks before the colon -> wired", want: WiringWired,
			setup: settingsAt("blanks", "{\"hooks\":{\"Stop\" \t :[{\"command\":\"retro-gate\"}]}}")},
		{name: "colon on the next line is not seen -> unwired (line-bound scan)", want: WiringUnwired,
			setup: settingsAt("nextline", "{\"hooks\":{\"Stop\"\n:[{\"command\":\"retro-gate\"}]}}")},
		{name: "retro-gate after the Stop block closed -> unwired", want: WiringUnwired,
			setup: settingsAt("after", `{"hooks":{"Stop":[{"command":"x"}],"Other":[{"command":"retro-gate"}]}}`)},
		{name: "a second Stop key after the first closed -> wired", want: WiringWired,
			setup: settingsAt("second", `{"a":{"Stop":[]},"b":{"Stop":[{"command":"retro-gate"}]}}`)},
		{name: "Stop not followed by a colon swallows the next char -> unwired", want: WiringUnwired,
			setup: settingsAt("nocolon", `{"Stop"[{"command":"retro-gate"}]}`)},
		{name: "CRLF line endings -> wired", want: WiringWired,
			setup: settingsAt("crlf", "{\r\n\"hooks\":{\"Stop\":[{\"command\":\"retro-gate\"}]}\r\n}\r\n")},
		{name: "retro-gat prefix only -> unwired", want: WiringUnwired,
			setup: settingsAt("prefix", `{"hooks":{"Stop":[{"command":"retro-gat"}]}}`)},
		{name: "empty settings.json -> unwired", want: WiringUnwired, setup: settingsAt("empty", "")},
	}
}

func TestWiringState(t *testing.T) {
	for _, tt := range wiringCases() {
		t.Run(tt.name, func(t *testing.T) {
			if tt.skipRoot && os.Geteuid() == 0 {
				t.Skip("running as root: permission bits are bypassed")
			}
			r, e := sandbox(t)
			target := tt.setup(t, r)
			if got := WiringState(e, target); got != tt.want {
				t.Errorf("WiringState(%q) = %q, want %q", target, got, tt.want)
			}
		})
	}
}

func TestWiringStateRelativeTargets(t *testing.T) {
	// 15a/15b/15c: a relative target must terminate and resolve against the cwd.
	tests := []struct {
		name, cwd, target, want string
		setup                   func(t *testing.T, r string)
	}{
		{"15a dot at own root", "a", ".", WiringWired, func(t *testing.T, r string) {
			gitInit(t, filepath.Join(r, "a"))
			wireSettings(t, filepath.Join(r, "a"), stopWired)
		}},
		{"15b bare name, no repo", ".", "bare", WiringWired, func(t *testing.T, r string) {
			wireSettings(t, filepath.Join(r, "bare"), stopWired)
		}},
		{"15c nested inside a repo", "repo", "nested", WiringWiredOffRoot, func(t *testing.T, r string) {
			gitInit(t, filepath.Join(r, "repo"))
			wireSettings(t, filepath.Join(r, "repo", "nested"), stopWired)
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r, _ := sandbox(t)
			tt.setup(t, r)
			e := envOf(filepath.Join(r, tt.cwd), map[string]string{envCeiling: filepath.Dir(r)})
			if got := WiringState(e, tt.target); got != tt.want {
				t.Errorf("WiringState(cwd=%s, %q) = %q, want %q", tt.cwd, tt.target, got, tt.want)
			}
		})
	}
}

func TestWiringStateReadFailureIsUnwired(t *testing.T) {
	// The bash predicate reads the file through awk and treats an awk failure as "no Stop entry".
	r, e := sandbox(t)
	d := settingsAt("rf", stopWired)(t, r)
	e.ReadFile = func(string) ([]byte, error) { return nil, errors.New("boom") }
	if got := WiringState(e, d); got != WiringUnwired {
		t.Errorf("WiringState with a failing read = %q, want %q", got, WiringUnwired)
	}
}

func TestWiringStateDowngradeOnlyAppliesToWired(t *testing.T) {
	// 10/11 cover unwired and absent; a failing read of a nested target must not downgrade either.
	r, e := sandbox(t)
	d := nestedInRepo(stopWired)(t, r)
	e.ReadFile = func(string) ([]byte, error) { return nil, errors.New("boom") }
	if got := WiringState(e, d); got != WiringUnwired {
		t.Errorf("nested target with a failing read = %q, want %q", got, WiringUnwired)
	}
}
