package parity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// runCorpusCase adds one corpus spec and runs it against the real corpus dir.
func runCorpusCase(t *testing.T, r *rig, corpus string, legacy, rsdd []string, files map[string]string) Result {
	t.Helper()
	if files == nil {
		files = map[string]string{}
	}
	r.addCase("c", legacy, rsdd, true, files)
	rep := r.runner.RunAll(r.load(), Options{CorpusMode: true, Corpora: []string{corpus}})
	if len(rep.Results) != 1 {
		t.Fatalf("want 1 result, got %d: %s", len(rep.Results), rep.Summary())
	}
	return rep.Results[0]
}

func assertUntouched(t *testing.T, dir string, before Tree) {
	t.Helper()
	if d := before.Diff(mustFingerprint(t, dir)); len(d) != 0 {
		t.Fatalf("the REAL corpus changed: %v", d)
	}
}

func TestSameWriteIsEqualEffectAndRealCorpusUntouched(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello"})
	before := mustFingerprint(t, c1)
	w := []string{"put={{corpus}}/f.md|new", "put={{corpus}}/added.md|a"}
	res := runCorpusCase(t, r, c1, w, w, nil)
	if res.Status != StatusEqual {
		t.Fatalf("identical writes must give an equal effect: %s %s", res.Status, joined(res.Problems))
	}
	assertUntouched(t, c1, before)
	if b, _ := os.ReadFile(filepath.Join(c1, "f.md")); string(b) != "hello" {
		t.Fatalf("real f.md was written: %q", b)
	}
}

func TestDifferentWriteIsAnEffectMismatch(t *testing.T) {
	tests := []struct {
		name         string
		legacy, rsdd []string
	}{
		{"different content", []string{"put={{corpus}}/f.md|AAA"}, []string{"put={{corpus}}/f.md|BBB"}},
		{"only legacy writes", []string{"touch={{corpus}}/new.md"}, []string{"out="}},
		{"only rsdd writes", []string{"out="}, []string{"touch={{corpus}}/new.md"}},
		{"different file", []string{"put={{corpus}}/x.md|1"}, []string{"put={{corpus}}/y.md|1"}},
		{"removal", []string{"rm={{corpus}}/f.md"}, []string{"out="}},
		{"mode change", []string{"chmod=755|{{corpus}}/f.md"}, []string{"out="}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t)
			c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello"})
			before := mustFingerprint(t, c1)
			res := runCorpusCase(t, r, c1, tt.legacy, tt.rsdd, nil)
			if res.Status != StatusFailed || !hasKind(res.Problems, KindUndeclared) || !strings.Contains(joined(res.Problems), "effect differs") {
				t.Fatalf("want an undeclared effect mismatch, got %s\n%s", res.Status, joined(res.Problems))
			}
			if hasKind(res.Problems, KindCorpusMod) {
				t.Fatalf("the tripwire must be unreachable: %s", joined(res.Problems))
			}
			assertUntouched(t, c1, before)
		})
	}
}

func TestEffectDeclarations(t *testing.T) {
	diff := func(r *rig, c1 string, files map[string]string) Result {
		return runCorpusCase(t, r, c1, []string{"put={{corpus}}/f.md|1"}, []string{"put={{corpus}}/f.md|2"}, files)
	}
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello"})
	res := diff(r, c1, map[string]string{"intended.json": `[{"field":"effect","reason":"rsdd writes the new schema"}]`})
	if res.Status != StatusDeclared {
		t.Fatalf("declared effect divergence honoured: %s %s", res.Status, joined(res.Problems))
	}

	r = newRig(t)
	same := []string{"put={{corpus}}/f.md|1"}
	res = runCorpusCase(t, r, c1, same, same, map[string]string{"intended.json": `[{"field":"effect","reason":"was different once"}]`})
	if res.Status != StatusFailed || !hasKind(res.Problems, KindStale) || !strings.Contains(joined(res.Problems), "effect") {
		t.Fatalf("a stale effect declaration fails: %s %s", res.Status, joined(res.Problems))
	}

	r = newRig(t)
	res = diff(r, c1, map[string]string{"intended.json": `[{"field":"effect","reason":" "}]`})
	if res.Status != StatusFailed || !hasKind(res.Problems, KindNoReason) {
		t.Fatalf("an effect declaration without a reason fails: %s %s", res.Status, joined(res.Problems))
	}
}

