package fetchdoc

import (
	"slices"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// A Stdio with no environment list (a test Stdio) still gives the children a PATH, and an unset TMPDIR
// means /tmp.
func TestProductionDepsFallsBackToAPathOnlyEnvironmentAndTmp(t *testing.T) {
	env := map[string]string{"PATH": "/opt/bin"}
	d := ProductionDeps(cli.Stdio{Env: func(k string) string { return env[k] }}, 7, nil)
	if want := []string{"PATH=/opt/bin"}; !slices.Equal(d.Environ, want) {
		t.Errorf("Environ = %q, want %q", d.Environ, want)
	}
	if d.TmpDir != "/tmp" {
		t.Errorf("TmpDir = %q, want /tmp", d.TmpDir)
	}
	if d.Pid != 7 {
		t.Errorf("Pid = %d, want 7", d.Pid)
	}
}

// The caller's environment list and its TMPDIR are used as given.
func TestProductionDepsKeepsTheCallerEnvironmentAndTMPDIR(t *testing.T) {
	full := []string{"PATH=/opt/bin", "TMPDIR=/scratch", "X=1"}
	env := map[string]string{"PATH": "/opt/bin", "TMPDIR": "/scratch", "X": "1"}
	s := cli.Stdio{Env: func(k string) string { return env[k] }, Environ: func() []string { return full }}
	d := ProductionDeps(s, 7, nil)
	if !slices.Equal(d.Environ, full) {
		t.Errorf("Environ = %q, want %q", d.Environ, full)
	}
	if d.TmpDir != "/scratch" {
		t.Errorf("TmpDir = %q, want /scratch", d.TmpDir)
	}
}

// A space is the first character badChars accepts; 0x1f and DEL are control characters, and a "|" has
// its own reason.
func TestBadCharsBoundary(t *testing.T) {
	const pipe, control = `a "|" would shift the SOURCES.md columns`, "control characters are not allowed"
	for in, want := range map[string]string{
		"a b": "", "a~b": "", "a\x1fb": control, "a\x7fb": control, "a\nb": control, "a|b": pipe,
	} {
		if got := badChars(in); got != want {
			t.Errorf("badChars(%q) = %q, want %q", in, got, want)
		}
	}
}
