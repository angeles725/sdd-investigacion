package show

import (
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// S8a: bash cases whose subject no longer exists in the port.

// T-IDG-TIMEOUT-ABSENT (main suite 2206, 2211) and T-IDG-ENUM-SORT-FAIL (2474): DOCUMENTED divergences (6) and (7)
// of tool-registry.d/research-sdd-status.md. The script, with `_IDG_TIMEOUT_BIN=""`, printed the `unverified`
// marker and never called reconcile; with a failing `sort` stage it printed the marker. The port bounds every child
// itself (no timeout binary, no hook) and sorts in process (no stage that can fail): the same worlds probe once and
// answer a clean STOP.
func TestS8aDivergences6And7(t *testing.T) {
	t.Run("L2206-IDG-TIMEOUT-ABSENT-divergence-6", func(t *testing.T) {
		probed := 0
		st := gateStubs{rec: func([]string, time.Duration, cli.Stdio) probeResult { probed++; return probeResult{} }}
		o, _ := runStubbed(t, oneRetro, map[string]string{"_IDG_TIMEOUT_BIN": ""}, st)
		if strings.Contains(o.out, "[issue-coverage: unverified") {
			t.Errorf("the port must not print the script's unverified marker: %q", o.out)
		}
		if probed != 1 {
			t.Errorf("reconcile called %d times, the port probes once", probed)
		}
	})
	t.Run("L2474-IDG-ENUM-SORT-FAIL-divergence-7", func(t *testing.T) {
		probed := 0
		st := gateStubs{rec: func([]string, time.Duration, cli.Stdio) probeResult { probed++; return probeResult{} }}
		o, _ := runStubbed(t, oneRetro, nil, st)
		if o.out != stopExhausted+"\n" || probed != 1 || strings.Contains(o.err, "sort") {
			t.Errorf("a retro listing has no sort stage to fail: stdout %q stderr %q probed %d", o.out, o.err, probed)
		}
	})
}
