package show

import (
	"bytes"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The consistency footer of the default report says when verify-state could not run (#2736): an empty block
// would read as "nothing to report" (kit CLAUDE.md section 7). Exit codes and every other line are unchanged.
func TestConsistencyNamesAVerifyStateThatCouldNotRun(t *testing.T) {
	const hdr = "  --- consistency (verify-state.sh) ---\n"
	cases := []struct {
		name, toolbelt string
		rc             int
		said, want     string
	}{
		{"no toolbelt dir", "", 127, "", hdr + "  consistency: DEGRADED — verify state could not run (RSDD_TOOLBELT_DIR is not set)\n"},
		{"script missing", "/tb", 127, "", hdr + "  consistency: DEGRADED — verify state could not run (/tb/verify-state.sh not found)\n"},
		{"not executable", "/tb", 126, "", hdr + "  consistency: DEGRADED — verify state could not run (/tb/verify-state.sh is not executable)\n"},
		{"ran clean", "/tb", 0, "summary: ok\nnoise\n", hdr + "  summary: ok\n"},
		{"ran stale", "/tb", 1, "FAIL x\n", hdr + "  FAIL x\n"},
		{"killed child is not could-not-run", "/tb", 137, "WARN y\n", hdr + "  WARN y\n"},
	}
	old := verifyState
	t.Cleanup(func() { verifyState = old })
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			verifyState = func(_ []string, s cli.Stdio) int {
				_, _ = s.Out.Write([]byte(tc.said))
				return tc.rc
			}
			var out bytes.Buffer
			c := &ctx{s: cli.Stdio{Out: &out, Err: &bytes.Buffer{},
				Env: func(k string) string { return map[string]string{"RSDD_TOOLBELT_DIR": tc.toolbelt}[k] }}, corpus: "/c"}
			c.consistency()
			if out.String() != tc.want {
				t.Errorf("got %q, want %q", out.String(), tc.want)
			}
		})
	}
}
