//go:build linux && !nodiff

package formats

import (
	"bytes"
	"errors"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// legacy runs the real Python tool. A missing python3 fails the test.
func legacy(t testing.TB, script string, args ...string) (code int, stderr string) {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests: %v", err)
	}
	tb, err := filepath.Abs(zipToolbelt)
	if err != nil {
		t.Fatal(err)
	}
	dir := tb
	if script != "analysis_manifest.py" { // the retired tools live in their frozen copy, the manifest CLI in the frozen toolbelt copy
		if dir, err = filepath.Abs(zipLegacyDir); err != nil {
			t.Fatal(err)
		}
	}
	argv := append([]string{filepath.Join(dir, script)}, args...)
	cmd := exec.Command(py, argv...)
	cmd.Dir = tb
	var errb bytes.Buffer
	cmd.Stderr = &errb
	err = cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		return 0, errb.String()
	case errors.As(err, &ee):
		return ee.ExitCode(), errb.String()
	}
	t.Fatalf("cannot run %s: %v", script, err)
	return -1, ""
}

func legacyStoredArgs(t testing.TB, in, out string, extra ...string) []string {
	ld, _ := filepath.Abs(zipLegacyDir)
	return append(storedArgs(t, in, out, extra...), "--metadata-parser", filepath.Join(ld, "zip_metadata.py"))
}

// zipVerifyManifest runs the legacy `analysis_manifest.py verify` over a published tree.
func zipVerifyManifest(t testing.TB, tree string) {
	t.Helper()
	code, stderr := legacy(t, "analysis_manifest.py", "verify", "--root", tree, filepath.Join(tree, "analysis-manifest.v1.json"))
	if code != 0 {
		t.Fatalf("analysis manifest of %s does not verify (exit %d): %s", tree, code, stderr)
	}
}

// legacyCmdCase runs one case through the Python tool and returns what it produced, in the shape the golden freezes.
func legacyCmdCase(t testing.TB, kind string, paths map[string]string, c cmdCase, work, inDir string, i int) zipCmdGold {
	t.Helper()
	lo := filepath.Join(work, "legacy-"+itoa(i))
	var code int
	var lerr string
	if kind == "meta" {
		code, lerr = legacy(t, "zip_metadata.py", metaArgs(t, paths[c.name], lo, c.extra...)...)
	} else {
		code, lerr = legacy(t, "zip_stored.py", legacyStoredArgs(t, paths[c.name], lo, c.extra...)...)
	}
	g := zipCmdGold{Label: c.label(), Code: code}
	if code != 0 {
		g.Stderr = strings.ReplaceAll(lerr, inDir, "<in>")
		// The subprocess failure line names this machine's python3 and checkout; freeze only what precedes it.
		if i := strings.Index(g.Stderr, "Command '["); i >= 0 {
			g.Stderr = g.Stderr[:i] + "Command '[<argv>]' failed\n"
		}
		assertNoLeftovers(t, work, "legacy-"+itoa(i))
		return g
	}
	g.Tree = treeGold(t, lo, inDir)
	g.Facts = manifestFacts(t, lo, inDir)
	return g
}

func parityCommand(t *testing.T, kind, golden string, fixtures func() map[string][]byte, cases func(map[string]string) []cmdCase) {
	work, in := t.TempDir(), t.TempDir()
	paths := writeFixtures(t, in, fixtures())
	cs := cases(paths)
	got := make([]zipCmdGold, len(cs))
	var accepted atomic.Int32
	t.Run("cases", func(t *testing.T) {
		for i, c := range cs {
			i, c := i, c
			t.Run(c.label(), func(t *testing.T) {
				t.Parallel()
				got[i] = legacyCmdCase(t, kind, paths, c, work, in, i)
				if got[i].Code != 0 {
					return
				}
				accepted.Add(1)
				// The Go command's published tree must also verify under the legacy manifest tool.
				_, mo := goCmdCase(t, kind, paths, c, work, in, i)
				zipVerifyManifest(t, mo)
			})
		}
	})
	if accepted.Load() < 5 {
		t.Fatalf("only %d archives were accepted; the comparison proves nothing", accepted.Load())
	}
	if !t.Failed() {
		checkZipGolden(t, golden, got)
	}
}

func TestZipMetadataCommandParity(t *testing.T) {
	parityCommand(t, "meta", "meta_cmd", metaFixtures, zipMetaCases)
}

func TestZipStoredCommandParity(t *testing.T) {
	parityCommand(t, "stored", "stored_cmd", storedFixtures, zipStoredCases)
}
