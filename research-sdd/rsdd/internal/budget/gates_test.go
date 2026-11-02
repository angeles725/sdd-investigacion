package budget

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestGateProbe is the child side of TestHarnessGates: it runs only when BUDGET_GATE_PROBE names a gate.
func TestGateProbe(t *testing.T) {
	switch os.Getenv("BUDGET_GATE_PROBE") {
	case "bwrap":
		needBwrap(t)
	case "ts":
		needTS(t)
	default:
		t.Skip("probe child only")
	}
	t.Log("gate passed")
}

// TestHarnessGates pins the old suite's cases 42, 43, 80 and 81: with no usable bwrap (or no node type stripping)
// a sandbox case SKIPs and says so, and RSDD_REQUIRE_BWRAP=1 / RSDD_REQUIRE_NODE_TS=1 turn that skip into a FAIL.
// The child runs with an empty PATH, so neither tool can be found.
func TestHarnessGates(t *testing.T) {
	cases := []struct {
		probe, require string
		wantFail       bool
		want           string
	}{
		{"bwrap", "", false, "no usable bwrap: sandbox-dependent case skipped, not passed"},
		{"bwrap", "RSDD_REQUIRE_BWRAP=1", true, "RSDD_REQUIRE_BWRAP=1 but there is no usable unprivileged bwrap"},
		{"ts", "", false, "node has no built-in TypeScript type stripping: pi case skipped, not passed"},
		{"ts", "RSDD_REQUIRE_NODE_TS=1", true, "RSDD_REQUIRE_NODE_TS=1 but this node has no built-in TypeScript type stripping"},
	}
	for _, c := range cases {
		t.Run(c.probe+"/"+map[bool]string{false: "skip", true: "require"}[c.wantFail], func(t *testing.T) {
			cmd := exec.Command(os.Args[0], "-test.run=^TestGateProbe$", "-test.v")
			cmd.Env = []string{"PATH=" + t.TempDir(), "HOME=" + t.TempDir(), "BUDGET_GATE_PROBE=" + c.probe}
			if c.require != "" {
				cmd.Env = append(cmd.Env, c.require)
			}
			out, err := cmd.CombinedOutput()
			s := string(out)
			if failed := err != nil; failed != c.wantFail {
				t.Fatalf("child failed=%v, want %v; output:\n%s", failed, c.wantFail, s)
			}
			if !strings.Contains(s, c.want) {
				t.Fatalf("child output lacks %q:\n%s", c.want, s)
			}
			if !c.wantFail && (!strings.Contains(s, "--- SKIP: TestGateProbe") || strings.Contains(s, "gate passed")) {
				t.Fatalf("child must SKIP, never pass:\n%s", s)
			}
		})
	}
}
