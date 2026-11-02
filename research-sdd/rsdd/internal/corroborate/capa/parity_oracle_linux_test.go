//go:build linux

package capa

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestParityOracleIsNotVacuous pins what the oracle really does, so a legacy tool that fails the same way
// as the port for an unrelated reason (no Python, no sandbox rig) cannot pass the parity tests: the happy
// run publishes evidence with exit 0, a timeout publishes failed evidence with exit 1, a usage error is 2.
func TestParityOracleIsNotVacuous(t *testing.T) {
	r := newRig(t)
	r.manifestCLI, _ = filepath.Abs(toolbeltDir + "/analysis_manifest.py")
	if got := runLegacy(t, r, nil, r.args("ok")...); got.code != 0 || !r.published("ok") {
		t.Fatalf("legacy happy run: code %d published %v stderr %s", got.code, r.published("ok"), got.stderr)
	}
	r.capaFile("sleep", "30")
	if got := runLegacy(t, r, nil, r.args("slow", "--timeout", "1")...); got.code != 1 || !r.published("slow") {
		t.Fatalf("legacy timeout run: code %d published %v stderr %s", got.code, r.published("slow"), got.stderr)
	}
	if got := runLegacy(t, r, nil, "--bogus"); got.code != 2 || !strings.Contains(got.stderr, "error: the following arguments are required") {
		t.Fatalf("legacy usage error: code %d stderr %s", got.code, got.stderr)
	}
}
