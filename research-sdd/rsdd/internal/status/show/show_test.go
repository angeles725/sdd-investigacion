package show

import (
	"bytes"
	"errors"
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

// Run is the production entry: past the pick the later sections are not ported, which is a typed operational
// failure and never a silent success.
func TestRunPastThePickIsNotYetPorted(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "RESEARCH-STATE.md"), []byte(probeState), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"--next"} {
		s, out, errb := stdio(root)
		if rc := Run([]string{root, mode}, s); rc != cli.ExitOperational || out.Len() != 0 ||
			errb.String() != "rsdd: status show: not-yet-ported: "+mode+" after the state-file pick; use toolbelt/research-sdd-status.sh (issue #2549)\n" {
			t.Errorf("%s: rc=%d stdout=%q stderr=%q", mode, rc, out.String(), errb.String())
		}
	}
	s, out, errb := stdio(root)
	if rc := Run([]string{root, "--next", "--emit-token"}, s); rc != 1 || !strings.Contains(out.String(), "return-token: unavailable (--next exited 1)") || !strings.Contains(errb.String(), "not-yet-ported") {
		t.Errorf("emit-token over the unported --next: rc=%d stdout=%q stderr=%q", rc, out.String(), errb.String())
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
