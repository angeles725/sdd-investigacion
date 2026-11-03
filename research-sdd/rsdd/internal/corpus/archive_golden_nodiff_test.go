//go:build nodiff

package corpus

import "testing"

// TestArchiveGoldens replays every case of the shared table through the Go command only and requires the recorded
// golden (stdout, stderr, exit code, resulting tree) plus the predicates of the retired bash case. It is the nodiff
// stand-in for TestArchiveCases (archive_legacy_test.go), so mutation testing kills without running bash.
func TestArchiveGoldens(t *testing.T) {
	if why := archiveHaveTools(); why != "" {
		t.Skip(why)
	}
	if testing.Short() {
		t.Skip("archive golden cases are slow")
	}
	for _, c := range archiveCases() {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			_, gor, f, target := archiveRunCase(t, c, false)
			archiveCheck(t, "go", c, f, target, gor)
			archiveCheckFiles(t, "go", c, target, f)
			archiveCheckGolden(t, "go", c, gor, f.root)
		})
	}
}
