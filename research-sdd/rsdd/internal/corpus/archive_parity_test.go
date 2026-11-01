package corpus

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

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

func archiveCompile(t *testing.T, f *archiveFx, pat string) *regexp.Regexp {
	t.Helper()
	pat = strings.ReplaceAll(pat, "@ROOT@", regexp.QuoteMeta(f.root))
	re, err := regexp.Compile("(?m)" + pat)
	if err != nil {
		t.Fatalf("bad pattern %q: %v", pat, err)
	}
	return re
}

// archiveCheck applies the old case's predicates to one side's result.
func archiveCheck(t *testing.T, side string, c archiveCase, f *archiveFx, d string, r archiveRes) {
	t.Helper()
	w := c.want
	all := r.out + r.err
	if w.rc >= 0 && r.code != w.rc {
		t.Errorf("%s: exit %d, want %d\n%s", side, r.code, w.rc, all)
	}
	for _, p := range w.has {
		if !archiveCompile(t, f, p).MatchString(all) {
			t.Errorf("%s: output lacks /%s/\n%s", side, p, all)
		}
	}
	for _, p := range w.lacks {
		if archiveCompile(t, f, p).MatchString(all) {
			t.Errorf("%s: output has /%s/\n%s", side, p, all)
		}
	}
	for _, p := range w.errHas {
		if !archiveCompile(t, f, p).MatchString(r.err) {
			t.Errorf("%s: stderr lacks /%s/\n%s", side, p, r.err)
		}
	}
	for _, p := range w.errNot {
		if archiveCompile(t, f, p).MatchString(r.err) {
			t.Errorf("%s: stderr has /%s/\n%s", side, p, r.err)
		}
	}
	// the tree is read after the run; files are checked against the manifest and, for content, the live tree
	_ = d
}

// archiveCheckFiles runs after a side, on the live tree of that side (the last side run is the Go side).
func archiveCheckFiles(t *testing.T, side string, c archiveCase, d string, f *archiveFx) {
	t.Helper()
	for _, rel := range c.want.files {
		if _, err := os.Lstat(filepath.Join(d, rel)); err != nil {
			t.Errorf("%s: %s not written", side, rel)
		}
	}
	for _, rel := range c.want.noFiles {
		if _, err := os.Lstat(filepath.Join(d, rel)); err == nil {
			t.Errorf("%s: %s must not exist", side, rel)
		}
	}
	for _, fh := range c.want.fileHas {
		b, err := os.ReadFile(filepath.Join(d, fh[0]))
		if err != nil || !regexp.MustCompile(fh[1]).Match(b) {
			t.Errorf("%s: %s does not match /%s/ (%v)", side, fh[0], fh[1], err)
		}
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

func archiveGoldenFiles(r archiveRes, root string) map[string]string {
	return map[string]string{
		"stdout": archiveNorm(r.out, root), "stderr": archiveNorm(r.err, root),
		"exit": strconv.Itoa(r.code) + "\n", "tree": archiveNorm(r.tree, root),
	}
}

// TestArchiveCases is the port's differential test: for every fixture case it runs the frozen legacy script and the Go
// command on separate restored copies of the same scratch tree and requires identical stdout, stderr, exit code and
// resulting tree; the Go result must also equal the golden recorded from the legacy script (`-update-archive`
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
			for file, want := range archiveGoldenFiles(gor, f.root) {
				b, err := os.ReadFile(filepath.Join(archiveGoldenDir, c.name, file))
				if err != nil {
					t.Fatalf("golden %s/%s: %v (run with -update-archive)", c.name, file, err)
				}
				if string(b) != want {
					t.Errorf("golden %s/%s differs:\n--- golden\n%s\n--- go\n%s", c.name, file, b, want)
				}
			}
		})
	}
}
