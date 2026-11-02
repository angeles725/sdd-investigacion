//go:build linux

package formats

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
)

// The analysis manifest of squashfs-extract, zip-metadata and zip-stored is created and verified in process
// (core/adapter): the commands must succeed with no python3 on PATH, and the manifest they publish must verify.

// noPython points PATH at an empty directory, so a python3 lookup or exec fails.
func noPython(t *testing.T) {
	t.Helper()
	t.Setenv("PATH", t.TempDir())
}

// verifyInProcess verifies the published manifest of tree with the in-process manifest CLI.
func verifyInProcess(t *testing.T, tree string) {
	t.Helper()
	var out, errb strings.Builder
	s := cli.Stdio{Out: &out, Err: &errb, Cwd: tree, Env: func(string) string { return "" }}
	if rc := adapter.ManifestRun([]string{"verify", "--root", tree, filepath.Join(tree, "analysis-manifest.v1.json")}, s); rc != 0 {
		t.Errorf("manifest of %s does not verify (exit %d): %s", tree, rc, errb.String())
	}
}

func TestSquashfsManifestNeedsNoPython(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	useTools(t, okExtraction)
	noPython(t)
	rc, stderr, _, out := extract(t, good)
	if rc != 0 {
		t.Fatalf("exit %d stderr %q, want 0 with no python3 on PATH", rc, stderr)
	}
	verifyInProcess(t, out)
}

func TestZipManifestNeedsNoPython(t *testing.T) {
	noPython(t)
	for name, tc := range map[string]struct {
		run  func([]string, cli.Stdio) int
		fx   map[string][]byte
		file string
	}{
		"zip-metadata": {ZipMetadata, metaFixtures(), "mixed.zip"},
		"zip-stored":   {ZipStored, storedFixtures(), "good.zip"},
	} {
		t.Run(name, func(t *testing.T) {
			paths := writeFixtures(t, t.TempDir(), tc.fx)
			out := filepath.Join(t.TempDir(), "out")
			code, _, stderr := runGo(t, tc.run, t.TempDir(), "--input", paths[tc.file], "--output", out, "--manifest-cli", zipManifestCLI(t))
			if code != 0 {
				t.Fatalf("exit %d stderr %q, want 0 with no python3 on PATH", code, stderr)
			}
			verifyInProcess(t, out)
		})
	}
}
