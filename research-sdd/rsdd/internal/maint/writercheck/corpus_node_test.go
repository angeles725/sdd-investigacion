//go:build !nodiff

package writercheck

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// TestClassifyAgreesWithParseRedEvidence runs the CI classifier (.github/scripts/parse-red-evidence.cjs) over the same
// list and compares it with this one, path by path.
// It spawns node, an oracle: kept out of the nodiff (teeth) build, where node also cannot start under ulimit -v.
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
