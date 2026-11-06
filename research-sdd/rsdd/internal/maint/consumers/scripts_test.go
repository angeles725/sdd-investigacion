package consumers

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sprintf(f string, a ...any) string { return fmt.Sprintf(f, a...) }

func TestFileListCountsUntrackedNotIgnored(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{"research-sdd/toolbelt/tracked.sh": "x", ".gitignore": "ignored.sh\n"})
	f.commit()
	f.files(map[string]string{"research-sdd/toolbelt/untracked.sh": "x", "research-sdd/toolbelt/ignored.sh": "x"})
	got := f.run()
	if got.rc != 0 || got.err != "" {
		t.Fatalf("rc %d, err %q", got.rc, got.err)
	}
	if l := line(got.out, "scripts: "); l != "scripts: 2 (sh 2)" {
		t.Fatalf("%q", l)
	}
	if l := line(got.out, "files: "); l != "files: 3 listed (tracked, and untracked but not ignored)" {
		t.Fatalf("%q", l)
	}
}

func TestScriptExtensionsAndRoots(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{
		"research-sdd/toolbelt/a.sh": "x", "research-sdd/toolbelt/b.sh": "x", "research-sdd/templates/c.py": "x",
		"research-sdd/install/d.mjs": "x", "research-sdd/install/e.cjs": "x", "research-sdd/install/f.js": "x",
		"research-sdd/toolbelt/g.ts": "x", "research-sdd/toolbelt/H.java": "x", "research-sdd/toolbelt/i.java": "x",
		"research-sdd/toolbelt/j.txt": "x", "research-sdd/toolbelt/K.SH": "x", "research-sdd/toolbelt/l.bash": "x",
		"research-sdd/toolbelt/noext": "x", "research-sdd/rsdd/m.sh": "x", "research-sdd/other/n.sh": "x", "o.sh": "x",
		"research-sdd/toolbelt/.ts": "x", // a name that is only an extension has that extension
	})
	f.commit()
	got := f.run()
	if l := line(got.out, "scripts: "); l != "scripts: 10 (java 2, sh 2, ts 2, cjs 1, js 1, mjs 1, py 1)" {
		t.Fatalf("%q", l)
	}
}

func TestEachExclusionIsCountedWithItsFiles(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{
		"research-sdd/toolbelt/live.sh":                      "x",
		"research-sdd/toolbelt/tests/run-all.sh":             "x",
		"research-sdd/toolbelt/tests/a.test.sh":              "x",
		"research-sdd/toolbelt/tests/b.test.mjs":             "x",
		"research-sdd/toolbelt/tests/fixtures/c.sh":          "x",
		"research-sdd/toolbelt/tests/fixtures/d.test.sh":     "x",
		"research-sdd/templates/fixtures/e.py":               "x",
		"research-sdd/install/node_modules/pkg/index.js":     "x",
		"research-sdd/install/node_modules/fixtures/deep.js": "x",
	})
	f.commit()
	got := f.run()
	const want = "excluded from the script list: `.test.` in the name 2, `fixtures` directory 4, `node_modules` 1"
	if l := line(got.out, "excluded from the script list: "); l != want {
		t.Fatalf("%q", l)
	}
	if l := line(got.out, "scripts: "); l != "scripts: 2 (sh 2)" {
		t.Fatalf("%q", l)
	}
}

func TestFixturesClaimTheFileBeforeTheTestRule(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{"research-sdd/toolbelt/live.sh": "x", "research-sdd/toolbelt/fixtures/only.test.sh": "x"})
	f.commit()
	const want = "excluded from the script list: `.test.` in the name 0, `fixtures` directory 1, `node_modules` 0"
	if l := line(f.run().out, "excluded from the script list: "); l != want {
		t.Fatalf("%q", l)
	}
}

func TestExclusionsReadZeroAsAWord(t *testing.T) {
	f := newFixture(t)
	f.write("research-sdd/toolbelt/live.sh", "x")
	f.commit()
	const want = "excluded from the script list: `.test.` in the name 0, `fixtures` directory 0, `node_modules` 0"
	if l := line(f.run().out, "excluded from the script list: "); l != want {
		t.Fatalf("%q", l)
	}
}

