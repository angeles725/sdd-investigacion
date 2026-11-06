package consumers

import (
	"fmt"
	"strings"
	"testing"
)

const (
	rowScripts = "scripts"
	rowTests   = "bash tests"
	rowDocs    = "doctrine and registries"
	rowCI      = "CI workflows"
	rowTempl   = "templates"
	rowHarness = "harness wiring"
	rowLists   = "lists"
	rowUncl    = "unclassified"
)

// row is the cells of one class row with the spacing folded: "2 1 1 1 none".
func row(out, class string) string {
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, class+" ") {
			return strings.Join(strings.Fields(strings.TrimPrefix(l, class)), " ")
		}
	}
	return "<no row " + class + ">"
}

// kit is a fixture with the live script a.sh (it names nothing) and the given extra files, each naming a.sh.
func kit(t *testing.T, extra ...string) *fixture {
	t.Helper()
	f := newFixture(t)
	f.write("research-sdd/toolbelt/a.sh", "x\n")
	for _, p := range extra {
		f.write(p, "run a.sh\n")
	}
	f.commit()
	return f
}

const emptyScripts = "1 no-match no-match no-match none"

func TestEachClassRuleAndTheirOrder(t *testing.T) {
	const hit = "1 1 1 1 none"
	cases := []struct {
		path  string
		class string // a row, or "" when the file is not read
		want  string // the row after the run
		skip  string // the "not read" counts when the file is not read
	}{
		{".github/workflows/ci.yml", rowCI, hit, ""},
		{".github/x.test.yml", rowCI, hit, ""},
		{".github/fixtures/ci.yml", "", "", "fixtures 1, Go module 0"},
		{".claude/settings.json", rowHarness, hit, ""},
		{"research-sdd/install/pi/ext.ts", rowHarness, hit, ""},
		{"research-sdd/install/pix/a.md", rowDocs, hit, ""},
		{"research-sdd/templates/t.md", rowTempl, hit, ""},
		{"research-sdd/templates/t.test.sh", rowTempl, hit, ""},
		{"research-sdd/templates/t.sh", rowTempl, hit, ""},
		{"research-sdd/templates/fixtures/q.md", "", "", "fixtures 1, Go module 0"},
		{"research-sdd/toolbelt/tests/x.test.sh", rowTests, hit, ""},
		{"docs/y.test.md", rowTests, hit, ""},
		{"research-sdd/toolbelt/b.sh", rowScripts, "2 1 1 1 none", ""},
		{"docs/z.md", rowDocs, hit, ""},
		{"research-sdd/toolbelt/m.txt.md", rowDocs, hit, ""},
		{"research-sdd/rsdd.md", rowDocs, hit, ""},
		{"research-sdd/toolbelt/l.txt", rowLists, hit, ""},
		{"other/l.txt", rowUncl, hit, ""},
		{"README", rowUncl, hit, ""},
		{"sub/.github/w.yml", rowUncl, hit, ""},
		{"sub/.claude/s.json", rowUncl, hit, ""},
		{"research-sdd/rsdd/internal/x.md", "", "", "fixtures 0, Go module 1"},
		{"research-sdd/rsdd/internal/testdata/fixtures/f", "", "", "fixtures 0, Go module 1"},
		{"research-sdd/toolbelt/fixtures/x.md", "", "", "fixtures 1, Go module 0"},
	}
	for _, c := range cases {
		t.Run(c.path, func(t *testing.T) {
			got := kit(t, c.path).run()
			if got.rc != 0 || got.err != "" {
				t.Fatalf("rc %d, err %q", got.rc, got.err)
			}
			if c.class == "" {
				want := fmt.Sprintf("not read: %s, binary 0, not regular 0 (read 1 of 2 listed)", c.skip)
				if l := line(got.out, "not read: "); l != want {
					t.Fatalf("%q, want %q", l, want)
				}
				if r := row(got.out, rowScripts); r != emptyScripts {
					t.Fatalf("a file that is not read changed the scripts row: %q", r)
				}
				return
			}
			if r := row(got.out, c.class); r != c.want {
				t.Fatalf("row %q = %q, want %q", c.class, r, c.want)
			}
		})
	}
}

func TestClassifiedFileIsSeenWhereverItSitsInTheList(t *testing.T) {
	fillers := []string{"1.dat", "5.dat", "9.dat"}
	for _, c := range []struct{ name, doc string }{{"first", "0.md"}, {"middle", "6.md"}, {"last", "~.md"}} {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t)
			f.write("research-sdd/toolbelt/a.sh", "x\n")
			for _, p := range fillers {
				f.write(p, "nothing\n")
			}
			f.write(c.doc, "a.sh\n")
			f.commit()
			got := f.run()
			if r := row(got.out, rowDocs); r != "1 1 1 1 none" {
				t.Fatalf("doctrine row %q", r)
			}
			if r := row(got.out, rowUncl); r != "3 no-match no-match no-match none" {
				t.Fatalf("unclassified row %q", r)
			}
		})
	}
	t.Run("only file", func(t *testing.T) {
		got := kit(t, "docs/only.md").run()
		if r := row(got.out, rowDocs); r != "1 1 1 1 none" {
			t.Fatalf("%q", r)
		}
	})
}

func TestUnclassifiedFilesWithAReferenceAreListed(t *testing.T) {
	f := kit(t, "z/notes", "b/notes", "c.dat")
	f.write("quiet.dat", "nothing\n")
	got := f.run()
	const want = "unclassified files with a reference:\n  b/notes 1\n  c.dat 1\n  z/notes 1\nnot read: "
	if !strings.Contains(got.out, want) {
		t.Fatalf("%s", got.out)
	}
}

func TestUnclassifiedListSaysWhyItIsEmpty(t *testing.T) {
	if l := line(kit(t).run().out, "unclassified files with a reference:"); l != "unclassified files with a reference: no files" {
		t.Fatalf("no unclassified file: %q", l)
	}
	f := kit(t)
	f.write("quiet.dat", "nothing\n")
	if l := line(f.run().out, "unclassified files with a reference:"); l != "unclassified files with a reference: no-match" {
		t.Fatalf("unclassified files, no reference: %q", l)
	}
}
