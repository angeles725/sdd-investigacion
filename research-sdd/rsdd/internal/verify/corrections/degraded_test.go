package corrections

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Operational failures are never a verdict (CLAUDE.md section 7): a file or directory the command could not read
// is the typed `degraded:` line on stderr and exit 1, never a quiet "no backlink" or "no block files".

type fsFail struct {
	read    func(p string, n int) error // called with the 1-based count of reads of p
	readDir func(dir string) error      // an error to return after the real entries
}

// runFailing runs the command in-process over dir with injected read and directory-listing failures.
func runFailing(dir string, f fsFail) observed {
	var out, errb strings.Builder
	counts := map[string]int{}
	code := runFS([]string{dir}, stdio(&out, &errb), func(p string) ([]byte, error) {
		counts[p]++
		if f.read != nil {
			if err := f.read(p, counts[p]); err != nil {
				return nil, err
			}
		}
		return readFile(p)
	}, func(d string) ([]os.DirEntry, error) {
		ents, err := os.ReadDir(d)
		if err == nil && f.readDir != nil {
			err = f.readDir(d)
		}
		return ents, err
	})
	return observed{out.String(), errb.String(), code}
}

var errBoom = errors.New("boom")

func TestDegradedTargetBlock(t *testing.T) {
	d := corpus(t, files("t-block1.md", plain(1), "t-block2.md", "> Corrects [Block 1].\n"))
	o := runFailing(d, fsFail{read: func(p string, n int) error {
		if strings.HasSuffix(p, "t-block1.md") && n == 2 { // the first read is the block loop's, the second the target lookup
			return errBoom
		}
		return nil
	}})
	want := "verify-corrections: degraded: cannot read target block t-block1.md: boom; the corpus was NOT checked\n"
	if o.code != 1 || o.stderr != want || strings.Contains(o.stdout, "FAIL") || strings.Contains(o.stdout, "== exit") || strings.Contains(o.stdout, "AMBIG") {
		t.Errorf("%+v", o)
	}
}

func TestDegradedExtractorPositions(t *testing.T) {
	three := files("t-block1.md", plain(1), "t-block2.md", plain(2), "t-block3.md", plain(3))
	for _, c := range []struct {
		name, victim string
		m            map[string]string
	}{
		{"single", "t-block1.md", files("t-block1.md", "> Corrects [Block 9].\n")},
		{"first", "t-block1.md", three},
		{"last", "t-block3.md", three},
	} {
		t.Run(c.name, func(t *testing.T) {
			o := runFailing(corpus(t, c.m), fsFail{read: func(p string, n int) error {
				if strings.HasSuffix(p, c.victim) {
					return errBoom
				}
				return nil
			}})
			want := "verify-corrections: degraded: extractor (awk) failed on " + c.victim + ": boom; the corpus was NOT checked\n"
			if o.code != 1 || o.stderr != want || strings.Contains(o.stdout, "ok ") || strings.Contains(o.stdout, "== exit") {
				t.Errorf("%+v", o)
			}
		})
	}
}

func TestDegradedFocusesFile(t *testing.T) {
	d := corpus(t, files("t-block1.md", plain(1), "sub/FOCUSES.md", "| `a` | x | y | `hb-blockN.md` | q |\n"))
	o := runFailing(d, fsFail{read: func(p string, n int) error {
		if strings.HasSuffix(p, "FOCUSES.md") {
			return errBoom
		}
		return nil
	}})
	want := "verify-corrections: degraded: cannot read focus map sub/FOCUSES.md: boom; the corpus was NOT checked\n"
	if o.code != 1 || o.stderr != want || o.stdout != "" {
		t.Errorf("%+v", o)
	}
}

func TestDegradedDirectoryWalk(t *testing.T) {
	subFails := func(dir string) error {
		if strings.HasSuffix(dir, "/sub") {
			return errBoom
		}
		return nil
	}
	t.Run("an unreadable subdirectory is not 'no block files'", func(t *testing.T) {
		d := corpus(t, files("sub/", ""))
		o := runFailing(d, fsFail{readDir: subFails})
		want := "verify-corrections: degraded: cannot read directory " + d + "/sub: boom; the corpus was NOT checked\n"
		if o.code != 1 || o.stderr != want || o.stdout != "" {
			t.Errorf("%+v", o)
		}
	})
	t.Run("an unreadable target root", func(t *testing.T) {
		d := corpus(t, files("t-block1.md", plain(1)))
		o := runFailing(d, fsFail{readDir: func(dir string) error { return errBoom }})
		if o.code != 1 || !strings.HasPrefix(o.stderr, "verify-corrections: degraded: cannot read directory "+d+": boom;") {
			t.Errorf("%+v", o)
		}
	})
	t.Run("a partial corpus is degraded even when other blocks exist", func(t *testing.T) {
		d := corpus(t, files("t-block1.md", plain(1), "sub/", ""))
		o := runFailing(d, fsFail{readDir: subFails})
		if o.code != 1 || strings.Contains(o.stdout, "ok ") {
			t.Errorf("%+v", o)
		}
	})
	t.Run("the entries returned before the error are kept", func(t *testing.T) {
		d := corpus(t, files("sub/a-block1.md", plain(1), "sub/a-block2.md", plain(2), "top-block3.md", plain(3)))
		got, errs := findFiles(d, isBlockCandidate, func(dir string) ([]os.DirEntry, error) {
			ents, err := os.ReadDir(dir)
			if err == nil {
				err = subFails(dir)
			}
			return ents, err
		})
		if len(got) != 3 || len(errs) != 1 || !strings.HasSuffix(errs[0].path, "/sub") || !errors.Is(errs[0].err, errBoom) {
			t.Errorf("files %v errs %v", got, errs)
		}
	})
}

func TestSymlinkedTargetIsFollowed(t *testing.T) {
	// Intended difference from the script: `find <symlink>` did not descend into a symlinked root and the script
	// exited 2 'no block files'; the Go port follows it, as `ls`, `cd` and every other caller of the path do.
	real := corpus(t, files("t-block1.md", "corrected in B2\n", "t-block2.md", "> Corrects [Block 1].\n"))
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	o := runGo(link)
	if o.code != 0 || !strings.Contains(o.stdout, "ok ") || o.stderr != "" {
		t.Errorf("%+v", o)
	}
}
