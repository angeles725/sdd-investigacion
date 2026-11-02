//go:build linux && !nodiff

package capa

// The legacy tool hands its manifest step to toolbelt/analysis_manifest.py, which runs `rsdd adapter manifest`
// through lib/rsdd-exec.sh. Without a cached binary that script runs `go build` - under the scenario's HOME,
// where a GOTOOLCHAIN=auto toolchain download lands in a read-only module cache that TempDir cannot remove.
// So the binary is built once, here, with the caller's real environment, and handed over as RSDD_BIN.

import (
	"os"
	"sync"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/parity"
)

const rsddModuleRoot = "../../.."

var (
	rsddBinOnce sync.Once
	rsddBinPath string
	rsddBinErr  error
	rsddBinDir  string
)

// rsddBinary builds ./cmd/rsdd once per test binary.
func rsddBinary(t testing.TB) string {
	t.Helper()
	rsddBinOnce.Do(func() {
		rsddBinDir, rsddBinErr = os.MkdirTemp("", "capa-parity-rsdd-")
		if rsddBinErr == nil {
			rsddBinPath, rsddBinErr = parity.BuildBinary(rsddModuleRoot, rsddBinDir)
		}
	})
	if rsddBinErr != nil {
		t.Fatalf("building rsdd for the legacy manifest step: %v", rsddBinErr)
	}
	return rsddBinPath
}

func TestMain(m *testing.M) {
	code := m.Run()
	if rsddBinDir != "" {
		_ = os.RemoveAll(rsddBinDir)
	}
	os.Exit(code)
}
