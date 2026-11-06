package show

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

func stdio(cwd string) (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	var out, errb bytes.Buffer
	return cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: func(string) string { return "" }, Cwd: cwd}, &out, &errb
}

func TestStateRC(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want int
	}{
		{nil, 0},
		{kit.ErrStateAbsent, 1},
		{kit.ErrStateAmbiguous, 2},
		{kit.ErrStateUsage, 3},
		{errors.New("other"), 3},
	} {
		if got := stateRC(tc.err); got != tc.want {
			t.Errorf("stateRC(%v) = %d, want %d", tc.err, got, tc.want)
		}
	}
}

// A failed resolution (bash rc 3) cannot be reached through a real corpus once the target is a directory, so the
// resolver is injected: the run stops with exit 1 and the typed line, and prints no verdict.
func TestPickFailedResolution(t *testing.T) {
	for _, focus := range []string{"", "x"} {
		root := t.TempDir()
		s, out, errb := stdio(root)
		c := &ctx{s: s, target: root, opts: options{focus: focus}}
		rc, done := c.pick(func(string, kit.ResolveOptions) (string, error) { return "", kit.ErrStateUsage })
		if rc != 1 || !done || out.Len() != 0 || errb.String() != "research-sdd-status: state-file resolution failed (rc 3)\n" {
			t.Errorf("focus %q: rc=%d done=%v stdout=%q stderr=%q", focus, rc, done, out.String(), errb.String())
		}
	}
}

// Ambiguous (rc 2) and absent (rc 1) resolutions are accepted: the first pick is used, or BOOTSTRAP is answered.
func TestPickAcceptsAmbiguousAndAbsent(t *testing.T) {
	root := t.TempDir()
	state := filepath.Join(root, "RESEARCH-STATE.md")
	if err := os.WriteFile(state, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	s, out, _ := stdio(root)
	c := &ctx{s: s, target: root}
	if rc, done := c.pick(func(string, kit.ResolveOptions) (string, error) { return state, kit.ErrStateAmbiguous }); rc != 0 || done || c.state != state || c.corpus != root {
		t.Errorf("ambiguous: rc=%d done=%v state=%q corpus=%q", rc, done, c.state, c.corpus)
	}
	c = &ctx{s: s, target: root, opts: options{mode: modeNext}}
	if rc, done := c.pick(func(string, kit.ResolveOptions) (string, error) { return "", kit.ErrStateAbsent }); rc != 0 || !done || out.String() != "BOOTSTRAP | no RESEARCH-STATE under "+root+"\n" {
		t.Errorf("absent: rc=%d done=%v stdout=%q", rc, done, out.String())
	}
}

// verifyWith answers every verify-state call of one test with the given exit code and report.
func verifyWith(t *testing.T, rc int, report string) {
	t.Helper()
	old := verifyState
	t.Cleanup(func() { verifyState = old })
	verifyState = func(_ []string, s cli.Stdio) int {
		_, _ = io.WriteString(s.Out, report)
		return rc
	}
}

// runWorld runs the production entry over a corpus holding one state file.
func runWorld(t *testing.T, state string, args ...string) (rc int, out, errb string) {
	t.Helper()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "RESEARCH-STATE.md"), []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
	s, o, e := stdio(root)
	rc = Run(append([]string{root}, args...), s)
	return rc, strings.ReplaceAll(o.String(), root, "<ROOT>"), e.String()
}

// The default report is ported whole: through the production entry it prints the campaign and document-cycle
// sections S7 supplied, where S6 answered a typed not-yet-ported line.
func TestRunDefaultReportIsPorted(t *testing.T) {
	verifyWith(t, 0, "")
	rc, out, errb := runWorld(t, probeState)
	if rc != 0 || errb != "" || strings.Contains(out, "not-yet-ported") ||
		!strings.Contains(out, "  campaign        : none (1 active focus, 0 with a queue)\n  last_iteration_ts: absent\n") {
		t.Errorf("rc=%d stdout=%q stderr=%q", rc, out, errb)
	}
}

// --next is ported: through the production entry it answers the verdict (NEXT here) and --emit-token maps it.
func TestRunNextIsPorted(t *testing.T) {
	verifyWith(t, 0, "")
	state := st4("", "0", -1, "", row("high", "G1 live", "pending"))
	if rc, out, errb := runWorld(t, state, "--next"); rc != 0 || out != "NEXT | high | G1 live\n" || errb != "" {
		t.Errorf("--next: rc=%d stdout=%q stderr=%q", rc, out, errb)
	}
	if rc, out, _ := runWorld(t, state, "--next", "--emit-token"); rc != 0 || out != "NEXT | high | G1 live\nreturn-token: next: G1 live\n" {
		t.Errorf("--next --emit-token: rc=%d stdout=%q", rc, out)
	}
	verifyWith(t, 1, "== verify-state: RESEARCH-STATE.md (target: t) ==\n   FAIL   no research-state.v1 envelope\n")
	if rc, out, _ := runWorld(t, probeState, "--next"); rc != 0 || out != "STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh <ROOT> [first failure: RESEARCH-STATE.md: no research-state.v1 envelope]\n" {
		t.Errorf("a state with no envelope is STALE: rc=%d stdout=%q", rc, out)
	}
}