func TestEachSideGetsAFreshCopy(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello"})
	files := map[string]string{"intended.json": `[{"field":"stdout","reason":"legacy sees its own leak"},{"field":"effect","reason":"legacy wrote, rsdd did not"}]`}
	res := runCorpusCase(t, r, c1,
		[]string{"put={{corpus}}/leak|1", "exists={{corpus}}/leak"},
		[]string{"exists={{corpus}}/leak"}, files)
	if res.Status != StatusDeclared {
		t.Fatalf("rsdd saw legacy's write (copy not recreated) or the effects were not computed per side: %s %s", res.Status, joined(res.Problems))
	}
}

func TestCorpusPathIsTheSameForBothSidesAndNotTheRealOne(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello"})
	want := filepath.Join(r.runner.Cfg.Work, "sandbox", "corpus")
	res := runCorpusCase(t, r, c1, []string{"out={{corpus}}"}, []string{"out=" + want}, nil)
	if res.Status != StatusEqual {
		t.Fatalf("{{corpus}} must be the scratch copy inside the sandbox on both sides: %s %s", res.Status, joined(res.Problems))
	}
	r = newRig(t)
	res = runCorpusCase(t, r, c1, []string{"out={{corpus}}"}, []string{"out=" + c1}, nil)
	if res.Status != StatusFailed {
		t.Fatal("{{corpus}} resolved to the real corpus path")
	}
}

func TestCopyTreePreservesLinksModesAndSkipsGit(t *testing.T) {
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "o.md"), []byte("o"), 0o644)
	src := filepath.Join(t.TempDir(), "src")
	os.MkdirAll(filepath.Join(src, "ro"), 0o755)
	os.MkdirAll(filepath.Join(src, ".git"), 0o755)
	os.WriteFile(filepath.Join(src, ".git", "HEAD"), []byte("ref"), 0o644)
	os.WriteFile(filepath.Join(src, "x.sh"), []byte("#!/bin/sh\n"), 0o755)
	os.WriteFile(filepath.Join(src, "private"), []byte("p"), 0o600)
	os.WriteFile(filepath.Join(src, "ro", "f"), []byte("f"), 0o444)
	os.Symlink(outside, filepath.Join(src, "dlink"))
	os.Symlink(filepath.Join(outside, "o.md"), filepath.Join(src, "flink"))
	os.Chmod(filepath.Join(src, "ro"), 0o555)
	t.Cleanup(func() { os.Chmod(filepath.Join(src, "ro"), 0o755) })

	dst := filepath.Join(t.TempDir(), "dst")
	if err := copyTree(src, dst, true); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(filepath.Join(dst, "ro"), 0o755) })

	perm := func(rel string) os.FileMode {
		st, err := os.Lstat(filepath.Join(dst, rel))
		if err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
		return st.Mode().Perm()
	}
	for rel, want := range map[string]os.FileMode{"x.sh": 0o755, "private": 0o600, "ro/f": 0o444, "ro": 0o555} {
		if got := perm(rel); got != want {
			t.Errorf("%s: mode %04o, want %04o", rel, got, want)
		}
	}
	for rel, want := range map[string]string{"dlink": outside, "flink": filepath.Join(outside, "o.md")} {
		st, err := os.Lstat(filepath.Join(dst, rel))
		if err != nil || st.Mode()&os.ModeSymlink == 0 {
			t.Fatalf("%s must stay a symlink: %v %v", rel, st, err)
		}
		if got, _ := os.Readlink(filepath.Join(dst, rel)); got != want {
			t.Errorf("%s -> %q, want %q", rel, got, want)
		}
	}
	if _, err := os.Lstat(filepath.Join(dst, ".git")); !os.IsNotExist(err) {
		t.Fatalf(".git must be skipped when skipGit is set: %v", err)
	}

	dst2 := filepath.Join(t.TempDir(), "dst2")
	if err := copyTree(src, dst2, false); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(filepath.Join(dst2, "ro"), 0o755) })
	if _, err := os.Stat(filepath.Join(dst2, ".git", "HEAD")); err != nil {
		t.Fatalf(".git is kept when skipGit is false: %v", err)
	}
}

