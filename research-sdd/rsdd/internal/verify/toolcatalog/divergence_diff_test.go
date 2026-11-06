//go:build !nodiff && unix

package toolcatalog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// What the scripts did where the port differs on purpose: each is a silent zero or a wrong count the report gave no
// sign of. Asserting the old behaviour keeps the divergence honest: when the oracle stops showing it, this fails and
// the entry in tool-registry.d goes.

func TestLegacyUnreadableInputReadsAsEmptyOrAllMissing(t *testing.T) {
	t.Parallel()
	skipIfRoot(t)
	for name, want := range map[string]string{installedFile: "(empty-input)", registryFile: "0 cataloged · 1 not cataloged"} {
		dir := kit(t, files(logOf("alpha"), regOf("alpha")))
		stage(t, dir)
		if err := os.Chmod(filepath.Join(dir, name), 0); err != nil {
			t.Fatal(err)
		}
		got := runLegacy(t, dir, "C", "verify-tool-catalog.sh")
		if got.code != 0 || !strings.Contains(got.stdout, want) {
			t.Errorf("%s unreadable: legacy printed %+v, want exit 0 and %q", name, got, want)
		}
	}
}

func TestLegacyBinaryLogLosesRows(t *testing.T) {
	t.Parallel()
	dir := kit(t, files("| a | x |\n| b\x00c | x |\n| d | x |\n", "a b d\n"))
	stage(t, dir)
	got := runLegacy(t, dir, "C", "verify-tool-catalog.sh")
	if got.code != 0 || !strings.Contains(got.stdout, "(empty-input)") || !strings.Contains(got.stderr, "binary file matches") {
		t.Errorf("legacy printed %+v, want empty-input for a log that names three tools", got)
	}
}

func TestLegacyIgnoresExtraArguments(t *testing.T) {
	t.Parallel()
	dir := kit(t, files(logOf("a"), regOf("a")))
	stage(t, dir)
	if got := runLegacy(t, dir, "C", "verify-tool-catalog.sh", "x", "y"); got.code != 0 || got.stderr != "" {
		t.Errorf("legacy printed %+v, want the arguments ignored", got)
	}
}
