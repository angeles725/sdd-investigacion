package writercheck

import "testing"

// TestNameKillCorpus walks EVERY line of the frozen corpus both detectors share (this scan and the PreToolUse hook's
// --strict-name-kill): a `deny` line is a name kill, an `allow` line is not.
func TestNameKillCorpus(t *testing.T) {
	lines := corpusLines()
	if len(lines) < 30 {
		t.Fatalf("the corpus was read as %d lines: a vacuous walk", len(lines))
	}
	deny := 0
	for _, l := range lines {
		want := l[0] == "deny"
		if want {
			deny++
		}
		if l[0] != "deny" && l[0] != "allow" {
			t.Fatalf("corpus verdict %q is neither deny nor allow", l[0])
		}
		if got := isNameKill(l[1], false); got != want {
			t.Errorf("%s: %q: scan says kill=%v", l[0], l[1], got)
		}
	}
	if deny == 0 || deny == len(lines) {
		t.Fatalf("the corpus has %d deny lines of %d: it pins nothing", deny, len(lines))
	}
}

// TestClassifyMatchesProductionList walks every line of the production-path list both classifiers share.
func TestClassifyMatchesProductionList(t *testing.T) {
	lines := productionLines()
	if len(lines) < 30 {
		t.Fatalf("the production list was read as %d lines: a vacuous walk", len(lines))
	}
	for _, l := range lines {
		if got := isProduction(l[1]); got != (l[0] == "production") {
			t.Errorf("%s: production=%v, the list says %s", l[1], got, l[0])
		}
	}
}
