package verify

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The drift check runs in process (kit issue #2645): no toolbelt directory is needed and the checker cannot be
// "not found". The old subprocess tests of those paths are gone with the subprocess.
func TestGapDriftRunsWithoutToolbelt(t *testing.T) {
	d := t.TempDir()
	sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | B1-G1 something wholly different about cats | w | pending |"))
	sdWrite(t, filepath.Join(d, "x-block1.md"), "# b\n\n- **B1-G1** how do the widgets frobnicate the sprockets under load\n")
	got := sdGo(t, d, false, d)
	want := "   WARN   gap-drift: DRIFT? B1-G1 overlap=0% row='something wholly different about cats' — copy the child-gap text verbatim from the block bullet (METHODOLOGY §7)"
	if !strings.Contains(got.Stdout, want) || strings.Contains(got.Stdout, "check-gap-drift.sh not found") {
		t.Errorf("want the in-process DRIFT? WARN without a toolbelt:\n%s", got.Stdout)
	}
}

// TestRelayGapDrift pins how the report treats the check's output and failures (these were the bash mutation
// controls vs-warn-lines, vs-failed-checker, vs-untyped-exit1 and vs-rows-guard of check-gap-drift.test.sh).
func TestRelayGapDrift(t *testing.T) {
	for _, c := range []struct {
		name string
		out  string
		rc   int
		want []string
	}{
		{"exit 2 is a degraded WARN naming the first line", "boom\nmore", 2, []string{"   WARN   gap-drift: degraded — check-gap-drift.sh failed (exit 2): boom"}},
		{"exit 1 with no typed line is degraded", "oops", 1, []string{"   WARN   gap-drift: degraded — check-gap-drift.sh failed (exit 1): oops"}},
		{"exit 1 with a DRIFT? line is a finding", "DRIFT? B1-G1 x\nchecked=1", 1,
			[]string{"   WARN   gap-drift: DRIFT? B1-G1 x — copy the child-gap text verbatim from the block bullet (METHODOLOGY §7)"}},
		{"UNPARSED is relayed as a finding", "UNPARSED B1-G1", 1,
			[]string{"   WARN   gap-drift: UNPARSED B1-G1 — copy the child-gap text verbatim from the block bullet (METHODOLOGY §7)"}},
		{"DEGRADED is relayed", "DEGRADED no words", 0, []string{"   WARN   gap-drift: DEGRADED no words"}},
		{"a clean report prints nothing", "checked=1 suspects=0", 0, nil},
		{"NO-BLOCK alone prints nothing", "NO-BLOCK B1-G1 (x)\nchecked=0", 0, nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			var got []string
			relayGapDrift(func(f string, a ...any) { got = append(got, fmt.Sprintf(f, a...)) }, c.out, c.rc)
			if strings.Join(got, "\n") != strings.Join(c.want, "\n") {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

// A listing failure is the check's exit 2 with its own message, relayed as a degraded WARN.
func TestGapDriftReportOfAnUnlistableTarget(t *testing.T) {
	d := t.TempDir()
	v := &verifier{s: cli.Stdio{Cwd: d}, target: filepath.Join(d, "missing")}
	out, rc := v.gapDriftReport(filepath.Join(d, "RESEARCH-STATE.md"), "")
	if rc != 2 || out != "check-gap-drift: cannot list block files under "+v.target {
		t.Errorf("got rc=%d out=%q", rc, out)
	}
}

// Without a B<n>-G<m> backlog row the report carries no gap-drift line, even when the target holds a block whose bullet
// would have drifted (the observable half of the old vs-rows-guard control). In process the guard in checkState is
// only a short cut: forcing it open leaves the output unchanged, because the check itself reports NoRows silently.
func TestGapDriftNotConsultedWithoutGapRows(t *testing.T) {
	d := t.TempDir()
	sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | plain gap about cats | w | pending |"))
	sdWrite(t, filepath.Join(d, "x-block1.md"), "# b\n\n- **B1-G1** how do the widgets frobnicate the sprockets under load\n")
	if got := sdGo(t, d, false, d); strings.Contains(got.Stdout, "gap-drift") {
		t.Errorf("a state with no B<n>-G<m> row must not consult the drift check:\n%s", got.Stdout)
	}
}
