//go:build !nodiff

package grammar

import (
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// TestDifferentialFleet is the read-only fleet pass: every retro of the kit repository's own retros/ and of every
// target registered in the real TARGETS.md that resolves on this machine goes through every file mode on both
// sides. Nothing is written; a machine without any corpus skips loudly. -short skips it (it is the slow pass).
func TestDifferentialFleet(t *testing.T) {
	if testing.Short() {
		t.Skip("-short: the fleet pass did NOT run (NOT a pass)")
	}
	repo, err := filepath.Abs("../../../../..")
	if err != nil {
		t.Fatal(err)
	}
	dirs := []string{filepath.Join(repo, "retros")}
	src, err := kit.ReadTargets(filepath.Join(repo, "research-sdd", "TARGETS.md"))
	if err != nil {
		t.Fatalf("the real registry must exist: %v", err)
	}
	usable, _ := kit.Classify(kit.PathsAll(src, os.Getenv), kit.IsDirOS)
	for _, target := range usable {
		dirs = append(dirs, filepath.Join(target, "retros"))
	}
	seen := map[string]bool{}
	var paths []string
	for _, dir := range dirs {
		matches, _ := filepath.Glob(filepath.Join(dir, "*.md"))
		for _, m := range matches {
			if real, err := filepath.EvalSymlinks(m); err == nil && !seen[real] {
				seen[real] = true
				paths = append(paths, m)
			}
		}
	}
	if len(paths) == 0 {
		t.Skip("no retro corpus resolves on this machine: the fleet pass did NOT run (NOT a pass)")
	}
	sort.Strings(paths)
	checkFileModes(t, "fleet", paths, false)
	markers := map[string]bool{}
	for _, p := range paths {
		if d, err := Read(p); err == nil {
			markerKeywordLines(markers, d.Raw)
		}
	}
	lines := make([]string, 0, len(markers))
	for l := range markers {
		lines = append(lines, l)
	}
	sort.Strings(lines)
	checkLineModes(t, "fleet", lines, false)
	t.Logf("fleet marker lines: %d", len(lines))
	t.Logf("fleet pass: %d retros under %d retros/ directories (%d registered targets resolve)", len(paths), len(dirs), len(usable))
}
