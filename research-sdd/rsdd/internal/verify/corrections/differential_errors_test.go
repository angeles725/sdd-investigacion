//go:build !nodiff && unix

package corrections

import (
	"os"
	"path/filepath"
	"testing"
)

// generatedSeeds is the ONE seed list of the generated differential: TestDifferentialGenerated compares seeds
// 1..generatedSeeds against the oracle and TestGeneratorExercisesEveryOutcome requires those same seeds to produce
// every report line kind. A single const, with no -short reduction, so the guard always proves what the
// differential ran.
const generatedSeeds = 40

// TestDifferentialErrorPaths compares the argument and filesystem error paths against the oracle: stdout, stderr
// and exit code.
func TestDifferentialErrorPaths(t *testing.T) {
	good := corpus(t, files("t-block1.md", plain(1), "t-block2.md", "> Corrects [Block 1].\n"))
	noBlocks := corpus(t, files("notes.md", "# not a block\n"))
	asFile := filepath.Join(good, "t-block1.md")
	t.Run("no argument", func(t *testing.T) { assertSameArgs(t, "") })
	t.Run("empty argument", func(t *testing.T) { assertSameArgs(t, "", "") })
	t.Run("missing directory", func(t *testing.T) { assertSameArgs(t, "", filepath.Join(good, "missing")) })
	t.Run("a file as the target", func(t *testing.T) { assertSameArgs(t, "", asFile) })
	t.Run("no block files", func(t *testing.T) { assertSameArgs(t, "", noBlocks) })
	t.Run("trailing slash", func(t *testing.T) { assertSameArgs(t, "", good+"/") })
	t.Run("extra arguments are ignored", func(t *testing.T) { assertSameArgs(t, "", good, "ignored", "also") })
	t.Run("relative target", func(t *testing.T) {
		parent := t.TempDir()
		if err := os.Rename(good, filepath.Join(parent, "sub")); err != nil {
			t.Fatal(err)
		}
		t.Chdir(parent)
		assertSameArgs(t, parent, "sub")
		assertSameArgs(t, parent, "./sub/")
	})
}

// TestDifferentialEdgeCases runs every boundary text of extract_edges_test.go through the frozen script as well.
func TestDifferentialEdgeCases(t *testing.T) {
	t.Parallel()
	for _, c := range edgeCases {
		t.Run(c.name, func(t *testing.T) {
			m := files("t-block100.md", c.text)
			for _, n := range []int{1, 2, 3, 4, 5, 8, 9, 32, 402} {
				m[blk("t", n)] = plain(n)
			}
			assertSame(t, c.name, corpus(t, m))
		})
	}
}

// assertSameArgs runs the oracle (in cwd when not empty) and the Go command with the same arguments.
func assertSameArgs(t *testing.T, cwd string, args ...string) {
	t.Helper()
	want := runLegacyArgs(t, cwd, args...)
	got := runGo(args...)
	if !got.same(want) {
		t.Errorf("args %q: Go differs from the legacy script (exit legacy %d, go %d)\n%s%s", args, want.code, got.code,
			lineDiff("stdout", want.stdout, got.stdout), lineDiff("stderr", want.stderr, got.stderr))
	}
}
