package stageissues

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Mutation-killing unit tests of exec.go, gh.go, repo.go, run.go and unc.go (kit issue #2592). They call the helpers
// directly, carry no build tag and run no bash of their own, so the -tags nodiff mutation run executes them.

func TestOSExecExitCodes(t *testing.T) {
	run := osExec(nil, t.TempDir(), "/usr/bin:/bin")
	if r := run("sh", []string{"-c", "exit 3"}, false); r.RC != 3 || r.NotFound {
		t.Errorf("exit 3: %+v", r)
	}
	if r := run("sh", []string{"-c", "echo hi"}, false); r.RC != 0 || r.Out != "hi\n" {
		t.Errorf("exit 0: %+v", r)
	}
	if r := run("sh", []string{"-c", "kill -9 $$"}, false); r.RC != 255 {
		t.Errorf("killed by a signal: RC = %d, want 255", r.RC)
	}
	if r := run("no-such-program-for-teeth", nil, false); r.RC != 127 || !r.NotFound {
		t.Errorf("missing program: %+v", r)
	}
}

func TestLabelFlags(t *testing.T) {
	for _, c := range []struct {
		in   string
		want []string
	}{
		{"a,b", []string{"--label", "a", "--label", "b"}},
		{"a,b,", []string{"--label", "a", "--label", "b"}}, // one trailing comma is dropped
		{"a,,", []string{"--label", "a", "--label", ""}},   // only the last empty piece
		{"it's", []string{"--label", `it'\''s`}},
		{"", nil},
	} {
		if got := labelFlags(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("labelFlags(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLastLine(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"a\nb", "b"},
		{"\nfoo", "foo"}, // the newline is the first byte
		{"abc", "abc"},
		{"a\n", ""},
		{"", ""},
	} {
		if got := lastLine(c.in); got != c.want {
			t.Errorf("lastLine(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLowerASCIIRange(t *testing.T) {
	if got, want := lowerASCII("AZaz@[`{ÀZ"), "azaz@[`{Àz"; got != want {
		t.Errorf("lowerASCII = %q, want %q", got, want)
	}
}

func TestNormalizeRemotePortAtStartOfHost(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"https://:80/owner/repo", "/owner/repo"}, // the port separator is the first byte of the host
		{"https://example.com:8443/owner/repo.git", "example.com/owner/repo"},
		{"https://github.com:443/owner/repo", "owner/repo"},
		{"git@github.com:owner/repo.git", "owner/repo"},
	} {
		if got := normalizeRemote(c.in); got != c.want {
			t.Errorf("normalizeRemote(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// git prints the toplevel relative to the process cwd here; the kit root is compared as an absolute path.
func TestResolveRepoAbsolutisesTheToplevel(t *testing.T) {
	root := realTemp(t)
	t.Chdir(root)
	a := &app{
		s:       cli.Stdio{Cwd: root, Env: func(string) string { return "" }},
		kitRoot: root,
		have:    func(string) bool { return true },
		exec: func(name string, args []string, merged bool) execResult {
			for _, x := range args {
				switch x {
				case "--show-toplevel":
					return execResult{Out: ".\n"}
				case "get-url":
					return execResult{Out: "https://github.com/owner/repo.git\n"}
				}
			}
			return execResult{RC: 1}
		},
	}
	if got := a.resolveRepo(); got != (repoResolution{Repo: "owner/repo"}) {
		t.Errorf("resolveRepo = %+v, want owner/repo", got)
	}
}

func TestCutCharsEdges(t *testing.T) {
	u, b := &app{utf8: true}, &app{}
	for _, c := range []struct {
		a    *app
		s    string
		n    int
		want string
	}{
		{u, "aé", 2, "aé"},
		{u, "aé", 1, "a"},
		{u, "aé", 0, ""},
		{u, "", 3, ""},
		{u, "a\xffb", 2, "a\xff"},
		{b, "abc", 3, "abc"},
		{b, "abc", 4, "abc"},
		{b, "abc", 2, "ab"},
		{b, "", 2, ""},
	} {
		if got := c.a.cutChars(c.s, c.n); got != c.want {
			t.Errorf("cutChars(%q, %d) utf8=%v = %q, want %q", c.s, c.n, c.a.utf8, got, c.want)
		}
	}
}

func TestResolveKitPhysicalToolbelt(t *testing.T) {
	root := realTemp(t)
	real := filepath.Join(root, "real", "kit", "research-sdd", "toolbelt")
	if err := os.MkdirAll(real, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(root, "lnk")); err != nil {
		t.Fatal(err)
	}
	mk := func(toolbelt string) *app {
		return &app{
			s: cli.Stdio{Cwd: root, Out: &bytes.Buffer{}, Err: &bytes.Buffer{}, Env: func(k string) string {
				if k == "RESEARCH_SDD_ISSUE_REPO" {
					return "owner/repo"
				}
				return ""
			}},
			toolbelt: toolbelt,
		}
	}
	a := mk("lnk") // relative to the caller's cwd, through a symlink
	if rc, stop := a.resolveKit(); rc != 0 || stop {
		t.Fatalf("resolveKit = %d, %v", rc, stop)
	}
	if want := filepath.Join(root, "real", "kit"); a.kitRoot != want || a.targetsMD != want+"/research-sdd/TARGETS.md" {
		t.Errorf("kitRoot = %q, targetsMD = %q; want the physical %q", a.kitRoot, a.targetsMD, want)
	}
	b := mk(filepath.Join(root, "nope", "x", "y")) // cannot be resolved: kept as given
	if rc, stop := b.resolveKit(); rc != 0 || stop {
		t.Fatalf("resolveKit = %d, %v", rc, stop)
	}
	if want := filepath.Join(root, "nope"); b.kitRoot != want {
		t.Errorf("unresolvable toolbelt: kitRoot = %q, want %q", b.kitRoot, want)
	}
}

func TestUncAddCutsOnlyPastTheLimit(t *testing.T) {
	a := &app{}
	a.uncAdd(false, "1", strings.Repeat("x", 100), "r")
	a.uncAdd(false, "2", strings.Repeat("x", 101), "r")
	if got := a.uncRecs[0].head; got != strings.Repeat("x", 100) {
		t.Errorf("100 characters must be kept whole, got %q", got)
	}
	if got := a.uncRecs[1].head; got != strings.Repeat("x", 97)+"..." {
		t.Errorf("101 characters must be cut to 97+..., got %q", got)
	}
}
