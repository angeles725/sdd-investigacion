package consumers

import (
	"os"
	"strings"
	"testing"
)

func TestCountsFilesPairsReferencesAndSelf(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{
		"research-sdd/toolbelt/a.sh": "b.sh\n",
		"research-sdd/toolbelt/b.sh": "a.sh a.sh b.sh\n",
		"research-sdd/toolbelt/c.sh": "c.sh\n",
		"research-sdd/toolbelt/d.sh": "nothing\n",
		"docs/one.md":                "a.sh a.sh b.sh\n",
		"docs/two.md":                "b.sh\n",
		"docs/three.md":              "nothing\n",
	})
	f.commit()
	got := f.run()
	// scripts: a names b (1); b names a twice and itself once; c names only itself; d names nothing.
	if r := row(got.out, rowScripts); r != "4 2 2 3 1" {
		t.Fatalf("scripts row %q", r)
	}
	// docs: one names a twice and b once (2 pairs, 3 references); two names b; three nothing.
	if r := row(got.out, rowDocs); r != "3 2 3 4 none" {
		t.Fatalf("doctrine row %q", r)
	}
}

func TestSharedBasenameIsOneNameAndCountedOnce(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{"research-sdd/toolbelt/z.sh": "z.sh\n", "research-sdd/templates/z.sh": "z.sh z.sh\n", "docs/d.md": "z.sh\n"})
	f.commit()
	got := f.run()
	if r := row(got.out, rowDocs); r != "1 1 1 1 none" {
		t.Fatalf("a reference to a shared name is one: %q", r)
	}
	if r := row(got.out, rowScripts); r != "1 no-match no-match no-match 1" {
		t.Fatalf("scripts row %q", r)
	}
	if r := row(got.out, rowTempl); r != "1 no-match no-match no-match 1" {
		t.Fatalf("templates row %q", r)
	}
}

func TestBinaryBoundary(t *testing.T) {
	cases := []struct {
		name    string
		nul     int // index of the NUL byte
		counted bool
	}{{"NUL at the first byte", 0, false}, {"NUL at byte 8191", 8191, false}, {"NUL at byte 8192", 8192, true}}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := kit(t)
			b := []byte(strings.Repeat("a", 8200))
			copy(b[c.nul+1:], " a.sh ")
			b[c.nul] = 0
			f.writeBytes("docs/blob.md", b)
			got := f.run()
			wantRow, wantBin := "1 1 1 1 none", "binary 0"
			if !c.counted {
				wantRow, wantBin = "none read n/a n/a n/a n/a", "binary 1"
			}
			if r := row(got.out, rowDocs); r != wantRow {
				t.Fatalf("row %q, want %q", r, wantRow)
			}
			if l := line(got.out, "not read: "); !strings.Contains(l, wantBin+", not regular 0") {
				t.Fatalf("%q", l)
			}
		})
	}
}

func TestUnreadableFileIsAnErrorNeverAZero(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every file")
	}
	f := kit(t, "docs/secret.md", "docs/ok.md")
	if err := os.Chmod(f.dir+"/docs/secret.md", 0); err != nil {
		t.Fatal(err)
	}
	got := f.run()
	if got.rc != 1 || got.out != "" || !strings.HasPrefix(got.err, "consumers: error: cannot read docs/secret.md: ") || !strings.HasSuffix(got.err, "permission denied\n") {
		t.Fatalf("got %+v", got)
	}
}

func TestListedButMissingFileIsAnError(t *testing.T) {
	f := kit(t, "docs/gone.md")
	if err := os.Remove(f.dir + "/docs/gone.md"); err != nil {
		t.Fatal(err)
	}
	got := f.run()
	if got.rc != 1 || got.out != "" || !strings.HasPrefix(got.err, "consumers: error: cannot read docs/gone.md: ") {
		t.Fatalf("got %+v", got)
	}
}

func TestNotRegularFileIsCountedNotRead(t *testing.T) {
	f := kit(t)
	if err := os.Symlink("a.sh", f.dir+"/docs-link.md"); err != nil {
		t.Skip("no symlinks")
	}
	f.git("add", "-A")
	got := f.run()
	if l := line(got.out, "not read: "); got.rc != 0 || l != "not read: fixtures 0, Go module 0, binary 0, not regular 1 (read 1 of 2 listed)" {
		t.Fatalf("rc %d, %q", got.rc, l)
	}
}

func TestReportIsDeterministic(t *testing.T) {
	f := kit(t, "docs/a.md", "docs/b.md", "z/c.dat", "y/c.dat", ".github/w.yml")
	first := f.run()
	for i := 0; i < 20; i++ {
		if again := f.run(); again != first {
			t.Fatalf("run %d differs", i)
		}
	}
}
