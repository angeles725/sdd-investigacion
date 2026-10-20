package parity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func mkCorpus(t *testing.T, name string, files map[string]string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for rel, body := range files {
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestCorpusUnchangedIsEqual(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello"})
	r.addCase("read", []string{"catf={{corpus}}/f.md"}, []string{"catf={{corpus}}/f.md"}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{CorpusMode: true, Corpora: []string{c1}})
	if rep.Failed() || rep.Counts.Equal != 1 || rep.Counts.Compared != 1 {
		t.Fatalf("%s\n%v", rep.Summary(), rep.Results)
	}
}

func TestCorpusWriteIsDetected(t *testing.T) {
	for _, side := range []string{"legacy", "rsdd"} {
		t.Run(side, func(t *testing.T) {
			r := newRig(t)
			c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello"})
			legacy, rsdd := []string{"catf={{corpus}}/f.md"}, []string{"catf={{corpus}}/f.md"}
			if side == "legacy" {
				legacy = append(legacy, "touch={{corpus}}/f.md")
			} else {
				rsdd = append(rsdd, "touch={{corpus}}/f.md")
			}
			r.addCase("write", legacy, rsdd, true, map[string]string{})
			rep := r.runner.RunAll(r.load(), Options{CorpusMode: true, Corpora: []string{c1}})
			if !rep.Failed() || len(rep.Results) != 1 {
				t.Fatalf("a write into the corpus must fail: %s", rep.Summary())
			}
			p := firstProblems(t, rep)
			if !hasKind(p, KindCorpusMod) || !strings.Contains(joined(p), side) || !strings.Contains(joined(p), "f.md") {
				t.Fatalf("want corpus-modified naming %s and f.md, got:\n%s", side, joined(p))
			}
		})
	}
}

func TestCorpusCreateIsDetected(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello"})
	r.addCase("make", []string{"touch={{corpus}}/new.md"}, []string{"out="}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{CorpusMode: true, Corpora: []string{c1}})
	if !rep.Failed() || !hasKind(firstProblems(t, rep), KindCorpusMod) || !strings.Contains(joined(firstProblems(t, rep)), "new.md") {
		t.Fatalf("a created file must be reported: %s %v", rep.Summary(), rep.Results)
	}
}

func TestAbsentCorporaAreCountedNotDropped(t *testing.T) {
	r := newRig(t)
	real1 := mkCorpus(t, "one", map[string]string{"f.md": "a"})
	absent := filepath.Join(t.TempDir(), "gone")
	notDir := filepath.Join(real1, "f.md")
	r.addCase("read", []string{"catf={{corpus}}/f.md"}, []string{"catf={{corpus}}/f.md"}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{CorpusMode: true, Corpora: []string{absent, real1, notDir}})
	if rep.Counts.AbsentCorpora != 2 || len(rep.Absent) != 2 {
		t.Fatalf("absent corpora = %d (%v), want 2", rep.Counts.AbsentCorpora, rep.Absent)
	}
	if rep.Absent[0].Path != absent || rep.Absent[1].Path != notDir {
		t.Fatalf("absent entries out of order or wrong: %v", rep.Absent)
	}
	if rep.Counts.Compared != 1 || rep.Failed() {
		t.Fatalf("only the existing corpus is compared: %s", rep.Summary())
	}
	if !strings.Contains(rep.Summary(), "absent-corpora=2") {
		t.Fatalf("summary hides the absent corpora: %s", rep.Summary())
	}
}

func TestCorpusModeOffSkipsCorpusSpecs(t *testing.T) {
	r := newRig(t)
	r.addCase("plain", []string{"out=a"}, []string{"out=a"}, false, map[string]string{})
	r.addCase("opt", []string{"catf={{corpus}}/x"}, []string{"catf={{corpus}}/x"}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{})
	if rep.Counts.Skipped != 1 || rep.Counts.Equal != 1 || rep.Counts.Compared != 1 || rep.Failed() {
		t.Fatalf("%s", rep.Summary())
	}
}

func TestCorpusModeWithZeroCorporaFails(t *testing.T) {
	r := newRig(t)
	r.addCase("opt", []string{"catf={{corpus}}/x"}, []string{"catf={{corpus}}/x"}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{CorpusMode: true})
	if !rep.Failed() || !hasKind(lastProblems(t, rep), KindEmptyInput) {
		t.Fatalf("corpus mode with 0 corpora is empty-input, not a pass: %s %v", rep.Summary(), rep.Results)
	}
}

func TestRunAllEmptyCases(t *testing.T) {
	r := newRig(t)
	rep := r.runner.RunAll(nil, Options{})
	if !rep.Failed() || !hasKind(firstProblems(t, rep), KindEmptyInput) {
		t.Fatalf("0 cases must not look like a pass: %s", rep.Summary())
	}
}

func TestPlainSpecRunsOnceInCorpusMode(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "a"})
	c2 := mkCorpus(t, "two", map[string]string{"f.md": "b"})
	r.addCase("plain", []string{"out=a"}, []string{"out=a"}, false, map[string]string{})
	r.addCase("opt", []string{"catf={{corpus}}/f.md"}, []string{"catf={{corpus}}/f.md"}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{CorpusMode: true, Corpora: []string{c1, c2}})
	if rep.Counts.Compared != 3 || rep.Counts.Equal != 3 {
		t.Fatalf("1 plain run + 2 corpus runs expected: %s", rep.Summary())
	}
}

