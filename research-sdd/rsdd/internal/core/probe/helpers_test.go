package probe

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// put writes body at dir/rel (parents created) with mode and returns the path.
func put(t *testing.T, dir, rel, body string, mode os.FileMode) string {
	t.Helper()
	p := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, mode); err != nil {
		t.Fatal(err)
	}
	return p
}

// exe writes an executable /bin/sh script.
func exe(t *testing.T, dir, rel, script string) string {
	t.Helper()
	return put(t, dir, rel, "#!/bin/sh\n"+script+"\n", 0o755)
}

func mkdir(t *testing.T, dir, rel string) string {
	t.Helper()
	p := filepath.Join(dir, rel)
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

// prober is a Prober over env whose fixed host paths live under root (so the real host never leaks in).
func prober(root, cwd string, env ...string) *Prober {
	p := New(env, cwd)
	p.root = root
	return p
}

// wantPath fails unless err is nil and got is want.
func wantPath(t *testing.T, got string, err error, want string) {
	t.Helper()
	if err != nil || got != want {
		t.Fatalf("got (%q, %v), want %q", got, err, want)
	}
}

// wantDegraded fails unless err is a *Degraded for tool whose kind is kind, with an empty path.
func wantDegraded(t *testing.T, got string, err error, tool string, kind error) {
	t.Helper()
	var d *Degraded
	if got != "" || !errors.As(err, &d) || d.Tool != tool || !errors.Is(err, kind) {
		t.Fatalf("got (%q, %v), want degraded %s (%v)", got, err, tool, kind)
	}
}
