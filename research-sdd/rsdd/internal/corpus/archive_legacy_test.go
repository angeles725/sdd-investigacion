//go:build !nodiff

package corpus

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Everything that runs the frozen legacy script lives in this file and archive_shim_test.go, both excluded from the
// nodiff build (`make teeth`): a mutant must not re-run bash. The Go side is still replayed against the goldens by
// archive_golden_nodiff_test.go, so the kills do not depend on the oracle.

// archiveLegacySHA pins the frozen oracle: testdata/archive/legacy/research-sdd-archive.sh is the script as of the
// port (kit issue #2459). A changed oracle must be a deliberate, reviewed edit of this constant.
const archiveLegacySHA = "2242a219d0f3e99c9739065c10636ca36473e449e247d9b8ff37bea3907855c0"

const archiveLegacyRel = "testdata/archive/legacy/research-sdd-archive.sh"

var archiveUpdate = flag.Bool("update-archive", false, "re-record the archive goldens from the frozen legacy script")

func archiveExit(t testing.TB, err error) int {
	if err == nil {
		return 0
	}
	if x, ok := err.(*exec.ExitError); ok {
		return x.ExitCode()
	}
	t.Fatal(err)
	return -1
}

func init() {
	archiveLegacyRunner = archiveRunLegacy
	archiveLegacyInstall = func(t testing.TB, tb string) {
		t.Helper()
		b, err := os.ReadFile(archiveLegacyRel)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(tb, "research-sdd-archive.sh"), b, 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

func archiveRunLegacy(t testing.TB, tb, cwd string, args, env []string) (string, string, int) {
	t.Helper()
	c := exec.Command("bash", append([]string{filepath.Join(tb, "research-sdd-archive.sh")}, args...)...)
	c.Dir, c.Env = cwd, env
	hasBin := false
	for _, kv := range env {
		hasBin = hasBin || strings.HasPrefix(kv, "RSDD_BIN=")
	}
	if !hasBin {
		// The frozen script's kit fallback is the Go command `rsdd corpus catalog`, found through RSDD_BIN.
		c.Env = append(append([]string(nil), env...), "RSDD_BIN="+archiveRsddBin(t))
	}
	var o, e bytes.Buffer
	c.Stdout, c.Stderr = &o, &e
	err := c.Run()
	return o.String(), e.String(), archiveExit(t, err)
}

func TestArchiveOracleIsPinned(t *testing.T) {
	b, err := os.ReadFile(archiveLegacyRel)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	if got := hex.EncodeToString(sum[:]); got != archiveLegacySHA {
		t.Fatalf("frozen oracle changed: sha256 %s, pinned %s", got, archiveLegacySHA)
	}
}

// TestArchiveCases is the port's differential test: for every fixture case it runs the frozen legacy script and the Go
// command on separate restored copies of the same scratch tree and requires identical stdout, stderr, exit code and
// resulting tree; both sides must also equal the golden recorded from the legacy script (`-update-archive`
// re-records), and satisfy the predicates of the retired bash case.
func TestArchiveCases(t *testing.T) {
	if why := archiveHaveTools(); why != "" {
		t.Skip(why)
	}
	if testing.Short() {
		t.Skip("archive differential cases are slow")
	}
	for _, c := range archiveCases() {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			leg, gor, f, target := archiveRunCase(t, c, true)
			archiveCheck(t, "legacy", c, f, target, *leg)
			archiveCheck(t, "go", c, f, target, gor)
			archiveCheckFiles(t, "go", c, target, f)
			for _, p := range []struct{ name, a, b string }{
				{"stdout", leg.out, gor.out}, {"stderr", leg.err, gor.err},
				{"exit", fmt.Sprint(leg.code), fmt.Sprint(gor.code)}, {"tree", leg.tree, gor.tree}} {
				if p.a != p.b {
					t.Errorf("legacy and Go differ on %s:\n--- legacy\n%s\n--- go\n%s", p.name, p.a, p.b)
				}
			}
			if *archiveUpdate {
				archiveGoldenWrite(t, c.name, *leg, f.root)
				return
			}
			archiveCheckGolden(t, "legacy", c, *leg, f.root)
			archiveCheckGolden(t, "go", c, gor, f.root)
		})
	}
}

func archiveGoldenWrite(t *testing.T, name string, r archiveRes, root string) {
	t.Helper()
	dir := filepath.Join(archiveGoldenDir, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for file, content := range archiveGoldenFiles(r, root) {
		if err := os.WriteFile(filepath.Join(dir, file), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
