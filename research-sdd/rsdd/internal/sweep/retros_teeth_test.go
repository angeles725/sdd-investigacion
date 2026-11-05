package sweep

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Teeth for the pure helpers of retros.go (kit issue #2592): exact values at the edges the mutants moved.

func TestProfSec(t *testing.T) {
	for us, want := range map[int64]string{0: "0.000000", 5: "0.000005", 999999: "0.999999", 1000000: "1.000000", 1234567: "1.234567", 12000003: "12.000003"} {
		if got := profSec(us); got != want {
			t.Errorf("profSec(%d) = %q, want %q", us, got, want)
		}
	}
}

func TestAllDigitsEdges(t *testing.T) {
	for v, want := range map[string]bool{
		"": false, "0": true, "9": true, "0123456789": true,
		"/": false, ":": false, "1/": false, ":1": false, "a": false, "-1": false, " 1": false,
	} {
		if got := allDigits(v); got != want {
			t.Errorf("allDigits(%q) = %v, want %v", v, got, want)
		}
	}
}

func TestAtoi(t *testing.T) {
	for v, want := range map[string]int64{"1700000000": 1700000000, "0": 0, "-5": -5, "": 0, "x": 0, "12x": 0, "1.5": 0} {
		if got := atoi(v); got != want {
			t.Errorf("atoi(%q) = %d, want %d", v, got, want)
		}
	}
}

func TestAbsMakesARelativePathAbsolute(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := abs("rel/x.md"), filepath.Join(cwd, "rel/x.md"); got != want {
		t.Errorf("abs = %q, want %q", got, want)
	}
	if got := abs("/a/b/../c"); got != "/a/c" {
		t.Errorf("abs of an absolute path cleans it: %q", got)
	}
}

func TestCanonicalOfAFileThatIsNotThere(t *testing.T) {
	realDir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	link := realDir + "-link"
	if err := os.Symlink(realDir, link); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(link)
	if err := os.WriteFile(realDir+"/here.md", []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	for in, want := range map[string]string{
		link + "/here.md":    realDir + "/here.md", // resolved whole
		link + "/gone.md":    realDir + "/gone.md", // the file is missing: its directory is resolved
		link + "/no/gone.md": link + "/no/gone.md", // neither resolves: as given
		"gone-relative.md":   "gone-relative.md",   // no directory part
	} {
		if got := canonical(in); got != want {
			t.Errorf("canonical(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSortOldestFirst(t *testing.T) {
	type row struct {
		e  int64
		s  string
		id int
	}
	rows := []row{{2, "b", 1}, {1, "z", 2}, {2, "a", 3}, {1, "y", 4}, {10, "a", 5}, {2, "a", 6}}
	sortOldestFirst(rows, func(r row) int64 { return r.e }, func(r row) string { return r.s })
	var got []string
	for _, r := range rows {
		got = append(got, strings.Join([]string{string(rune('0' + r.e%10)), r.s, string(rune('0' + r.id))}, ""))
	}
	// 10 sorts after 2 (numeric epoch), equal epochs by serial, identical rows keep their order (3 before 6).
	if want := "1y4 1z2 2a3 2a6 2b1 0a5"; strings.Join(got, " ") != want {
		t.Errorf("order %v, want %s", got, want)
	}
}

func TestRetrosEnvelopeListsPendingAndMissingTogether(t *testing.T) {
	res := sweepResult{targets: 1, total: 1, pendingCnt: 1,
		rows:    []pendingRow{{file: "/t/retros/p.md", target: "/t", deltas: "2", dk: "counted", status: "pending", age: "3"}},
		missing: []string{"/t"}}
	var b strings.Builder
	writeRetrosEnvelope(&b, res)
	want := `{
  "schema": "research-sdd.sweep-retros/v1",
  "state": "ok",
  "counts": {
    "targets": 1,
    "targets_absent": 0,
    "targets_skipped": 0,
    "retros": 1,
    "pending": 1,
    "missing_retro": 1
  },
  "reason": null,
  "items": [
    {
      "kind": "pending-retro",
      "file": "/t/retros/p.md",
      "target": "/t",
      "deltas": 2,
      "deltas_state": "counted",
      "status": "pending",
      "age_days": 3,
      "age_state": "counted",
      "escalated": false,
      "warning": null
    },
    {
      "kind": "missing-retro",
      "target": "/t"
    }
  ]
}
`
	if b.String() != want {
		t.Errorf("got:\n%s\nwant:\n%s", b.String(), want)
	}
}