func TestAmbiguousBasenames(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{"research-sdd/toolbelt/z.sh": "x", "research-sdd/templates/z.sh": "x", "research-sdd/install/a.js": "x", "research-sdd/toolbelt/a.js": "x", "research-sdd/toolbelt/u.sh": "x"})
	f.commit()
	got := f.run()
	if l := line(got.out, "ambiguous basenames: "); l != "ambiguous basenames: 2 (a.js, z.sh)" {
		t.Fatalf("%q", l)
	}
	if l := line(got.out, "scripts: "); l != "scripts: 5 (sh 3, js 2)" {
		t.Fatalf("%q", l)
	}
	f2 := newFixture(t)
	f2.write("research-sdd/toolbelt/u.sh", "x")
	f2.commit()
	if l := line(f2.run().out, "ambiguous basenames: "); l != "ambiguous basenames: none" {
		t.Fatalf("%q", l)
	}
}

func TestRepoDefaultsToTheWorkTreeHoldingTheWorkingDirectory(t *testing.T) {
	f := newFixture(t)
	f.write("research-sdd/toolbelt/a.sh", "x")
	f.commit()
	want := "consumers: repository " + f.dir
	sub := f.dir + "/research-sdd/toolbelt"
	got := runIn(sub, f.env)
	if l := line(got.out, "consumers: "); got.rc != 0 || l != want {
		t.Fatalf("from a subdirectory: rc %d, %q", got.rc, l)
	}
	if l := line(got.out, "kit: "); l != "kit: "+f.dir+"/research-sdd" {
		t.Fatalf("%q", l)
	}
	got = runIn(f.root, f.env, "--repo", "r")
	if l := line(got.out, "consumers: "); got.rc != 0 || l != want {
		t.Fatalf("--repo relative to the working directory: rc %d, %q", got.rc, l)
	}
}

func TestLimitsAreStatedOnEveryRun(t *testing.T) {
	f := newFixture(t)
	f.write("research-sdd/toolbelt/a.sh", "x")
	f.commit()
	got := f.run()
	want := []string{
		"Go classes: not enumerated by this version (production code, tests, generated, assembled, embedded).",
		"limits:",
		"  names that arrive through a flag or an environment variable are not seen",
		"  names built at run time are not seen",
		"  globs are not expanded: a pattern that matches a script is not a reference to it",
		"  names without the extension are not matched",
		"  nothing outside the repository is read: other repositories, installed copies, harness homes, git history",
		"  a match is a whole-name occurrence in text, not proof of a call: prose and comments count",
	}
	if !strings.Contains(got.out, strings.Join(want, "\n")+"\n") {
		t.Fatalf("limits block not found in:\n%s", got.out)
	}
}

func TestRunWritesNothingUnderTheRepository(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{"research-sdd/toolbelt/a.sh": "b.sh", "research-sdd/toolbelt/b.sh": "a.sh", "README.md": "a.sh"})
	f.commit()
	f.write("research-sdd/toolbelt/untracked.sh", "a.sh")
	before := snapshot(t, f.dir)
	if got := f.run(); got.rc != 0 || got.out == "" {
		t.Fatalf("rc %d, stdout %q, stderr %q", got.rc, got.out, got.err)
	}
	if after := snapshot(t, f.dir); after != before {
		t.Fatalf("the tree changed:\nbefore %s\nafter  %s", before, after)
	}
}

// snapshot is every path under dir with its size and mode, .git included (an index refresh would show).
func snapshot(t *testing.T, dir string) string {
	t.Helper()
	var b strings.Builder
	err := filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		fmt.Fprintf(&b, "%s %d %v %d\n", p, fi.Size(), fi.Mode(), fi.ModTime().UnixNano())
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return b.String()
}

func TestSplitNULSortsAndDeduplicates(t *testing.T) {
	// git lists a path of a merge conflict once per stage, and nothing promises the order across the two lists.
	got := splitNUL("b\x00a\x00b\x00\x00c\x00")
	if strings.Join(got, ",") != "a,b,c" {
		t.Fatalf("%q", got)
	}
	if got := splitNUL(""); len(got) != 0 {
		t.Fatalf("%q", got)
	}
}
