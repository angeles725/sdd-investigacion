//go:build linux && !nodiff

package catalog

import (
	"bytes"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"unicode"
)

// Differential tests: the frozen Python generator (testdata/legacy/gen-catalog.py, the bytes of
// templates/gen-catalog.py before the port) and the Go command must produce the same stdout, exit code and CATALOG.md
// from the same input tree, on every replay input and on seeded random corpora. A missing python3 FAILS: a skipped
// differential proves nothing. The random corpora give every block file a distinct number and share one prefix,
// because the order of equal numbers and the subject of mixed prefixes depend on Python's scandir order (declared
// deviation in the package doc).

type outcome struct {
	stdout  []byte
	exit    int
	catalog []byte
	hasCat  bool
}

func runPython(t *testing.T, root string) outcome {
	t.Helper()
	legacy, err := filepath.Abs(filepath.Join("testdata", "legacy", "gen-catalog.py"))
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	cmd := exec.Command("python3", legacy, root)
	cmd.Stdout = &out
	err = cmd.Run()
	var ee *exec.ExitError
	exit := 0
	switch {
	case errors.As(err, &ee):
		exit = ee.ExitCode()
	case err != nil:
		t.Fatalf("python3 is required for the differential test: %v", err)
	}
	return collect(root, out.Bytes(), exit)
}

func runGo(root string) outcome {
	s, out, _ := stdio("/work")
	rc := Run([]string{root}, s)
	return collect(root, out.Bytes(), rc)
}

func collect(root string, stdout []byte, exit int) outcome {
	b, err := os.ReadFile(filepath.Join(root, "CATALOG.md"))
	return outcome{stdout: stdout, exit: exit, catalog: b, hasCat: err == nil}
}

func compare(t *testing.T, label string, build func(dir string)) {
	t.Helper()
	pyDir, goDir := t.TempDir(), t.TempDir()
	build(pyDir)
	build(goDir)
	py, gg := runPython(t, pyDir), runGo(goDir)
	if py.exit != gg.exit || !bytes.Equal(py.stdout, gg.stdout) || py.hasCat != gg.hasCat || !bytes.Equal(py.catalog, gg.catalog) {
		t.Errorf("%s: python and go differ\npython exit=%d stdout=%q catalog(%v)=%q\ngo     exit=%d stdout=%q catalog(%v)=%q",
			label, py.exit, py.stdout, py.hasCat, py.catalog, gg.exit, gg.stdout, gg.hasCat, gg.catalog)
	}
}

func TestParityReplayInputs(t *testing.T) {
	cases, _ := filepath.Glob(filepath.Join("testdata", "replay", "*", "in"))
	if len(cases) == 0 {
		t.Fatal("no replay inputs")
	}
	for _, in := range cases {
		t.Run(filepath.Base(filepath.Dir(in)), func(t *testing.T) {
			compare(t, in, func(dir string) { copyTree(t, in, dir) })
		})
	}
}

var (
	zeroes   = []rune{'0', '٠', '０', '𝟎', '०', '𝟘'}
	suffixes = []string{"", "", "-x", "-é-ñ", "-a_b", "-日本", "-٣", "-1", "--", "-x-y-z", "-A"}
	decoys   = []string{"README.md", "pfx-Block3.md", "blocked-notes.md", "pfx-bloque.md", "pfx-block1-a.b.md", "x.txt", "pfx-block2x.md", "bloque4.md", "pfx-block5-.md", "pfx-BLOQUE6.md"}
	titles   = []string{
		"# Block %d — T%d\n", "# Bloque %d - T%d\r\n", "# Block %d —\n", "# Block %d —  \n", "x\n# Block %d — late T%d\n",
		"# Random %d%d\n", "no heading %d%d\n", "", "\n", "# \n", "# Block %d — ñandú — %d 　\n", "#Block %d — %d\n",
		"# Block %d – %d\n", "intro\r# Block %d — cr %d\r", "# Block %d — %d", "## Block %d — %d\n", "# BLOCK %d — %d\n",
	}
	prefixes = []string{"pfx", "éñ", "a b", "x-y"}
)

// digitsOf renders n with the digit script of zero and a number of leading zeros.
func digitsOf(n int, zero rune, pad int) string {
	var sb strings.Builder
	for i := 0; i < pad; i++ {
		sb.WriteRune(zero)
	}
	for _, c := range fmt.Sprint(n) {
		sb.WriteRune(zero + (c - '0'))
	}
	return sb.String()
}

func TestParityRandomCorpora(t *testing.T) {
	rng := rand.New(rand.NewSource(20261102))
	for i := 0; i < 80; i++ {
		prefix := prefixes[rng.Intn(len(prefixes))]
		count := rng.Intn(9)
		nums := rng.Perm(40)[:count]
		type file struct{ name, body string }
		var files []file
		for _, n := range nums {
			kw := []string{"block", "bloque"}[rng.Intn(2)]
			name := prefix + "-" + kw + digitsOf(n, zeroes[rng.Intn(len(zeroes))], rng.Intn(3)) + suffixes[rng.Intn(len(suffixes))] + ".md"
			f := titles[rng.Intn(len(titles))]
			files = append(files, file{name, fill(f, n)})
		}
		for _, d := range decoys {
			if rng.Intn(3) == 0 {
				files = append(files, file{d, "# Block 1 — decoy\n"})
			}
		}
		if rng.Intn(4) == 0 {
			files = append(files, file{"CATALOG.md", "STALE\n"})
		}
		compare(t, fmt.Sprintf("random corpus %d", i), func(dir string) {
			for _, f := range files {
				if err := os.WriteFile(filepath.Join(dir, f.name), []byte(f.body), 0o644); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

// fill puts n into the %d verbs of a title format.
func fill(format string, n int) string {
	switch strings.Count(format, "%d") {
	case 0:
		return format
	case 1:
		return fmt.Sprintf(format, n)
	}
	return fmt.Sprintf(format, n, n)
}

// All Nd characters: the number a file name encodes must equal Python's int() of it.
func TestParityEveryDecimalDigit(t *testing.T) {
	var runes []rune
	for r := rune(0); r <= 0x1FFFF; r++ {
		if unicode.Is(unicode.Nd, r) {
			runes = append(runes, r)
		}
	}
	if len(runes) < 600 {
		t.Fatalf("only %d Nd runes found", len(runes))
	}
	compare(t, "all digits", func(dir string) {
		for i, r := range runes {
			// one file per digit; the 4-digit position keeps every number distinct: "<digit><iiii>"
			name := fmt.Sprintf("pfx-block%c%04d.md", r, i)
			if err := os.WriteFile(filepath.Join(dir, name), []byte("# Block 1 — d\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	})
}
