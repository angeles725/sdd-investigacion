package niagara

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPathHelpersMatchPosixpath(t *testing.T) {
	joins := []struct{ a, b, want string }{
		{"a", "b", "a/b"}, {"/", "b", "/b"}, {"a/", "b", "a/b"}, {"", "b", "b"}, {"a", "", "a/"},
	}
	for _, tt := range joins {
		if got := pjoin(tt.a, tt.b); got != tt.want {
			t.Errorf("pjoin(%q, %q) = %q, want %q", tt.a, tt.b, got, tt.want)
		}
	}
	splits := []struct{ in, head, tail string }{
		{"/a/b", "/a", "b"}, {"/a", "/", "a"}, {"a", "", "a"}, {"//a", "//", "a"}, {"/a//b", "/a", "b"}, {"a/", "a", ""}, {"/", "/", ""},
	}
	for _, tt := range splits {
		if h, tl := psplit(tt.in); h != tt.head || tl != tt.tail {
			t.Errorf("psplit(%q) = (%q, %q), want (%q, %q)", tt.in, h, tl, tt.head, tt.tail)
		}
	}
	if got := pdirname("/x/defaults/system.properties"); got != "/x/defaults" {
		t.Errorf("pdirname = %q", got)
	}
	norms := []struct{ in, want string }{
		{"/a/./b/../c//d", "/a/c/d"}, {"//a", "//a"}, {"///a", "/a"}, {"a/..", "."}, {"../a", "../a"}, {"/..", "/"}, {"", "."}, {"a/b/../../..", ".."},
	}
	for _, tt := range norms {
		if got := normpath(tt.in); got != tt.want {
			t.Errorf("normpath(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

// Expected values are os.path.realpath on CPython 3.15 over the same tree.
func TestPyRealpathMatchesPython(t *testing.T) {
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	mustLink := func(target, name string) {
		t.Helper()
		if err := os.Symlink(target, filepath.Join(d, name)); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(d, "real", "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	mustLink("real", "link")
	mustLink("loop", "loop")
	mustLink("b", "a")
	mustLink("a", "b")
	mustLink("real/../real", "rel")
	mustLink("/definitely/not/here", "dangling")
	mustLink("..", "real/up")
	tests := []struct{ in, want string }{
		{"link", "/real"}, {"link/sub", "/real/sub"}, {"link/nope/x", "/real/nope/x"},
		{"loop", "/loop"}, {"loop/x", "/loop/x"}, {"a", "/a"}, {"a/x", "/a/x"},
		{"rel/sub", "/real/sub"}, {"dangling", "OUT:/definitely/not/here"}, {"dangling/x", "OUT:/definitely/not/here/x"},
		{"real/up", ""}, {"real/up/real", "/real"}, {"real/../link", "/real"}, {"real/./sub//", "/real/sub"},
		{"missing/../real", "/real"}, {"link/../link", "/real"},
	}
	for _, tt := range tests {
		got := pyRealpath("", d+"/"+tt.in)
		if strings.HasPrefix(got, d) {
			got = strings.TrimPrefix(got, d)
		} else {
			got = "OUT:" + got
		}
		if got != tt.want {
			t.Errorf("pyRealpath(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
	// a relative path resolves against the working directory it is given
	if got := pyRealpath(d, "real/up"); got != d {
		t.Errorf("relative real/up = %q, want %q", got, d)
	}
	if got := pyRealpath(d, "."); got != d {
		t.Errorf("relative . = %q, want %q", got, d)
	}
}

func TestInsideRoot(t *testing.T) {
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(d, "home")
	outside := filepath.Join(d, "outside")
	if err := os.MkdirAll(filepath.Join(home, "in"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(d, "home-sibling"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(home, "esc")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(home, "in"), filepath.Join(home, "stay")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(d, "home-sibling"), filepath.Join(home, "sib")); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		sub  string
		want bool
	}{
		{home, true}, {home + "/in", true}, {home + "/nope/x", true}, {home + "/stay", true},
		{home + "/esc", false}, {home + "/esc/deeper", false},
		{home + "/sib", false}, // a sibling whose name starts with the root's name is still outside
		{outside, false},
	}
	for _, tt := range tests {
		if got := insideRoot("", home, tt.sub); got != tt.want {
			t.Errorf("insideRoot(%q) = %v, want %v", tt.sub, got, tt.want)
		}
	}
}
