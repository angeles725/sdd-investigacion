package cleancheck

import (
	"os"
	"strings"
	"testing"
)

// hasPrefix reports whether any line of the merged output starts with the prefix.
func hasPrefix(r Result, prefix string) bool {
	for _, l := range r.Lines {
		if strings.HasPrefix(l.Text, prefix) {
			return true
		}
	}
	return false
}

// lock makes dir unreadable for the test and restores it afterwards; the case is skipped for root.
func lock(t *testing.T, dir string) {
	t.Helper()
	if os.Getuid() == 0 {
		t.Skip("a permission case needs a non-root user")
	}
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
}

// The stale-tmp scan lists the tmp directory itself (the script ran find on it): a directory that cannot be listed is
// a refused run with the walker's diagnostic, never a quiet clean.
func TestStaleTmpListingFailureRefuses(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	lock(t, w.tmp)
	r := w.check()
	if r.Exit != 2 || r.Verdict != Refused || r.Summary != "" {
		t.Fatal(w.dump(r))
	}
	if !has(r, "clean-check: ERROR: find failed or was truncated in "+w.tmp) {
		t.Error("the refusal line is missing:\n" + w.dump(r))
	}
	if got := r.Stderr(); !strings.Contains(got, "find: '"+w.tmp+"': Permission denied") {
		t.Errorf("the walker's diagnostic was not surfaced on stderr: %q", got)
	}
	if hasPrefix(r, "GARBAGE") || hasPrefix(r, "CLEAN-CHECK:") {
		t.Error("nothing may be claimed about a tmp directory that was not read:\n" + w.dump(r))
	}
}

// A sources/probes tree that cannot be walked is one refused run (the script had two walks and two messages): neither
// the UNMANIFESTED-SCRIPT nor the preserved-copy verdict of any scratchpad file is given, and no summary is printed.
func TestFailedProbesWalkRefusesAndEvaluatesNothing(t *testing.T) {
	w := newWorld(t)
	keep(w, "sources/\n")
	w.write("sources/probes/locked/f", "x")
	w.writeAt(w.scratch+"/a.sh", "x")
	w.writeAt(w.scratch+"/b.log", "x")
	w.write("notes/b.md", "see b.log and a.sh\n")
	lock(t, w.repo+"/sources/probes/locked")
	r := w.check(func(o *Options) { o.Scratchpad = w.scratch })
	if r.Exit != 2 || r.Verdict != Refused {
		t.Fatal(w.dump(r))
	}
	if !has(r, "clean-check: ERROR: manifest scan failed under "+w.repo+"/sources/probes; UNMANIFESTED-SCRIPT not evaluated") ||
		!has(r, "find: '"+w.repo+"/sources/probes/locked': Permission denied") {
		t.Error(w.dump(r))
	}
	for _, p := range []string{"UNMANIFESTED-SCRIPT", "UNPRESERVED-ARTIFACT", "scratchpad:", "CLEAN-CHECK:"} {
		if hasPrefix(r, p) {
			t.Errorf("%s was reported although the probes were not read:\n%s", p, w.dump(r))
		}
	}
	if r.Summary != "" || r.Findings != 0 {
		t.Errorf("summary %q findings %d", r.Summary, r.Findings)
	}
}

// A permission error under an _evidence directory is not a skippable hole: the discovery degrades (exit 3) with the
// typed line, end to end (TestClassifyDiscovery pins the classification alone).
func TestUnreadableDirUnderEvidenceDegradesTheScan(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	w.writeAt(w.repo+"/_evidence/t/locked/f", "x")
	w.writeAt(w.repo+"/.git/info/exclude", "_evidence/\n")
	lock(t, w.repo+"/_evidence/t/locked")
	r := w.check()
	if r.Exit != 3 || r.Verdict != Degraded || len(r.Degraded) != 1 || r.Degraded[0] != DegradedEvidence {
		t.Fatal(w.dump(r))
	}
	want := "DEGRADED-EVIDENCE-SCAN find for _evidence directories failed under " + w.repo + ": find: '" + w.repo + "/_evidence/t/locked': Permission denied"
	if !has(r, want) {
		t.Errorf("missing %q:\n%s", want, w.dump(r))
	}
	if !hasPrefix(r, "CLEAN-CHECK: degraded") {
		t.Error("the summary must say degraded:\n" + w.dump(r))
	}
}
