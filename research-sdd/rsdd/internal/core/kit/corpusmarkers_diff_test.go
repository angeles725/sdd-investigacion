//go:build !nodiff && unix

package kit

import (
	"os/exec"
	"path/filepath"
	"testing"
)

// The real lib/corpus-markers.sh against the Go port, case by case (same predicate, same answer). A missing
// bash skips with a message saying the port is not proven; a missing lib fails.
func TestCorpusMarkersDifferential(t *testing.T) {
	bin, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("differential: bash not found; the Go corpus-marker port is NOT proven against lib/corpus-markers.sh in this run")
	}
	lib, _ := filepath.Abs(filepath.Join(toolbeltRel, "lib", "corpus-markers.sh"))
	root := t.TempDir()
	dirs := []string{filepath.Join(root, "missing")}
	for _, c := range markerCases {
		dirs = append(dirs, buildMarkerCase(t, root, c))
	}
	for _, d := range dirs {
		out, err := exec.Command(bin, "-c", `. "$1" && declare -F corpus_marker_present >/dev/null || exit 97; corpus_marker_present "$2"; echo $?`, "_", lib, d).Output()
		if err != nil {
			t.Fatalf("driver for %s: %v", d, err)
		}
		want := string(out) == "0\n"
		if got := CorpusMarkerPresent(d); got != want {
			t.Errorf("%s: bash=%v go=%v", filepath.Base(d), want, got)
		}
	}
}