func TestReadOnlyDirsDoNotBreakTheSandboxWipe(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"ro/f.md": "x"})
	if err := os.Chmod(filepath.Join(c1, "ro"), 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(filepath.Join(c1, "ro"), 0o755) })
	t.Cleanup(func() {
		if err := r.runner.Cleanup(); err != nil {
			t.Error(err)
		}
	})
	r.addCase("c", []string{"catf={{corpus}}/ro/f.md"}, []string{"catf={{corpus}}/ro/f.md"}, true, map[string]string{})
	cases := r.load()
	for i := range 2 {
		rep := r.runner.RunAll(cases, Options{CorpusMode: true, Corpora: []string{c1}})
		if rep.Failed() || rep.Counts.Equal != 1 {
			t.Fatalf("run %d: %s %v", i, rep.Summary(), rep.Results)
		}
	}
}

func TestGitDirIsNotCopiedIntoTheScratchCorpus(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "x", ".git/HEAD": "ref"})
	res := runCorpusCase(t, r, c1, []string{"exists={{corpus}}/.git", "exists={{corpus}}/f.md"}, []string{"out=noyes"}, nil)
	if res.Status != StatusEqual {
		t.Fatalf("%s %s", res.Status, joined(res.Problems))
	}
}

// The tripwire: if the real corpus ever changes it is a typed corpus-modified.
func TestCheckCorpusTripwire(t *testing.T) {
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "x"})
	before := mustFingerprint(t, c1)
	if p := checkCorpus("legacy", c1, before); len(p) != 0 {
		t.Fatalf("unchanged corpus: %v", p)
	}
	os.WriteFile(filepath.Join(c1, "f.md"), []byte("xx"), 0o644)
	p := checkCorpus("rsdd", c1, before)
	if !hasKind(p, KindCorpusMod) || !strings.Contains(joined(p), "rsdd") || !strings.Contains(joined(p), "f.md") {
		t.Fatalf("want corpus-modified naming the side and the path: %v", p)
	}
	if p := checkCorpus("rsdd", filepath.Join(c1, "gone"), before); !hasKind(p, KindCorpusRead) {
		t.Fatalf("an unreadable corpus is corpus-unreadable: %v", p)
	}
}

func TestFixtureInputsGetTheSameEffectTreatment(t *testing.T) {
	r := newRig(t)
	files := map[string]string{"inputs/a.txt": "orig"}
	res, _ := r.run([]string{"put={{input}}/a.txt|x"}, []string{"put={{input}}/a.txt|x"}, files)
	if res.Status != StatusEqual {
		t.Fatalf("same fixture write: %s %s", res.Status, joined(res.Problems))
	}
	r = newRig(t)
	res, _ = r.run([]string{"put={{input}}/a.txt|x"}, []string{"put={{input}}/a.txt|y"}, map[string]string{"inputs/a.txt": "orig"})
	if res.Status != StatusFailed || !strings.Contains(joined(res.Problems), "effect differs") {
		t.Fatalf("different fixture write: %s %s", res.Status, joined(res.Problems))
	}
	r = newRig(t)
	res, _ = r.run([]string{"touch={{input}}/new.txt"}, []string{"out="}, map[string]string{"inputs/a.txt": "orig"})
	if res.Status != StatusFailed || !strings.Contains(joined(res.Problems), "effect differs") {
		t.Fatalf("one-sided fixture write: %s %s", res.Status, joined(res.Problems))
	}
}

func TestCasesWithoutATreeHaveNoEffect(t *testing.T) {
	r := newRig(t)
	res, _ := r.run([]string{"out=a"}, []string{"out=a"}, map[string]string{"intended.json": `[{"field":"effect","reason":"nothing to diff"}]`})
	if res.Status != StatusFailed || !hasKind(res.Problems, KindStale) {
		t.Fatalf("no tree means no effect, so an effect declaration is stale: %s %s", res.Status, joined(res.Problems))
	}
}
