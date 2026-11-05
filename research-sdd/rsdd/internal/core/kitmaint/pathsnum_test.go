package kitmaint

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNumbers(t *testing.T) {
	for _, c := range []struct {
		v      string
		def, n int
	}{{"", 120, 120}, {"7", 120, 7}, {"abc", 120, 0}, {" 3 ", 5, 3}, {"0", 5, 0}, {"-2", 5, -2}} {
		if got := IntOr(c.v, c.def); got != c.n {
			t.Errorf("IntOr(%q,%d) = %d, want %d", c.v, c.def, got, c.n)
		}
	}
	for s, want := range map[string]bool{"": true, "0": true, "123": true, "12a": false, "a12": false, "1 2": false, "-1": false} {
		if AllDigits(s) != want {
			t.Errorf("AllDigits(%q) = %v", s, !want)
		}
	}
	for s, want := range map[string]bool{"": false, "abcdef0": true, "ABCDEF9": true, "ag": false, "0x1": false} {
		if IsHex(s) != want {
			t.Errorf("IsHex(%q) = %v", s, !want)
		}
	}
}

func TestAbsAndInside(t *testing.T) {
	if Abs("/w", "a/b") != "/w/a/b" || Abs("/w", "/x") != "/x" {
		t.Error("Abs")
	}
	if !Inside("/r/s", "/r") || !Inside("/r", "/r") || Inside("/rr/s", "/r") || Inside("/q", "/r") {
		t.Error("Inside must compare whole path elements")
	}
}

func TestStateDir(t *testing.T) {
	env := map[string]string{"HOME": "/h"}
	get := func(k string) string { return env[k] }
	if got := StateDir(get); got != "/h/.local/state/research-sdd/pipeline" {
		t.Errorf("default: %s", got)
	}
	env["XDG_STATE_HOME"] = "/x"
	if got := StateDir(get); got != "/x/research-sdd/pipeline" {
		t.Errorf("xdg: %s", got)
	}
}

func TestPaths(t *testing.T) {
	root := scratch(t)
	real := filepath.Join(root, "real")
	if err := os.MkdirAll(real, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if !IsDir(real) || IsDir(filepath.Join(root, "nope")) || IsDir(script(t, root, "f", ":")) {
		t.Error("IsDir")
	}
	got, err := ResolveDir(root, "link")
	if err != nil || got != real {
		t.Errorf("ResolveDir relative link = %q, %v", got, err)
	}
	if _, err := ResolveDir(root, "missing"); err == nil {
		t.Error("ResolveDir of a missing dir must fail")
	}
	// the nearest existing ancestor is resolved, the not-yet-existing tail is appended unchanged
	got, err = PhysPath(root, "link/a/b")
	if err != nil || got != real+"/a/b" {
		t.Errorf("PhysPath = %q, %v", got, err)
	}
	got, err = PhysPath(root, "link")
	if err != nil || got != real {
		t.Errorf("PhysPath existing = %q, %v", got, err)
	}
	if got, err = PhysPath(root, "/"); err != nil || got != "" {
		t.Errorf("PhysPath(/) = %q, %v", got, err)
	}
	if got, err = PhysPath("/", "zz-no-such-top-level-dir/x"); err != nil || got != "/zz-no-such-top-level-dir/x" {
		t.Errorf("PhysPath under / = %q, %v", got, err)
	}
}
