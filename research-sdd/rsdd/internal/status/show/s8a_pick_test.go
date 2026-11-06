package show

import (
	"bytes"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// root-pick 10 and 10b: `--sync-state --focus aaa` on a healthy corpus exits 0; when the resolver fails with rc 3
// from its SECOND call on (the startup pick succeeds, the sync re-pick fails) the run is a typed error, exit 1,
// and nothing is written. The bash suite stubbed resolve_state_file in a kit copy; the port's seam is resolveState.
func TestS8aSyncFocusRePick(t *testing.T) {
	flat := files{"corpus/RESEARCH-STATE.md": one("root", "pending", 1, "0"), "corpus/RESEARCH-STATE-aaa.md": one("aaa", "pending", 1, "0")}
	runSync := func(t *testing.T) (rc int, errb, tree string) {
		t.Helper()
		sc := m4("sync-focus", "", flat)
		root := sc.build(t)
		var o, e bytes.Buffer
		s := cli.Stdio{Out: &o, Err: &e, Cwd: root, Env: func(string) string { return "" }}
		rc = Run([]string{root + "/corpus", "--sync-state", "--focus", "aaa"}, s)
		return rc, e.String(), readTree(t, root)
	}
	t.Run("10-healthy", func(t *testing.T) {
		if rc, errb, _ := runSync(t); rc != 0 {
			t.Errorf("rc=%d stderr=%q", rc, errb)
		}
	})
	t.Run("10b-resolver-rc-3-on-the-re-pick", func(t *testing.T) {
		old, calls := resolveState, 0
		t.Cleanup(func() { resolveState = old })
		resolveState = func(dir string, o kit.ResolveOptions) (string, error) {
			calls++
			if calls > 1 {
				return "", kit.ErrStateUsage
			}
			return old(dir, o)
		}
		rc, errb, tree := runSync(t)
		first, _, _ := strings.Cut(errb, "\n")
		if rc != 1 || first != "research-sdd-status: state-file resolution failed (rc 3)" {
			t.Errorf("rc=%d stderr=%q", rc, errb)
		}
		if strings.Contains(tree, "schema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 1") && strings.Contains(errb, "wrote") {
			t.Errorf("a failed re-pick wrote a file: %s", errb)
		}
		if calls != 2 {
			t.Errorf("resolver called %d times, want 2 (startup pick, re-pick)", calls)
		}
	})
}
