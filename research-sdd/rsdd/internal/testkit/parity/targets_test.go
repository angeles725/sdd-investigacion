package parity

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// targetFixtures are shared with the bash cross-check. rh is the
// RESEARCH_HOME handed to both parsers.
var targetFixtures = []struct {
	name, body, rh string
	want           []string
}{
	{"single row", "| 1 | a | `/abs/one` |\n", "/home/u", []string{"/abs/one"}},
	{"target first middle last", "| 1 | a | `/abs/first` |\n| 2 | b | `/abs/middle` |\n| 3 | c | `/abs/last` |\n", "/home/u",
		[]string{"/abs/first", "/abs/last", "/abs/middle"}},
	{"RESEARCH_HOME forms", "| 1 | a | `$RESEARCH_HOME/x/one` |\n| 2 | b | `${RESEARCH_HOME}/x/two` |\n", "/data/rh",
		[]string{"/data/rh/x/one", "/data/rh/x/two"}},
	{"RESEARCH_HOME trailing slash", "| 1 | a | `$RESEARCH_HOME/x` |\n", "/data/rh/", []string{"/data/rh/x"}},
	{"prose outside the table ignored", "Prose cites `/not/a/row` here.\n- bullet `/also/not`\n| 1 | a | `/in/table` |\nmore prose `$RESEARCH_HOME/nope`\n", "/h",
		[]string{"/in/table"}},
	{"indented row", "   | 1 | a | `/indented` |\n\t| 2 | b | `/tabbed` |\n", "/h", []string{"/indented", "/tabbed"}},
	{"truncated path inside a row surfaces", "| 1 | a | `/data/some/very/lo...` |\n", "/h", []string{"/data/some/very/lo..."}},
	{"non-path slug passes through", "| 1 | a | `/mrdoob/three.js` |\n", "/h", []string{"/mrdoob/three.js"}},
	{"duplicates collapse and sort", "| 1 | a | `/b` |\n| 2 | b | `/a` |\n| 3 | c | `/b` |\n", "/h", []string{"/a", "/b"}},
	{"two tokens one row", "| 1 | `/p1` | `/p2` | `$RESEARCH_HOME/p3` |\n", "/h", []string{"/h/p3", "/p1", "/p2"}},
	{"non-backticked and relative tokens ignored", "| 1 | a | /bare/path | `relative/path` |\n", "/h", nil},
	{"no rows at all", "just prose\n", "/h", nil},
	{"empty file", "", "/h", nil},
	{"no trailing newline on last row", "| 1 | a | `/last-no-nl` |", "/h", []string{"/last-no-nl"}},
}

func TestParseTargets(t *testing.T) {
	for _, tt := range targetFixtures {
		t.Run(tt.name, func(t *testing.T) {
			f := filepath.Join(t.TempDir(), "TARGETS.md")
			if err := os.WriteFile(f, []byte(tt.body), 0o644); err != nil {
				t.Fatal(err)
			}
			got, err := ParseTargets(f, tt.rh)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tt.want) && !(len(got) == 0 && len(tt.want) == 0) {
				t.Fatalf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestParseTargetsAbsentFileIsAnError(t *testing.T) {
	_, err := ParseTargets(filepath.Join(t.TempDir(), "nope.md"), "/h")
	if err == nil || !strings.Contains(err.Error(), "absent-input") {
		t.Fatalf("an unreadable TARGETS.md must be absent-input, not an empty list: %v", err)
	}
	if _, err := ParseTargets("", "/h"); err == nil {
		t.Fatal("an empty path must be an error")
	}
}

func TestResearchHome(t *testing.T) {
	env := map[string]string{"HOME": "/home/u"}
	get := func(k string) string { return env[k] }
	if got := ResearchHome(get); got != "/home/u" {
		t.Fatalf("falls back to HOME: %q", got)
	}
	env["RESEARCH_HOME"] = "/rh"
	if got := ResearchHome(get); got != "/rh" {
		t.Fatalf("RESEARCH_HOME wins: %q", got)
	}
}
