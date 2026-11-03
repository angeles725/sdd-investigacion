//go:build linux

package adapter

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// Tool-free kill tests for mutants that the Python-oracle parity tests (!nodiff) used to cover.
// Every expectation is a literal derived once from the frozen Python behaviour.

func TestRelativePathNormalizationLimitIsExactlyEightPasses(t *testing.T) {
	layered := func(n int) string {
		s := "%2e%2e/x"
		for i := 1; i < n; i++ {
			s = strings.ReplaceAll(s, "%", "%25")
		}
		return s
	}
	// n encoding layers settle on pass n+1 of 8, so 7 layers settle and 8 layers do not.
	for n, want := range map[int]string{
		1: "x must be a canonical artifact-relative path",
		7: "x must be a canonical artifact-relative path",
		8: "x exceeds normalization limit",
		9: "x exceeds normalization limit",
	} {
		_, err := relativePath(layered(n), "x")
		if err == nil || err.Error() != want {
			t.Errorf("%d layers: err = %v, want %q", n, err, want)
		}
	}
}

func TestRequirePrivateBoundaries(t *testing.T) {
	// exactly five left fields is well formed
	if err := RequirePrivate("/a/b", "1 2 0:1 / /a/b - tmpfs tmpfs rw"); err != nil {
		t.Errorf("five left fields: %v", err)
	}
	// four left fields is too few
	err := RequirePrivate("/a", "1 2 0:1 / - tmpfs tmpfs rw")
	if err == nil || !strings.Contains(err.Error(), "too few left fields") {
		t.Errorf("four left fields: %v", err)
	}
	// of two mounts at the same depth the first one listed wins
	both := "1 2 0:1 / /a - tmpfs t rw\n3 4 0:2 / /a - nfs t rw\n"
	if err := RequirePrivate("/a/x", both); err != nil {
		t.Errorf("first same-depth mount must win: %v", err)
	}
	flipped := "3 4 0:2 / /a - nfs t rw\n1 2 0:1 / /a - tmpfs t rw\n"
	if err := RequirePrivate("/a/x", flipped); err == nil {
		t.Error("first same-depth mount (nfs) must win")
	}
}

func TestUnderMountPathEqualToMount(t *testing.T) {
	if !underMount([]string{"/", "a", "b"}, []string{"/", "a", "b"}) {
		t.Error("a path equal to its mount is under it")
	}
	if underMount([]string{"/", "a"}, []string{"/", "a", "b"}) {
		t.Error("a path shorter than its mount is not under it")
	}
}

func TestNFKCRunBoundaries(t *testing.T) {
	for _, run := range nfkcRuns {
		for _, c := range []rune{run.lo, run.hi} {
			want := string(run.dst + c - run.lo)
			if got, ok := foldRune(c); !ok || got != want {
				t.Errorf("foldRune(%U) = %q,%v want %q", c, got, ok, want)
			}
		}
	}
}

func TestPyReprHexPadding(t *testing.T) {
	for in, want := range map[string]string{
		"\x00": `'\x00'`, "\x01": `'\x01'`, "\x1f": `'\x1f'`, "\x7f": `'\x7f'`, "\u0085": `'\x85'`,
		"\u200b": "'\\u200b'", "\u0378": "'\\u0378'",
		"\U000e0001": `'\U000e0001'`, "\U0010ffff": `'\U0010ffff'`,
	} {
		if got := pyRepr(in); got != want {
			t.Errorf("pyRepr(%+q) = %s, want %s", in, got, want)
		}
	}
}

func TestPyFieldsSeparatorSet(t *testing.T) {
	for r := rune(0x1b); r <= 0x21; r++ {
		got := pyFields("a" + string(r) + "b")
		sep := r >= 0x1c && r <= 0x20
		if sep && len(got) != 2 || !sep && len(got) != 1 {
			t.Errorf("pyFields around %U = %q", r, got)
		}
	}
}

func isErrno(err error, e syscall.Errno) bool {
	pe, ok := err.(*os.PathError)
	return ok && pe.Err == e
}

func TestRealpathDotDotAtTopAndStrictNonDirectory(t *testing.T) {
	for _, p := range []string{"/rsdd-teeth-missing/..", "/.."} {
		if got, err := realpath(p, false, ""); err != nil || got != "/" {
			t.Errorf("realpath(%q) = %q, %v; want /", p, got, err)
		}
	}
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "f")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := realpath(file, true, ""); err != nil || got != file {
		t.Errorf("strict realpath of a file = %q, %v", got, err)
	}
	for _, p := range []string{file + "/x", file + "/"} {
		if _, err := realpath(p, true, ""); !isErrno(err, syscall.ENOTDIR) {
			t.Errorf("strict realpath(%q) err = %v, want ENOTDIR", p, err)
		}
	}
}

func TestWhichSearchSources(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(dir, "tool")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got, ok := which("tool", dir, ""); !ok || got != exe {
		t.Errorf("which via search = %q, %v", got, ok)
	}
	if got, ok := which(exe, "", ""); !ok || got != exe {
		t.Errorf("which with a directory part ignores an empty search = %q, %v", got, ok)
	}
	if got, ok := which(exe, "/nonexistent", ""); !ok || got != exe {
		t.Errorf("which with a directory part ignores the search = %q, %v", got, ok)
	}
	if got, ok := which("tool", "", dir); ok {
		t.Errorf("which without a search path found %q", got)
	}
}

func TestStatOfTimestampsAndWriteAllError(t *testing.T) {
	st := &syscall.Stat_t{Dev: 7, Ino: 9, Mode: 0o100644, Size: 5}
	st.Mtim = syscall.Timespec{Sec: 2, Nsec: 3}
	st.Ctim = syscall.Timespec{Sec: 4, Nsec: 5}
	want := statTuple{7, 9, 0o100644, 5, 2_000_000_003, 4_000_000_005}
	if got := statOf(st); got != want {
		t.Errorf("statOf = %+v, want %+v", got, want)
	}
	if err := writeAll(-1, []byte("x")); err != syscall.EBADF {
		t.Errorf("writeAll on a bad fd = %v, want EBADF", err)
	}
}

func TestWhichTrimsDirectoryAndAnchorsRelativeCandidates(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(dir, "sub", "tool")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	// trailing separators on the directory part collapse to one
	if got, ok := which(filepath.Join(dir, "sub")+"//tool", "", ""); !ok || got != exe {
		t.Errorf("which with doubled separator = %q, %v; want %q", got, ok, exe)
	}
	// a relative candidate is checked against the injected cwd
	if got, ok := which("tool", "sub", dir); !ok || got != "sub/tool" {
		t.Errorf("which relative = %q, %v; want sub/tool", got, ok)
	}
}
