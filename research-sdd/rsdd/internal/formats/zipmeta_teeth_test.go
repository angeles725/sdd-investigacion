//go:build linux

package formats

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

func TestZipReportGuardBoundary(t *testing.T) {
	e := ZipEntry{Name: "a", NameEncoding: "cp437", NameRaw: []byte("a")}
	b, err := jsonout.CanonicalUnicode(zipRecord(&e))
	if err != nil {
		t.Fatal(err)
	}
	line := int64(len(b))
	const over = "canonical report exceeds max-report-bytes"
	for name, c := range map[string]struct {
		max   int64
		calls int
		want  string // the message of the last call
	}{
		"one record at the cap":        {line, 1, ""},
		"one record over the cap":      {line - 1, 1, over},
		"two records at the cap":       {2 * line, 2, ""},
		"two records over the cap":     {2*line - 1, 2, over},
		"third record over the cap":    {2 * line, 3, over},
		"empty report, zero cap":       {0, 0, ""},
		"first record over a zero cap": {0, 1, over},
	} {
		g := zipReportGuard(c.max)
		var err error
		for i := 0; i < c.calls; i++ {
			if err = g(&e); err != nil && i < c.calls-1 {
				t.Errorf("%s: call %d failed early: %v", name, i+1, err)
			}
		}
		if got := zipErrorMessage(err); got != c.want {
			t.Errorf("%s: error %q, want %q", name, got, c.want)
		}
	}
}

func TestZipMetadataInputCapBoundary(t *testing.T) {
	data := buildZip([]zfx{{name: []byte("a"), payload: []byte("a")}}, zipOpts{})
	in := filepath.Join(t.TempDir(), "a.zip")
	if err := os.WriteFile(in, data, 0o600); err != nil {
		t.Fatal(err)
	}
	size := int64(len(data))
	if code, _, stderr := runGo(t, ZipMetadata, "/", metaArgs(t, in, filepath.Join(pub(t), "out"), "--max-input-bytes", strconv.FormatInt(size, 10))...); code != 0 {
		t.Errorf("input exactly at the cap: exit %d %q", code, stderr)
	}
	code, _, stderr := runGo(t, ZipMetadata, "/", metaArgs(t, in, filepath.Join(pub(t), "out"), "--max-input-bytes", strconv.FormatInt(size-1, 10))...)
	if code == 0 || !strings.Contains(stderr, "zip-metadata: input exceeds max-input-bytes\n") {
		t.Errorf("input one over the cap: exit %d %q", code, stderr)
	}
}

// reportCapFixedPoint finds the smallest max-report-bytes the report fits in. The report echoes the cap, so
// its length depends on the number of digits in the cap: the length P(c) = base - digits(base cap) + digits(c)
// and the cap that equals its own report length is the exact boundary.
func reportCapFixedPoint(t *testing.T, run func(cap int64) (int, string, int64)) int64 {
	t.Helper()
	const probe = 9999999
	code, stderr, base := run(probe)
	if code != 0 {
		t.Fatalf("probe run: exit %d %q", code, stderr)
	}
	for d := int64(1); d <= 7; d++ {
		c := base - 7 + d
		if int64(len(strconv.FormatInt(c, 10))) == d {
			return c
		}
	}
	t.Fatalf("no fixed point for a report of %d bytes", base)
	return 0
}

func TestZipMetadataReportCapBoundary(t *testing.T) {
	data := buildZip([]zfx{{name: []byte("a"), payload: []byte("a")}}, zipOpts{})
	in := filepath.Join(t.TempDir(), "a.zip")
	if err := os.WriteFile(in, data, 0o600); err != nil {
		t.Fatal(err)
	}
	run := func(cap int64) (int, string, int64) {
		out := filepath.Join(pub(t), "out")
		code, _, stderr := runGo(t, ZipMetadata, "/", metaArgs(t, in, out, "--max-report-bytes", strconv.FormatInt(cap, 10))...)
		var size int64
		if code == 0 {
			b, err := os.ReadFile(filepath.Join(out, "zip-metadata.v1.json"))
			if err != nil {
				t.Fatal(err)
			}
			size = int64(len(b))
		}
		return code, stderr, size
	}
	c := reportCapFixedPoint(t, run)
	if code, stderr, size := run(c); code != 0 || size != c {
		t.Errorf("cap %d (the report length): exit %d %q, report %d bytes", c, code, stderr, size)
	}
	code, stderr, _ := run(c - 1)
	if code == 0 || !strings.Contains(stderr, "zip-metadata: canonical report exceeds max-report-bytes\n") {
		t.Errorf("cap %d (one under the report length): exit %d %q", c-1, code, stderr)
	}
}
