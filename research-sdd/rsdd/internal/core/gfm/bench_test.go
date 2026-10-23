package gfm

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The largest real table source in the repo is research-sdd/TARGETS.md (the registry). Go side: read once,
// then time parse + touching every cell. Bash side: the real gap_rows_parse over the same file via the driver
// (process start included, as every kit invocation pays it); BenchmarkBashStartup runs the same driver on an
// empty file so the per-process floor can be subtracted.
const targetsRel = "../../../../TARGETS.md"

func targetsBytes(b *testing.B) string {
	b.Helper()
	p, err := os.ReadFile(filepath.Clean(targetsRel))
	if err != nil {
		b.Fatalf("TARGETS.md not readable (%v): benchmark input moved", err)
	}
	return string(p)
}

func BenchmarkGoParseTargets(b *testing.B) {
	src := targetsBytes(b)
	b.SetBytes(int64(len(src)))
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		d := ParseWith(src, Options{})
		cells := 0
		for _, tb := range d.Tables {
			for _, r := range tb.Rows {
				cells += len(r.Text())
			}
		}
		if cells == 0 {
			b.Fatal("no cells parsed")
		}
	}
}

func BenchmarkGoRowsTargets(b *testing.B) {
	src := targetsBytes(b)
	b.SetBytes(int64(len(src)))
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		n := 0
		for r := range Rows(src, Options{}) {
			n += r.Len()
		}
		if n == 0 {
			b.Fatal("no cells parsed")
		}
	}
}

func benchBash(b *testing.B, file string) {
	if _, err := exec.LookPath("bash"); err != nil {
		b.Skip("bash not found in PATH; bash side of the comparison not measured")
	}
	tb, _ := filepath.Abs(toolbeltRel)
	script, _ := filepath.Abs(filepath.Join("testdata", "diff-driver.sh"))
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if out, err := exec.Command("bash", script, tb, "gaprows", file).CombinedOutput(); err != nil {
			b.Fatalf("driver failed: %v\n%s", err, out)
		}
	}
}

func BenchmarkBashGapRowsTargets(b *testing.B) {
	p, _ := filepath.Abs(targetsRel)
	benchBash(b, p)
}

func BenchmarkBashStartup(b *testing.B) {
	p := filepath.Join(b.TempDir(), "empty.md")
	if err := os.WriteFile(p, nil, 0o600); err != nil {
		b.Fatal(err)
	}
	benchBash(b, p)
}