func TestSummaryLine(t *testing.T) {
	r := newRig(t)
	r.addCase("a-eq", []string{"out=a"}, []string{"out=a"}, false, map[string]string{})
	r.addCase("b-decl", []string{"out=a"}, []string{"out=b"}, false, map[string]string{"intended.json": `[{"field":"stdout","reason":"r"}]`})
	r.addCase("c-fail", []string{"out=a"}, []string{"out=b"}, false, map[string]string{})
	r.addCase("d-skip", []string{"catf={{corpus}}/x"}, []string{"catf={{corpus}}/x"}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{})
	want := "parity: compared=3 equal=1 declared-divergent=1 failed=1 absent-corpora=0 skipped=1"
	if rep.Summary() != want {
		t.Fatalf("summary\n got %q\nwant %q", rep.Summary(), want)
	}
}

func TestCorpusTimeoutStillCheckedForWrites(t *testing.T) {
	r := newRig(t)
	r.runner.Cfg.Timeout = 300 * time.Millisecond
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "a"})
	r.addCase("slow", []string{"touch={{corpus}}/f.md", "sleep=30"}, []string{"out="}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{CorpusMode: true, Corpora: []string{c1}})
	p := firstProblems(t, rep)
	if !hasKind(p, KindTimeout) || !hasKind(p, KindCorpusMod) {
		t.Fatalf("a timed-out run that already wrote must report both:\n%s", joined(p))
	}
}

func TestFingerprint(t *testing.T) {
	dir := mkCorpus(t, "fp", map[string]string{"a.md": "aa", "sub/b.md": "bb", ".git/HEAD": "ref"})
	base, err := Fingerprint(dir)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := Fingerprint(dir)
	if d := base.Diff(again); len(d) != 0 {
		t.Fatalf("an untouched tree must not differ: %v", d)
	}
	for k := range base {
		if strings.Contains(k, ".git") {
			t.Fatalf(".git must be skipped, saw %s", k)
		}
	}
	if len(base) < 3 { // root, a.md, sub, sub/b.md
		t.Fatalf("fingerprint looks empty: %v", base)
	}

	mutations := []struct {
		name string
		do   func()
		want string
	}{
		{"size", func() { os.WriteFile(filepath.Join(dir, "a.md"), []byte("aaa"), 0o644) }, "a.md"},
		{"same-size content, new mtime", func() {
			p := filepath.Join(dir, "sub", "b.md")
			os.WriteFile(p, []byte("XX"), 0o644)
			future := time.Now().Add(3 * time.Hour)
			os.Chtimes(p, future, future)
		}, "b.md"},
		{"mode", func() { os.Chmod(filepath.Join(dir, "a.md"), 0o600) }, "a.md"},
		{"added", func() { os.WriteFile(filepath.Join(dir, "new.md"), nil, 0o644) }, "new.md"},
		{"removed", func() { os.Remove(filepath.Join(dir, "sub", "b.md")) }, "b.md"},
	}
	for _, m := range mutations {
		t.Run(m.name, func(t *testing.T) {
			before, err := Fingerprint(dir)
			if err != nil {
				t.Fatal(err)
			}
			m.do()
			after, err := Fingerprint(dir)
			if err != nil {
				t.Fatal(err)
			}
			d := before.Diff(after)
			if len(d) == 0 || !strings.Contains(strings.Join(d, "\n"), m.want) {
				t.Fatalf("%s change not reported (want %s): %v", m.name, m.want, d)
			}
		})
	}
	// .git changes are ignored.
	before, _ := Fingerprint(dir)
	os.WriteFile(filepath.Join(dir, ".git", "HEAD"), []byte("different"), 0o644)
	after, _ := Fingerprint(dir)
	if d := before.Diff(after); len(d) != 0 {
		t.Fatalf(".git edits must be invisible: %v", d)
	}
}

func TestFingerprintAbsentRootIsAnError(t *testing.T) {
	if _, err := Fingerprint(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Fatal("an absent root must be an error, not an empty tree")
	}
}

func TestFingerprintDiffIsBounded(t *testing.T) {
	a, b := Tree{}, Tree{}
	for i := range 100 {
		b[filepath.Join("f", string(rune('a'+i%26)), string(rune('A'+i/26)))] = "x"
	}
	d := a.Diff(b)
	if len(d) == 0 || len(d) > 15 || !strings.Contains(d[len(d)-1], "more") {
		t.Fatalf("diff must be capped and say how many were cut: %d lines: %q", len(d), strings.Join(d, "|"))
	}
}
