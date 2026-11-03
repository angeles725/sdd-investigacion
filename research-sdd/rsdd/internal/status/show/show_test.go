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

// The default report is not ported yet: past the pick it is a typed operational failure, never a silent success.
func TestRunDefaultReportIsNotYetPorted(t *testing.T) {
	rc, out, errb := runWorld(t, probeState)
	if rc != cli.ExitOperational || out != "" ||
		errb != "rsdd: status show: not-yet-ported: status after the state-file pick; use toolbelt/research-sdd-status.sh (issue #2549)\n" {
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

// The two sections the --next block calls into that belong to slice S5 end the run as not yet ported, typed and
// operational, the moment a verdict needs them: a counter past the threshold, and the terminal exhausted STOP.
func TestRunNextAnswersNotYetPortedAtTheS5Sections(t *testing.T) {
	verifyWith(t, 0, "")
	for _, c := range []struct{ name, state, section string }{
		{"retro-due", st4("", "11", -1, "", row("high", "G1 live", "pending")), "RETRO-DUE covers_through derivation"},
		{"exhausted-stop", st4("", "0", 0, "", row("high", "G1 done", "covered")), "issues_due_gate"},
	} {
		rc, out, errb := runWorld(t, c.state, "--next")
		if want := "rsdd: status show: not-yet-ported: " + c.section + " of --next; use toolbelt/research-sdd-status.sh (issue #2549)\n"; rc != cli.ExitOperational || out != "" || errb != want {
			t.Errorf("%s: rc=%d stdout=%q stderr=%q", c.name, rc, out, errb)
		}
		rc, out, _ = runWorld(t, c.state, "--next", "--root")
		if rc != cli.ExitOperational || out != "" {
			t.Errorf("%s --root: rc=%d stdout=%q", c.name, rc, out)
		}
	}
}

// --sync-state is ported: through the production entry it writes the envelope and no longer answers not-yet-ported.
func TestRunSyncStateIsPorted(t *testing.T) {
	root := t.TempDir()
	state := filepath.Join(root, "RESEARCH-STATE.md")
	if err := os.WriteFile(state, []byte(probeState), 0o644); err != nil {
		t.Fatal(err)
	}
	s, out, errb := stdio(root)
	if rc := Run([]string{root, "--sync-state"}, s); rc != 0 || !strings.HasPrefix(out.String(), "sync-state: wrote ") || strings.Contains(errb.String(), "not-yet-ported") {
		t.Fatalf("rc=%d stdout=%q stderr=%q", rc, out.String(), errb.String())
	}
	if b, _ := os.ReadFile(state); !strings.Contains(string(b), "<!-- research-state.v1 -->") {
		t.Errorf("no envelope written: %q", b)
	}
}

func TestPositiveInt(t *testing.T) {
	for in, want := range map[string]bool{"1": true, "15": true, "0007": true, "9223372036854775807": true, "0": false, "": false, "-1": false, "1.5": false, "1a": false, "9223372036854775808": false, " 1": false} {
		if _, ok := positiveInt(in); ok != want {
			t.Errorf("positiveInt(%q) ok = %v, want %v", in, ok, want)
		}
	}
	if n, _ := positiveInt("0007"); n != 7 {
		t.Errorf("positiveInt(0007) = %d, want 7", n)
	}
}

func TestDirname(t *testing.T) {
	for in, want := range map[string]string{"a/b": "a", "a/b/": "a", "a//b": "a", "/a": "/", "a": ".", "./x": ".", "../c/s": "../c", "/": "/", "//": "/", "": "."} {
		if got := dirname(in); got != want {
			t.Errorf("dirname(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestShowMapsBackToTheCallersSpelling(t *testing.T) {
	s, _, _ := stdio("/w")
	c := &ctx{s: s, target: "corpus/"}
	if got := c.show("/w/corpus/RESEARCH-STATE.md"); got != "corpus/RESEARCH-STATE.md" {
		t.Errorf("show = %q", got)
	}
	if got := c.show(""); got != "" {
		t.Errorf("show(empty) = %q", got)
	}
	if got := c.show("/elsewhere/x"); got != "/elsewhere/x" {
		t.Errorf("show(outside) = %q", got)
	}
	abs := &ctx{s: s, target: "/w/corpus"}
	if got := abs.show("/w/corpus/x"); got != "/w/corpus/x" {
		t.Errorf("show(absolute target) = %q", got)
	}
}
