//go:build linux

package formats

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestZipStoredReportCapBoundary(t *testing.T) {
	data := buildZip([]zfx{{name: []byte("a"), payload: []byte("a"), attrs: teethReg}}, teethStoredOpts)
	in := filepath.Join(t.TempDir(), "a.zip")
	if err := os.WriteFile(in, data, 0o600); err != nil {
		t.Fatal(err)
	}
	run := func(cap int64) (int, string, int64) {
		out := filepath.Join(pub(t), "out")
		code, _, stderr := runGo(t, ZipStored, "/", storedArgs(t, in, out, "--max-report-bytes", strconv.FormatInt(cap, 10))...)
		var size int64
		if code == 0 {
			b, err := os.ReadFile(filepath.Join(out, "zip-stored.v1.json"))
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
	if code == 0 || !strings.Contains(stderr, "zip-stored: canonical report exceeds max-report-bytes\n") {
		t.Errorf("cap %d (one under the report length): exit %d %q", c-1, code, stderr)
	}
}

func TestStageInputCapBoundary(t *testing.T) {
	data := bytesOf(2*1024+7, 'z')
	in := filepath.Join(t.TempDir(), "in.zip")
	if err := os.WriteFile(in, data, 0o600); err != nil {
		t.Fatal(err)
	}
	size := int64(len(data))
	for name, c := range map[string]struct {
		limit int64
		want  string
	}{"at the cap": {size, ""}, "one over the cap": {size - 1, "input exceeds max-input-bytes"}} {
		dir := t.TempDir()
		root, err := os.OpenRoot(dir)
		if err != nil {
			t.Fatal(err)
		}
		got, err := stageInput(in, root, c.limit)
		root.Close()
		if msg := zipErrorMessage(err); msg != c.want {
			t.Errorf("%s: error %q, want %q", name, msg, c.want)
			continue
		}
		if c.want == "" {
			staged, rerr := os.ReadFile(filepath.Join(dir, "archive.zip"))
			if rerr != nil || string(staged) != string(data) || got.size != size {
				t.Errorf("%s: staged %d bytes (%v), recorded size %d", name, len(staged), rerr, got.size)
			}
		}
	}
}

func bytesOf(n int, b byte) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}
