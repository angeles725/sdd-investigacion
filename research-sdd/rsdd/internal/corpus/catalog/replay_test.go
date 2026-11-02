package catalog

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
}

// TestReplay runs every case of testdata/replay (an input tree plus the stdout, exit code and CATALOG.md the frozen
// Python generator produced for it, see the legacy copy in testdata/legacy) and compares byte for byte. A case
// without a CATALOG.md in expect/ is one where the generator must not write one.
func TestReplay(t *testing.T) {
	cases, err := filepath.Glob(filepath.Join("testdata", "replay", "*", "in"))
	if err != nil || len(cases) == 0 {
		t.Fatalf("no replay cases found (err=%v): an empty corpus proves nothing", err)
	}
	for _, in := range cases {
		dir := filepath.Dir(in)
		t.Run(filepath.Base(dir), func(t *testing.T) {
			root := t.TempDir()
			copyTree(t, in, root)
			wantOut := mustRead(t, filepath.Join(dir, "expect", "stdout"))
			wantExit, _ := strconv.Atoi(strings.TrimSpace(string(mustRead(t, filepath.Join(dir, "expect", "exit")))))
			s, out, errb := stdio("/work")
			if rc := Run([]string{root}, s); rc != wantExit {
				t.Fatalf("exit = %d, want %d (stderr %q)", rc, wantExit, errb.String())
			}
			if !bytes.Equal(out.Bytes(), wantOut) {
				t.Errorf("stdout = %q, want %q", out.String(), wantOut)
			}
			got, gerr := os.ReadFile(filepath.Join(root, "CATALOG.md"))
			want, werr := os.ReadFile(filepath.Join(dir, "expect", "CATALOG.md"))
			switch {
			case werr == nil:
				if gerr != nil || !bytes.Equal(got, want) {
					t.Errorf("CATALOG.md differs (read err %v):\ngot  %q\nwant %q", gerr, got, want)
				}
			case wantExit == 0 && gerr == nil && string(got) == "STALE CONTENT\n":
				t.Errorf("stale CATALOG.md was not replaced")
			case wantExit != 0 && gerr == nil:
				t.Errorf("CATALOG.md written on a failed run: %q", got)
			}
		})
	}
}

func mustRead(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
