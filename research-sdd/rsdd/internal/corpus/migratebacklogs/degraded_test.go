package migratebacklogs

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path"
	"strings"
	"testing"
)

// The operational failures of the command, reached through Options.FS (no file permissions, no root checks).

var errBoom = errors.New("boom")

// brokenFS serves a real tree but fails to open the listed paths: a directory in dirs fails to list, a file in
// files fails to read.
type brokenFS struct {
	fs.FS
	dirs, files map[string]bool
}

func (b brokenFS) Open(name string) (fs.File, error) {
	if b.dirs[name] || b.files[name] {
		return nil, &fs.PathError{Op: "open", Path: name, Err: errBoom}
	}
	return b.FS.Open(name)
}

func runBroken(t *testing.T, c dcase, dirs, files []string) (rc int, stdout, stderr string) {
	t.Helper()
	root, corpus := c.layout(t)
	b := brokenFS{FS: os.DirFS(corpus), dirs: map[string]bool{}, files: map[string]bool{}}
	for _, d := range dirs {
		b.dirs[d] = true
	}
	for _, f := range files {
		b.files[f] = true
	}
	before := treeFingerprint(t, root)
	var so, se bytes.Buffer
	rc = Run(Options{Args: []string{corpus}, Out: &so, Err: &se, FS: b})
	if treeFingerprint(t, root) != before {
		t.Error("the run changed the corpus tree")
	}
	return rc, normalize(root, so.String()), normalize(root, se.String())
}

func TestUnlistableCorpusIsDegradedNotAbsent(t *testing.T) {
	t.Parallel()
	rc, so, se := runBroken(t, one("x", "# R\n"), []string{"."}, nil)
	if rc != 1 || so != "" {
		t.Errorf("rc=%d stdout=%q", rc, so)
	}
	want := "degraded: migrate-backlogs: @T@/corpus is not readable/traversable (open .: boom) — cannot scan\n"
	if se != want {
		t.Errorf("stderr %q, want %q", se, want)
	}
}

func TestUnlistableSubdirectoryIsDegradedNotAbsent(t *testing.T) {
	t.Parallel()
	c := dcase{files: map[string]string{"RESEARCH-STATE-a.md": "# R\n", "sub/x.md": "x\n"}}
	rc, so, se := runBroken(t, c, []string{"sub"}, nil)
	if rc != 1 || so != "" {
		t.Errorf("rc=%d stdout=%q: nothing may be reported before the scan is complete", rc, so)
	}
	want := "degraded: migrate-backlogs: scanning @T@/corpus failed (open sub: boom) — cannot tell absent from unreadable\n"
	if se != want {
		t.Errorf("stderr %q, want %q", se, want)
	}
}

// The directory below the search depth is never listed, so a failure there is not a failure of the run.
func TestDirectoryBelowTheSearchDepthIsNotListed(t *testing.T) {
	t.Parallel()
	c := dcase{files: map[string]string{"RESEARCH-STATE-a.md": "# R\n", "a/b/c/x.md": "x\n"}}
	rc, _, se := runBroken(t, c, []string{"a/b/c"}, nil)
	if rc != 0 || se != "" {
		t.Errorf("rc=%d stderr=%q", rc, se)
	}
}

// An unreadable state file stops the run where it is: what was printed before stays, nothing after it is, and
// there is no closing line (a summary would claim a complete run).
func TestUnreadableStateFileStopsTheRun(t *testing.T) {
	t.Parallel()
	c := dcase{files: map[string]string{
		"RESEARCH-STATE-a.md": state("## Gap-backlog", brow("high", "pending")),
		"RESEARCH-STATE-b.md": "# R\n", "RESEARCH-STATE-c.md": "# R\n",
	}}
	rc, so, se := runBroken(t, c, nil, []string{"RESEARCH-STATE-b.md"})
	if rc != 1 || so != "ok a: nothing to migrate\n" {
		t.Errorf("rc=%d stdout=%q", rc, so)
	}
	if want := "degraded: migrate-backlogs: cannot read @T@/corpus/RESEARCH-STATE-b.md — proposal not computed\n"; se != want {
		t.Errorf("stderr %q, want %q", se, want)
	}
}

// An unreadable FOCUSES.md does not make its state files documents: they get their proposal, and the FOCUSES pass
// is the one that fails.
func TestUnreadableFocusesIsNotADocumentRegistry(t *testing.T) {
	t.Parallel()
	c := dcase{files: map[string]string{"RESEARCH-STATE-d.md": "# R\n\nno backlog\n", "FOCUSES.md": focusesTable("| d | document | RESEARCH-STATE-d.md |")}}
	rc, so, se := runBroken(t, c, nil, []string{"FOCUSES.md"})
	if rc != 1 || !strings.Contains(so, "MANUAL d empty-backlog-skeleton rows=1 first-line=0\n") || strings.Contains(so, "migrate-backlogs:") {
		t.Errorf("rc=%d stdout=%q", rc, so)
	}
	if want := "degraded: migrate-backlogs: cannot read @T@/corpus/FOCUSES.md — proposal not computed\n"; se != want {
		t.Errorf("stderr %q, want %q", se, want)
	}
}

// The path in the degraded line is the target as given joined to the relative name, with no doubled slash.
func TestDegradedPathJoinsTheTargetOnce(t *testing.T) {
	t.Parallel()
	c := dcase{files: map[string]string{"s/RESEARCH-STATE-a.md": "# R\n"}}
	root, corpus := c.layout(t)
	var so, se bytes.Buffer
	rc := Run(Options{Args: []string{corpus + "///"}, Out: &so, Err: &se, FS: brokenFS{FS: os.DirFS(corpus), files: map[string]bool{"s/RESEARCH-STATE-a.md": true}}})
	want := "degraded: migrate-backlogs: cannot read " + path.Join(root, "corpus") + "/s/RESEARCH-STATE-a.md — proposal not computed\n"
	if rc != 1 || se.String() != want {
		t.Errorf("rc=%d stderr %q, want %q", rc, se.String(), want)
	}
}
