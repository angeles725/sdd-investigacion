//go:build linux

package pcap

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// Expected values are what pathlib.PurePosixPath and posixpath answer in CPython 3.12.

func TestNormIsStrOfPath(t *testing.T) {
	for in, want := range map[string]string{
		"": ".", ".": ".", "/": "/", "//": "//", "///": "/", "////x": "/x", "//a": "//a", "///a//b/": "/a/b",
		"a/b/": "a/b", "./a/./b": "a/b", "a//b": "a/b", "a/../b": "a/../b", "/a/b": "/a/b",
	} {
		if got := norm(in); got != want {
			t.Errorf("norm(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParentAndName(t *testing.T) {
	for _, c := range []struct{ in, parent, name string }{
		{"", ".", ""}, {".", ".", ""}, {"/", "/", ""}, {"//", "//", ""}, {"a", ".", "a"}, {"/a", "/", "a"}, {"//a", "//", "a"},
		{"a/b/c", "a/b", "c"}, {"/a/b", "/a", "b"}, {"a/b/", "a", "b"}, {"./a", ".", "a"},
	} {
		if p, n := parentAndName(c.in); p != c.parent || n != c.name {
			t.Errorf("parentAndName(%q) = %q, %q; want %q, %q", c.in, p, n, c.parent, c.name)
		}
	}
}

func TestJoinIsPathDivision(t *testing.T) {
	for _, c := range []struct{ base, name, want string }{
		{"a", "", "a"}, {"a/", "", "a"}, {".", "x", "x"}, {"", "x", "x"}, {"/", "x", "/x"}, {"//", "x", "//x"}, {"a", "x", "a/x"},
		{"a/b/", "x", "a/b/x"}, {"/a", "x", "/a/x"},
	} {
		if got := join(c.base, c.name); got != c.want {
			t.Errorf("join(%q, %q) = %q, want %q", c.base, c.name, got, c.want)
		}
	}
}

func TestAbsoluteAgainstTheWorkingDirectory(t *testing.T) {
	for _, c := range []struct{ cwd, p, want string }{
		{"/w", "x", "/w/x"}, {"/w/", "x", "/w/x"}, {"/w", "/abs", "/abs"}, {"", "x", "x"}, {"/w", "../x", "/w/../x"},
	} {
		if got := absolute(c.cwd, c.p); got != c.want {
			t.Errorf("absolute(%q, %q) = %q, want %q", c.cwd, c.p, got, c.want)
		}
	}
}

func TestPySplitAndPyJoin(t *testing.T) {
	for _, c := range []struct{ in, head, tail string }{
		{"a/b", "a", "b"}, {"/a", "/", "a"}, {"//a", "//", "a"}, {"a//b", "a", "b"}, {"a", "", "a"}, {"a/", "a", ""}, {"/", "/", ""}, {"", "", ""},
	} {
		if h, tl := pySplit(c.in); h != c.head || tl != c.tail {
			t.Errorf("pySplit(%q) = %q, %q; want %q, %q", c.in, h, tl, c.head, c.tail)
		}
	}
	for _, c := range []struct{ dir, name, want string }{{"", "x", "x"}, {"a/", "x", "a/x"}, {"a", "x", "a/x"}, {"/", "x", "/x"}} {
		if got := pyJoin(c.dir, c.name); got != c.want {
			t.Errorf("pyJoin(%q, %q) = %q, want %q", c.dir, c.name, got, c.want)
		}
	}
}

func TestResolveStrictFollowsLinksComponentByComponent(t *testing.T) {
	cwd, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	mustDo := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	mustDo(os.MkdirAll(filepath.Join(cwd, "dir/sub"), 0o755))
	mustDo(os.WriteFile(filepath.Join(cwd, "dir/f"), nil, 0o644))
	mustDo(os.Symlink("dir", filepath.Join(cwd, "l")))
	mustDo(os.Symlink("../f", filepath.Join(cwd, "dir/sub/up")))
	mustDo(os.Symlink(filepath.Join(cwd, "dir"), filepath.Join(cwd, "abs")))
	mustDo(os.Symlink("b", filepath.Join(cwd, "a")))
	mustDo(os.Symlink("a", filepath.Join(cwd, "b")))
	mustDo(os.Symlink("nowhere", filepath.Join(cwd, "dangling")))

	for _, c := range []struct{ in, want string }{
		{"dir", cwd + "/dir"},
		{"dir/sub/..", cwd + "/dir"},
		{"l", cwd + "/dir"},
		{"l/f", cwd + "/dir/f"},
		{"l/../l", cwd + "/dir"},
		{"abs/f", cwd + "/dir/f"},
		{"dir/sub/up", cwd + "/dir/f"},
		{"./dir//sub/.", cwd + "/dir/sub"},
		{filepath.Join(cwd, "dir/sub/.."), cwd + "/dir"},
		{"..", filepath.Dir(cwd)},
		{"../..", filepath.Dir(filepath.Dir(cwd))},
	} {
		got, err := resolveStrict(cwd, c.in)
		if err != nil || got != c.want {
			t.Errorf("resolveStrict(%q) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}

	var pe *os.PathError
	for _, c := range []struct {
		in, path string
		errno    syscall.Errno
		op       string
	}{
		{"nope", "nope", syscall.ENOENT, "lstat"},
		{"dir/nope/x", "dir/nope", syscall.ENOENT, "lstat"},
		{"dangling", "nowhere", syscall.ENOENT, "lstat"},
		{"a", "a", syscall.ELOOP, "stat"},
		{"dir/f/x", "dir/f/x", syscall.ENOTDIR, "lstat"},
	} {
		_, err := resolveStrict(cwd, c.in)
		if !errors.As(err, &pe) || pe.Path != c.path || !errors.Is(err, c.errno) || pe.Op != c.op {
			t.Errorf("resolveStrict(%q) error = %v, want %s %s: %v", c.in, err, c.op, c.path, c.errno)
		}
	}
}
