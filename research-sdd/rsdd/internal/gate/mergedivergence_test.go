//go:build !nodiff

package gate

import (
	"strings"
	"testing"
)

// TestCISkippedRequiredDiverges names the one declared divergence of the CI gate from the frozen merge-gate.sh:
// a REQUIRED check that concluded skipped or neutral. The legacy jq counted both as green and allowed the merge;
// the port refuses with ci_skipped. Every other CI case stays byte-identical in TestDifferentialAgainstLegacy.
func TestCISkippedRequiredDiverges(t *testing.T) {
	t.Parallel()
	if testing.Short() {
		t.Skip("runs the frozen bash original")
	}
	for _, tool := range []string{"bash", "jq", "git", "awk", "sed", "grep"} {
		if _, err := lookPath(tool); err != nil {
			t.Skipf("%s not on PATH", tool)
		}
	}
	w := newWorld(t)
	w.buildRepos()
	r := &diffRig{w: w}
	p := w.assessFile("false", "passive")
	for _, c := range []struct {
		name, concl, wantGo string
	}{
		{"skipped", "skipped", "ci_skipped (toolbelt-tests)"},
		{"neutral", "neutral", "ci_skipped (toolbelt-tests)"},
	} {
		sc := r.mg("required "+c.name, "repo", p, with(argsMerge, "--no-closure-evidence"),
			"MERGE_GATE_REQUIRED_CHECKS=shellcheck,toolbelt-tests",
			"STUB_CHECKS_JSON="+r.ck("shellcheck:completed:success", "toolbelt-tests:completed:"+c.concl))
		legacy, got := w.runLegacy(sc), w.runGo(sc)
		if legacy.rc != 0 || strings.Contains(legacy.out, "refuse:") {
			t.Errorf("%s: the frozen original no longer allows a required %s check: rc=%d out=%q", c.name, c.concl, legacy.rc, legacy.out)
		}
		if got.rc != 1 || !strings.Contains(got.out, "refuse: "+c.wantGo+" (head=") {
			t.Errorf("%s: the port must refuse with %s: rc=%d out=%q", c.name, c.wantGo, got.rc, got.out)
		}
	}
}
