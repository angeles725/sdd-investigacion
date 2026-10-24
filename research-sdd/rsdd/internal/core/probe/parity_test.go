//go:build unix

package probe

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Differential test: the REAL toolbelt/lib/tool-env.sh (testdata/parity-driver.sh) and core/probe must print
// the same path and return the same code on the same fixtures. Bash runs under LC_ALL=C. Both sides see
// the real fixed host paths (Prober.root is empty here), which they only stat; every case pins the
// candidates that would execute something (brew prefix, r2 usrbin) to fixtures. A missing bash or
// toolbelt FAILS the test: a skipped parity test proves nothing.

const (
	toolbeltRel = "../../../../toolbelt"
	harnessRC   = 97
)

type pcase struct {
	name, mode, arg, cwd string
	env                  []string
	unsetPath            bool
}

func runBash(t *testing.T, c pcase) (string, int) {
	t.Helper()
	bin, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("bash is required for the parity test: %v", err)
	}
	tb, _ := filepath.Abs(toolbeltRel)
	if _, err := os.Stat(tb + "/lib/tool-env.sh"); err != nil {
		t.Fatalf("toolbelt not found at %s: %v", tb, err)
	}
	script, _ := filepath.Abs("testdata/parity-driver.sh")
	cmd := exec.Command(bin, script, tb, c.mode, c.arg)
	cmd.Dir, cmd.Env = c.cwd, append([]string{"LC_ALL=C"}, c.env...)
	if c.unsetPath {
		cmd.Env = append(cmd.Env, "RSDD_DRIVER_UNSET_PATH=1")
	}
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	rc := 0
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("cannot run the driver: %v", err)
		}
		rc = ee.ExitCode()
	}
	if rc == harnessRC {
		t.Fatalf("driver harness failure: %s", stderr.String())
	}
	return out.String(), rc
}

// runGo answers like the driver: the printed line and the shell return code.
func runGo(t *testing.T, c pcase) (string, int) {
	t.Helper()
	p := New(append([]string{"LC_ALL=C"}, c.env...), c.cwd)
	var path string
	var err error
	switch c.mode {
	case "cmdv":
		path, err = p.LookPath(c.arg)
	case "brew":
		path, _ = p.BrewPrefix()
	case "java":
		path, err = p.JavaHome()
	case "jar":
		path, err = p.JavaJar(c.arg)
	case "ghidra":
		path, err = p.GhidraHome()
	case "r2":
		path, err = p.R2()
	case "ilspy":
		path, err = p.ILSpy()
	case "pkgcfg":
		var ok bool
		if path, ok = p.SystemPkgConfigPath(); !ok {
			err = &Degraded{}
		}
	default:
		t.Fatalf("unknown mode %s", c.mode)
	}
	var d *Degraded
	switch {
	case err == nil && path != "":
		return path + "\n", 0
	case err == nil:
		return "", 0
	case errors.Is(err, ErrUnknownTool):
		return "", 2
	case errors.As(err, &d):
		return "", 1
	}
	t.Fatalf("untyped error %v", err)
	return "", 0
}

func TestParityWithToolEnv(t *testing.T) {
	// A driver that resolves nothing would agree with a Go side that resolves nothing: every mode must
	// see at least one hit and one miss on the bash side. No miss is reachable for brew (rc is brew's),
	// java (cases keep a fixture fallback) or pkgcfg (host dirs); the unit tests cover those misses.
	hits, misses := map[string]bool{}, map[string]bool{}
	defer func() {
		for _, m := range []string{"cmdv", "brew", "java", "jar", "ghidra", "r2", "ilspy", "pkgcfg"} {
			if !hits[m] || (!misses[m] && m != "brew" && m != "java" && m != "pkgcfg") {
				t.Errorf("mode %s: hit=%v miss=%v; the fixtures do not exercise it", m, hits[m], misses[m])
			}
		}
	}()
	for _, c := range parityCases(t) {
		t.Run(c.mode+"/"+c.name, func(t *testing.T) {
			bOut, bRC := runBash(t, c)
			hits[c.mode] = hits[c.mode] || bOut != ""
			misses[c.mode] = misses[c.mode] || bRC != 0
			gOut, gRC := runGo(t, c)
			if c.mode == "brew" { // rsdd_brew_prefix's rc is brew's own and every caller ignores it
				bRC, gRC = 0, 0
			}
			if bOut != gOut || bRC != gRC {
				t.Fatalf("bash (%q, rc=%d) go (%q, rc=%d)", bOut, bRC, gOut, gRC)
			}
		})
	}
}
