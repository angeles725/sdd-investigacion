//go:build unix

package probe

import (
	"bytes"
	"errors"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/reasons"
)

func TestDegradedIsTyped(t *testing.T) {
	nf := &Degraded{Tool: "r2"}
	if !errors.Is(nf, ErrNotFound) || errors.Is(nf, ErrOverrideUnusable) {
		t.Fatalf("not-found kind wrong: %v", nf)
	}
	ov := &Degraded{Tool: "r2", Override: "R2"}
	if !errors.Is(ov, ErrOverrideUnusable) || errors.Is(ov, ErrNotFound) {
		t.Fatalf("override kind wrong: %v", ov)
	}
	if ov.Error() != "missing runtime dependency: r2 (R2 is set but unusable)" ||
		nf.Error() != "missing runtime dependency: r2" {
		t.Fatalf("messages: %q / %q", ov.Error(), nf.Error())
	}
	if nf.Code() != reasons.DegradedMissingRuntimeDependency {
		t.Fatalf("code %q", nf.Code().Text())
	}
	var b bytes.Buffer
	if err := ov.Emit(&b); err != nil || b.String() != "degraded: missing runtime dependency: r2\n" {
		t.Fatalf("emit %q %v", b.String(), err)
	}
}

func TestNewEnvLastWinsAndUnsetDiffersFromEmpty(t *testing.T) {
	p := New([]string{"A=1", "A=2", "E=", "junk"}, "/")
	if v, ok := p.lookup("A"); !ok || v != "2" {
		t.Fatalf("A = %q %v", v, ok)
	}
	if v, ok := p.lookup("E"); !ok || v != "" {
		t.Fatalf("E = %q %v", v, ok)
	}
	if _, ok := p.lookup("junk"); ok {
		t.Fatal("an entry without '=' must not define a variable")
	}
}

func TestLookPath(t *testing.T) {
	d := t.TempDir()
	noexec := put(t, d, "a/foo", "x", 0o644)
	good := exe(t, d, "b/foo", "")
	mkdir(t, d, "c/foo")
	put(t, d, "d/bar", "x", 0o644)
	cases := []struct {
		name, path, cwd, cmd, want string
	}{
		{"first executable wins over earlier non-executable", d + "/a:" + d + "/b", d, "foo", good},
		{"a directory is never a command", d + "/c:" + d + "/b", d, "foo", good},
		{"non-executable fallback when nothing executes", d + "/a", d, "foo", noexec},
		{"fallback kept across a later miss", d + "/a:" + d + "/d", d, "foo", noexec},
		{"trailing slash is not doubled", d + "/b/", d, "foo", good},
		{"empty element is dot", d + "/a::", d + "/b", "foo", "./foo"},
		{"relative element is kept", "../b", d + "/b", "foo", "../b/foo"},
		{"empty PATH answers absolute cwd path", "", d + "/b", "foo", d + "/b/foo"},
		{"slash name executable is printed as given", "/nowhere", d, "b/foo", "b/foo"},
		{"PATH searched in order", d + "/b:" + d + "/a", d, "foo", good},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := prober(d, c.cwd, "PATH="+c.path).LookPath(c.cmd)
			wantPath(t, got, err, c.want)
		})
	}
	absent := []struct{ name, path, cwd, cmd string }{
		{"missing everywhere", d + "/a", d, "nope"},
		{"empty name", d + "/b", d, ""},
		{"slash name non-executable", "", d, "a/foo"},
		{"slash name directory", "", d, "c/foo"},
		{"directory only", d + "/c", d, "foo"},
	}
	for _, c := range absent {
		t.Run(c.name, func(t *testing.T) {
			got, err := prober(d, c.cwd, "PATH="+c.path).LookPath(c.cmd)
			wantDegraded(t, got, err, c.cmd, ErrNotFound)
		})
	}
	t.Run("unset PATH searches the working directory", func(t *testing.T) {
		got, err := prober(d, d+"/b").LookPath("foo")
		wantPath(t, got, err, d+"/b/foo")
	})
}
