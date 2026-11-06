//go:build unix && !nodiff

package deploy

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// buildPath fills bin with symlinks to the host tools the installer needs and with recording fakes for every tool
// that could reach the network or a package manager. A fake appends "<name> <args>" to the call log and exits 97.
func buildPath(t *testing.T, bin, callLog string) {
	t.Helper()
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, tool := range systemTools {
		p, err := exec.LookPath(tool)
		if err != nil {
			if !optionalTools[tool] {
				needTool(t, tool)
			}
			continue
		}
		if err := os.Symlink(p, filepath.Join(bin, tool)); err != nil {
			t.Fatal(err)
		}
	}
	for _, tool := range fakeTools {
		execfile.Write(t, filepath.Join(bin, tool), "#!/bin/sh\necho \""+tool+" $*\" >> '"+callLog+"'\nexit 97\n")
	}
}

// needTool fails (RSDD_PARITY_REQUIRE=1) or skips when a host tool the frozen installer needs is missing.
func needTool(t *testing.T, tool string) {
	t.Helper()
	if os.Getenv("RSDD_PARITY_REQUIRE") == "1" {
		t.Fatalf("no %s on PATH and RSDD_PARITY_REQUIRE=1", tool)
	}
	t.Skipf("no %s on PATH: the frozen installer cannot run (RSDD_PARITY_REQUIRE=1 makes this a failure)", tool)
}

// dropTool removes a tool from the world's PATH (a missing dependency).
func (w *world) dropTool(name string) {
	w.t.Helper()
	if err := os.Remove(filepath.Join(w.bin, name)); err != nil {
		w.t.Fatal(err)
	}
}
