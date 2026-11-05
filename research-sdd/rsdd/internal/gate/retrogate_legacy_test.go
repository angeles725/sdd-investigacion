//go:build !nodiff

package gate

import (
	"bytes"
	"os"
	"os/exec"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// rgLegacy is the frozen original retro-gate.sh, sha-pinned by the differential.
const rgLegacy = "testdata/legacy/retro-gate.sh"

func init() {
	rgStageLegacy = stageLegacyRetroGate
	rgRunBash = runLegacyRetroGate
}

// stageLegacyRetroGate copies the frozen original into the world's staged toolbelt.
func stageLegacyRetroGate(w *rgWorld) {
	b, err := os.ReadFile(rgLegacy)
	must(w.t, err)
	execfile.Write(w.t, w.tb+"/retro-gate.sh", string(b))
}

// runLegacyRetroGate runs the frozen original exactly as the old suite did.
func runLegacyRetroGate(w *rgWorld, r rgRun) *rgRes {
	w.t.Helper()
	bash, _ := exec.LookPath("bash")
	cmd := exec.Command(bash, append([]string{w.tb + "/retro-gate.sh"}, r.args...)...)
	cmd.Dir = w.root
	cmd.Env = envList(w.envFor(r))
	cmd.Stdin = strings.NewReader(r.stdin)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			w.t.Fatal(err)
		}
		rc = ee.ExitCode()
	}
	return w.collect(r, out.String(), errb.String(), rc)
}
