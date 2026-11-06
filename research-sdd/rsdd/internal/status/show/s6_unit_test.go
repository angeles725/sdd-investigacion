package show

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// Unit tests of slice S6: what the differential cannot say because the script cannot do it (the intended
// divergences, the production wiring), and the pieces under the scenario table.

// runS6 runs the default report over a one-state world with the given environment.
func runS6(t *testing.T, env map[string]string, flags ...string) (rc int, out, errs string) {
	t.Helper()
	sc := os6("unit", "", one("root", "pending", 1, "0"), nil, env)
	root := sc.build(t)
	e := s5Env{sc.environ(root, t.TempDir(), "/nonexistent-bin"), t.TempDir()}
	var o, eb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &eb, Env: e.lookup, Environ: func() []string { return e.environ },
		Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: root}
	seamMu.Lock()
	defer seamMu.Unlock()
	old := verifyState
	defer func() { verifyState = old }()
	verifyState = func([]string, cli.Stdio) int { return 0 }
	rc = run(append([]string{filepath.Join(root, "corpus")}, flags...), s, syncOr(nextOr(liveSeams, (*ctx).report)))
	return rc, o.String(), eb.String()
}

// A state-file listing that fails refuses the run before any output (the script ignored the failure).
func TestReportRefusesAFailingStateListing(t *testing.T) {
	old := listStateFiles
	t.Cleanup(func() { listStateFiles = old })
	listStateFiles = func(string) ([]string, error) { return nil, errors.New("boom") }
	rc, out, errs := runS6(t, nil)
	if rc != 1 || out != "" || !strings.Contains(errs, "degraded: cannot list the state files under") || !strings.Contains(errs, "boom") {
		t.Errorf("rc=%d out=%q err=%q, want the typed refusal and no output", rc, out, errs)
	}
}

// ---- the remote-visibility block, states the fake gh cannot produce ------------------------------------------

// visCtx is a context over a directory with a .git and the given gh seams.
func visCtx(t *testing.T, environ []string) (*ctx, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, ".git"), 0o755))
	var out bytes.Buffer
	s := cli.Stdio{Out: &out, Err: &bytes.Buffer{}, Env: func(string) string { return "" }, Environ: func() []string { return environ }, Cwd: root}
	return &ctx{s: s, target: root}, &out
}

func TestVisibilityNamesAMissingGit(t *testing.T) {
	c, out := visCtx(t, []string{"PATH=/nonexistent-bin"})
	if !c.remoteVisibility() {
		t.Error("a block that printed a degraded line must say so")
	}
	if want := "degraded: remote-visibility: git not found — cannot read the remotes of " + c.target + "\n"; out.String() != want {
		t.Errorf("got %q, want %q", out.String(), want)
	}
}

func TestVisibilityOfADirectoryWithoutGitIsSilent(t *testing.T) {
	c, out := visCtx(t, nil)
	must(t, os.Remove(filepath.Join(c.target, ".git")))
	if c.remoteVisibility() || out.Len() != 0 {
		t.Errorf("no .git must be silent, printed %q", out.String())
	}
}

func TestVisibilityStatesOfTheProbe(t *testing.T) {
	cases := []struct {
		name string
		v    gh.Visibility
		want string
	}{
		{"probe could not run", gh.Visibility{State: gh.StateProbeFailed}, "degraded: remote-visibility: gh probe could not run (PROBE_FAILED) for remote origin — visibility unverified\n"},
		{"gh vanished", gh.Visibility{State: gh.StateMissing}, "degraded: remote-visibility: gh probe could not run (GH_MISSING) for remote origin — visibility unverified\n"},
		{"output cap", gh.Visibility{State: gh.StateOutputCap, Raw: "XYZ"}, "degraded: remote-visibility: unrecognised gh answer [XYZ] for remote origin — visibility unverified\n"},
		{"killed", gh.Visibility{State: gh.StateError, RC: 137}, "degraded: remote-visibility: gh failed (rc=137) for remote origin — visibility unverified\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := os6("v", "", one("root", "pending", 1, "0"), gitRepo("origin", "https://github.com/o/r"), nil)
			root := sc.build(t)
			var out bytes.Buffer
			s := cli.Stdio{Out: &out, Err: &bytes.Buffer{}, Env: func(string) string { return "" }, Environ: func() []string { return os.Environ() }, Cwd: root}
			c := &ctx{s: s, target: filepath.Join(root, "corpus")}
			seamMu.Lock()
			oldP, oldF := ghProbe, ghFound
			ghProbe = func(gh.Options, string) (gh.Visibility, error) { return tc.v, nil }
			ghFound = func(string, []string, string) bool { return true }
			got := c.remoteVisibility()
			ghProbe, ghFound = oldP, oldF
			seamMu.Unlock()
			if !got || out.String() != tc.want {
				t.Errorf("degraded=%v out=%q, want %q", got, out.String(), tc.want)
			}
		})
	}
}

