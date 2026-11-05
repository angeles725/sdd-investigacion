package writercheck

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

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

// TestClassifyAgreesWithParseRedEvidence runs the CI classifier (.github/scripts/parse-red-evidence.cjs) over the same
// list and compares it with this one, path by path.
func TestClassifyAgreesWithParseRedEvidence(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not on PATH; parse-red-evidence.test.cjs pins the same list on the JS side")
	}
	cjs := filepath.Join(kitroot.Dir(t), "..", ".github", "scripts", "parse-red-evidence.cjs")
	if _, err := os.Stat(cjs); err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, l := range productionLines() {
		paths = append(paths, l[1])
	}
	script := `const {isProductionPath}=require(process.argv[1]);for(const p of process.argv.slice(2))console.log((isProductionPath(p)?"production ":"other ")+p)`
	out, err := exec.Command(node, append([]string{"-e", script, cjs}, paths...)...).Output()
	if err != nil {
		t.Fatalf("node: %v", err)
	}
	got := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(got) != len(paths) {
		t.Fatalf("node classified %d of %d paths", len(got), len(paths))
	}
	for i, p := range paths {
		kind := "other"
		if isProduction(p) {
			kind = "production"
		}
		if got[i] != kind+" "+p {
			t.Errorf("the CI classifier says %q, this one says %q", got[i], kind+" "+p)
		}
	}
}
