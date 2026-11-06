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

// The bash cases below sabotage a sourced lib in a copy of the kit (lib/gh-visibility.sh, lib/hook-wiring.sh,
// lib/blocked-rows.sh). The port compiles those libs in, so the failure mode does not exist. No numbered divergence
// of tool-registry.d/research-sdd-status.md covers them, so they stay as the legacy expectation and are skipped until
// s1 decides (delete as retired behaviour, or keep as a shim-level test). Go's behaviour for the same world is the
// ordinary run (the lib cannot be missing).
func TestS8aUndocumentedDivergences(t *testing.T) {
	for _, c := range []struct{ id, legacy, goOut string }{
		{"visibility-13a lib/gh-visibility.sh missing + repo with NO remote", "silent: no degraded line, no reason-codes footer", "silent (same), the lib is compiled in"},
		{"visibility-13b lib/gh-visibility.sh missing + no .git", "silent", "silent (same)"},
		{"visibility-13c lib/gh-visibility.sh missing + a remote", "`degraded: remote-visibility: lib/gh-visibility.sh unavailable` + one reason-codes footer", "the probe runs normally (PUBLIC remote: `WARN public-remote: ...`)"},
		{"main-7329 T-1150-2a lib/hook-wiring.sh absent", "exit 1, `cannot find helper`, no report", "the report runs; Stop hook line from the compiled-in core/hookwiring"},
		{"main-7333 T-1150-2b lib defines no hook_stop_wiring_state", "exit 1, `failed to define`, no report", "the report runs (no sourced function to be missing)"},
		{"blocked-rows-262-missing lib/blocked-rows.sh missing", "exit 1 + a typed message naming blocked-rows", "the report runs; blocked rows are read in process"},
		{"blocked-rows-262-empty lib/blocked-rows.sh empty", "exit 1 + a typed message naming blocked-rows", "the report runs; blocked rows are read in process"},
	} {
		t.Run(c.id, func(t *testing.T) {
			t.Skipf("undocumented divergence: %s, pending s1 decision (legacy: %s; port: %s)", c.id, c.legacy, c.goOut)
		})
	}
}