// What the probe is handed: the slug and nothing of the URL, the bound of this script (10 s), the caller's gh.
func TestVisibilityProbeArguments(t *testing.T) {
	sc := os6("v", "", one("root", "pending", 1, "0"), gitRepo("origin", "https://user:tok@github.com/o/r.git"), nil)
	root := sc.build(t)
	var out bytes.Buffer
	s := cli.Stdio{Out: &out, Err: &bytes.Buffer{}, Env: func(k string) string {
		if k == "RSDD_GH_BIN" {
			return "my-gh"
		}
		return ""
	}, Environ: func() []string { return os.Environ() }, Cwd: root}
	c := &ctx{s: s, target: filepath.Join(root, "corpus")}
	var gotRepo string
	var gotOpts gh.Options
	seamMu.Lock()
	defer seamMu.Unlock()
	oldP, oldF := ghProbe, ghFound
	defer func() { ghProbe, ghFound = oldP, oldF }()
	ghFound = func(bin string, _ []string, _ string) bool { return bin == "my-gh" }
	ghProbe = func(o gh.Options, repo string) (gh.Visibility, error) {
		gotOpts, gotRepo = o, repo
		return gh.Visibility{State: gh.StatePrivate, Raw: "PRIVATE"}, nil
	}
	c.remoteVisibility()
	if gotRepo != "o/r" || gotOpts.Bin != "my-gh" || gotOpts.Default != 10 || gotOpts.Dir != root {
		t.Errorf("probe got repo=%q opts={Bin:%q Default:%d Dir:%q}", gotRepo, gotOpts.Bin, gotOpts.Default, gotOpts.Dir)
	}
}

func TestCommandFound(t *testing.T) {
	dir := t.TempDir()
	exe, plain := filepath.Join(dir, "tool"), filepath.Join(dir, "plain")
	must(t, os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o755))
	must(t, os.WriteFile(plain, []byte("x"), 0o644))
	must(t, os.Mkdir(filepath.Join(dir, "sub"), 0o755))
	cases := []struct {
		name    string
		bin     string
		environ []string
		cwd     string
		want    bool
	}{
		{"absolute path", exe, nil, "/", true},
		{"not executable", plain, nil, "/", false},
		{"a directory", filepath.Join(dir, "sub"), nil, "/", false},
		{"missing", filepath.Join(dir, "none"), nil, "/", false},
		{"relative path is relative to the working directory", "./tool", nil, dir, true},
		{"relative path elsewhere", "./tool", nil, filepath.Join(dir, "sub"), false},
		{"on the PATH", "tool", []string{"PATH=/nonexistent:" + dir}, "/", true},
		{"PATH last entry wins over earlier ones", "tool", []string{"PATH=/a", "PATH=" + dir}, "/", true},
		{"not on the PATH", "tool", []string{"PATH=/nonexistent"}, "/", false},
		{"no PATH at all", "tool", nil, "/", false},
		{"empty PATH entry is the working directory", "tool", []string{"PATH=/nonexistent:"}, dir, true},
		{"plain file on the PATH", "plain", []string{"PATH=" + dir}, "/", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := commandFound(tc.bin, tc.environ, tc.cwd); got != tc.want {
				t.Errorf("commandFound(%q) = %v, want %v", tc.bin, got, tc.want)
			}
		})
	}
}

// ---- the readers ----------------------------------------------------------------------------------------------

func TestNumCmp(t *testing.T) {
	for _, tc := range []struct {
		a, b string
		want int
	}{{"1", "1", 0}, {"007", "7", 0}, {"9", "10", -1}, {"10", "9", 1}, {"0", "00", 0}, {"12", "13", -1}, {"13", "12", 1}, {"99999999999999999999", "100000000000000000000", -1}} {
		got := numCmp(tc.a, tc.b)
		if (got < 0) != (tc.want < 0) || (got > 0) != (tc.want > 0) {
			t.Errorf("numCmp(%q, %q) = %d, want sign %d", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestSortByKeyTies(t *testing.T) {
	a, b := iterRec{"row", "1", "ok", "5"}, iterRec{"row", "1", "bad", "z"}
	if got := sortByKey([]iterRec{a, b}, false); got[0] != b {
		t.Errorf("unstable sort breaks a tie on the whole line: %v", got)
	}
	if got := sortByKey([]iterRec{a, b}, true); got[0] != a {
		t.Errorf("stable sort keeps the file order of a tie: %v", got)
	}
}

func TestAwkInt(t *testing.T) {
	for in, want := range map[string]string{"0": "0", "007": "7", "12": "12", "9007199254740993": "9007199254740992"} {
		if got := awkInt(in); got != want {
			t.Errorf("awkInt(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestErrnoText(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want string
	}{{fs.ErrPermission, "Permission denied"}, {fs.ErrNotExist, "No such file or directory"}, {errors.New("other"), "other"}} {
		if got := errnoText(tc.err); got != tc.want {
			t.Errorf("errnoText(%v) = %q, want %q", tc.err, got, tc.want)
		}
	}
}

func TestFirstFormsKeepsTwoDistinct(t *testing.T) {
	recs := []iterRec{{"row", "1", "bad", "a"}, {"row", "2", "ok", "1"}, {"row", "3", "bad", "a"}, {"row", "4", "bad", "b"}, {"row", "5", "bad", "c"}}
	if got := firstForms(recs); got != "a,b" {
		t.Errorf("firstForms = %q, want a,b", got)
	}
	if got := countBad(recs); got != 4 {
		t.Errorf("countBad = %d, want 4", got)
	}
}

func TestIterStreamHeaderOnlyTable(t *testing.T) {
	recs, hdr, noCol := iterStream("| Iter | Notes |\n|---|---|\n| 1 | x |\n")
	if !noCol || hdr != " Iter | Notes " || recs != nil {
		t.Errorf("got recs=%v hdr=%q noCol=%v", recs, hdr, noCol)
	}
}
