//go:build !nodiff

package gate

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The differential test of the merge-train port: every scenario of mtScenarios (the whole bash suite plus the
// cases the port added) runs against the frozen original (testdata/legacy/mergetrain: kit-merge-train.sh and the
// kit-gate.sh / kit-wait-merge.sh / kit-maint-common.sh it calls, frozen with it so a later port of those tools
// cannot move the oracle) and against runMergeTrain, each in a fresh world built identically, and the two must
// agree on the exit code, stdout, stderr, the ordered gh / gate / merge call log, the receipt, and what is left
// behind (remote heads, train branches, worktrees, refs/train, state files).
//
// Both worlds are deterministic (fixed git dates and identities), so even the shas in the log and the receipt match.
// The merge gate is the same stub script on both sides: the bash reaches it through KIT_MERGE_GATE, the port
// through its in-process hook (mtDeps.mergeGate).
//
// Not compared, by design (each is a declared divergence of RunMergeTrain, see its doc comment):
//   - the shell's `Terminated` job report on the bash side of the SIGTERM scenario;
//   - the `DEGRADED: <why>` line the rsdd process contract adds on stderr for an exit 3;
//   - the run stamp's pid and the case directory, which are normalised.
var mtDegradedLine = regexp.MustCompile(`(?m)^DEGRADED: .*\n?`)

func mtLegacyDir(t *testing.T) string {
	t.Helper()
	stage := t.TempDir()
	for _, f := range []string{"kit-merge-train.sh", "kit-gate.sh", "kit-wait-merge.sh", "kit-maint-common.sh"} {
		b, err := os.ReadFile(filepath.Join("testdata", "legacy", "mergetrain", f))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(stage, f), b, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return stage
}

// runBash runs the frozen script in the world c exactly as the old suite did.
func (c *mtCase) runBash(stage string, r mtRun) mtResult {
	c.env = append(c.env, r.env...)
	argv := []string{"bash", stage + "/kit-merge-train.sh"}
	if r.wrapTO {
		argv = append([]string{"timeout", "--preserve-status", "-s", "TERM", "4"}, argv...)
	}
	cmd := exec.Command(argv[0], append(argv[1:], r.args(c)...)...)
	cmd.Dir, cmd.Env = c.dir, c.env
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			c.t.Fatalf("cannot run the frozen script: %v", err)
		}
		rc = ee.ExitCode()
	}
	return c.collect(rc, out.String(), errb.String())
}

func TestMergeTrainDifferential(t *testing.T) {
	t.Parallel()
	if testing.Short() {
		t.Skip("builds git repositories and runs processes")
	}
	stage := mtLegacyDir(t)
	for _, sc := range mtScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()
			cb := newMtCase(t)
			legacy := cb.runBash(stage, sc.setup(cb))
			cg := newMtCase(t)
			port := cg.runGo(sc.setup(cg), nil)
			port.err = mtDegradedLine.ReplaceAllString(port.err, "")
			if sc.name == "term" { // the shell's own "Terminated" job report of the killed kit-gate.sh
				legacy.err = strings.ReplaceAll(legacy.err, "Terminated\n", "")
			}
			if legacy != port {
				t.Fatalf("legacy and Go differ\n--- legacy rc=%d\nout=%q\nerr=%q\ncalls=%q\nreceipt=%q\npost=%q\n--- go rc=%d\nout=%q\nerr=%q\ncalls=%q\nreceipt=%q\npost=%q",
					legacy.rc, legacy.out, legacy.err, legacy.calls, legacy.receipt, legacy.post,
					port.rc, port.out, port.err, port.calls, port.receipt, port.post)
			}
			if strings.TrimSpace(legacy.out) == "" && sc.rc != 0 {
				t.Fatalf("the oracle printed nothing for a rc %d scenario: the comparison would prove nothing", sc.rc)
			}
		})
	}
}
