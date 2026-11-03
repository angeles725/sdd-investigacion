package corpus

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

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

// archiveCheckGolden requires one side's result to equal the golden recorded from the legacy script.
func archiveCheckGolden(t *testing.T, side string, c archiveCase, r archiveRes, root string) {
	t.Helper()
	for file, want := range archiveGoldenFiles(r, root) {
		b, err := os.ReadFile(filepath.Join(archiveGoldenDir, c.name, file))
		if err != nil {
			t.Fatalf("golden %s/%s: %v (run with -update-archive)", c.name, file, err)
		}
		if string(b) != want {
			t.Errorf("%s: golden %s/%s differs:\n--- golden\n%s\n--- %s\n%s", side, c.name, file, b, side, want)
		}
	}
}

func archiveGoldenFiles(r archiveRes, root string) map[string]string {
	return map[string]string{
		"stdout": archiveNorm(r.out, root), "stderr": archiveNorm(r.err, root),
		"exit": strconv.Itoa(r.code) + "\n", "tree": archiveNorm(r.tree, root),
	}
}
