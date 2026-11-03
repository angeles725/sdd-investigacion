package show

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// Unit tests of slice S5: what the differential cannot say because the script cannot do it (the intended
// divergences), the subprocess inventory, and the pieces under the scenario table.

// ---- a run with stub children --------------------------------------------------------------------------------

type gateStubs struct {
	gh  func(o gh.Options, args ...string) (gh.RunResult, error)
	rec func(args []string, timeout time.Duration, s cli.Stdio) probeResult
	cc  func(script, target string, timeout time.Duration, s cli.Stdio) probeResult
}

// runStubbed runs `--next` over an exhausted corpus holding the retros, with the given extra environment and the
// children replaced by stubs. The toolbelt holds a clean-check.sh (never run: the stub answers).
func runStubbed(t *testing.T, retroFiles files, env map[string]string, st gateStubs) (outcome, string) {
	t.Helper()
	sc := n5("unit", "", one("root", "covered", 0, "0"), retroFiles, env)
	root := sc.build(t)
	tb := t.TempDir()
	must(t, os.WriteFile(filepath.Join(tb, "clean-check.sh"), []byte("#!/bin/sh\n"), 0o755))
	oldV, oldG, oldR, oldC := verifyState, ghList, reconcileRun, cleanCheckRun
	t.Cleanup(func() { verifyState, ghList, reconcileRun, cleanCheckRun = oldV, oldG, oldR, oldC })
	verifyState = func([]string, cli.Stdio) int { return 0 }
	okGH := func(gh.Options, ...string) (gh.RunResult, error) { return gh.RunResult{State: gh.StateOK}, nil }
	okRec := func([]string, time.Duration, cli.Stdio) probeResult { return probeResult{} }
	okCC := func(string, string, time.Duration, cli.Stdio) probeResult { return probeResult{} }
	ghList, reconcileRun, cleanCheckRun = orFunc(st.gh, okGH), orFunc(st.rec, okRec), orFunc(st.cc, okCC)
	e := s5Env{sc.environ(root, t.TempDir(), "/nonexistent-bin"), tb}
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: e.lookup, Environ: func() []string { return e.environ },
		Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: root}
	rc := run([]string{filepath.Join(root, "corpus"), "--next"}, s, syncOr(nextOr(liveSeams, s4Tail)))
	return outcome{rc, strings.ReplaceAll(out.String(), root, "<ROOT>"), strings.ReplaceAll(errb.String(), root, "<ROOT>")}, root
}

func orFunc[F any](f, dflt F) F {
	if reflect.ValueOf(f).IsNil() {
		return dflt
	}
	return f
}

var oneRetro = retros("a.md", "# A\n")

// ---- the intended divergences --------------------------------------------------------------------------------

// The script's _IDG_RECONCILE_TIMEOUT_SECS went to `timeout`, which refuses anything but a duration (an invalid value
// failed every call with exit 125 and made the coverage unverified). The port bounds the call itself: an unusable
// value is the default 15 s, for the batch prefetch and the probes alike.
func TestGateTimeoutKnob(t *testing.T) {
	for _, c := range []struct {
		val  string
		want int
	}{{"", 15}, {"abc", 15}, {"0", 15}, {"-3", 15}, {"1.5", 15}, {"7", 7}, {"007", 7}} {
		var probe time.Duration
		var bound int
		st := gateStubs{
			gh: func(o gh.Options, _ ...string) (gh.RunResult, error) {
				bound = gh.ResolveBound(o.Env, o.Knob, o.Default).Seconds
				return gh.RunResult{State: gh.StateOK}, nil
			},
			rec: func(_ []string, to time.Duration, _ cli.Stdio) probeResult { probe = to; return probeResult{} },
		}
		runStubbed(t, oneRetro, map[string]string{"_IDG_RECONCILE_TIMEOUT_SECS": c.val}, st)
		if probe != time.Duration(c.want)*time.Second || bound != c.want {
			t.Errorf("_IDG_RECONCILE_TIMEOUT_SECS=%q: probe bound %v, gh bound %ds, want %ds", c.val, probe, bound, c.want)
		}
	}
	var probe time.Duration
	runStubbed(t, oneRetro, nil, gateStubs{rec: func(_ []string, to time.Duration, _ cli.Stdio) probeResult { probe = to; return probeResult{} }})
	if probe != 15*time.Second {
		t.Errorf("unset knob: probe bound %v, want 15s", probe)
	}
}

// The script probed for timeout(1)/gtimeout and, with neither (or with the _IDG_TIMEOUT_BIN test hook set empty),
// skipped every probe and called the coverage unverified. The port needs no external timeout: the hook is gone and
// the probes run.
func TestGateNeedsNoTimeoutBinary(t *testing.T) {
	probed := 0
	st := gateStubs{rec: func([]string, time.Duration, cli.Stdio) probeResult { probed++; return probeResult{} }}
	o, _ := runStubbed(t, oneRetro, map[string]string{"_IDG_TIMEOUT_BIN": ""}, st)
	if probed != 1 || o.out != stopExhausted+"\n" || strings.Contains(o.err, "timeout") {
		t.Errorf("probed %d times, stdout %q, stderr %q", probed, o.out, o.err)
	}
}

// A TMPDIR that cannot take the issue cache is named, makes the coverage unverified, and the probes still run on
// their own gh queries (no cache argument). The script went further and skipped every probe when it could not
// capture a probe's stderr; the port captures it in memory.
func TestGateCacheFileFailure(t *testing.T) {
	var calls [][]string
	ghCalled := false
	st := gateStubs{
		gh: func(gh.Options, ...string) (gh.RunResult, error) {
			ghCalled = true
			return gh.RunResult{State: gh.StateOK}, nil
		},
		rec: func(a []string, _ time.Duration, _ cli.Stdio) probeResult {
			calls = append(calls, a)
			return probeResult{}
		},
	}
	o, root := runStubbed(t, oneRetro, map[string]string{"TMPDIR": "/nonexistent-tmp-dir"}, st)
	if want := "WARN: mktemp failed for issue-cache — marking coverage unverified\n"; o.err != want {
		t.Errorf("stderr %q, want %q", o.err, want)
	}
	if want := stopExhausted + " [issue-coverage: unverified]\n"; o.out != want {
		t.Errorf("stdout %q, want %q", o.out, want)
	}
	if ghCalled || !reflect.DeepEqual(calls, [][]string{{filepath.Join(root, "corpus/retros/a.md")}}) {
		t.Errorf("gh called %v, probes %v: want no batch and one cacheless probe", ghCalled, calls)
	}
}

// RSDD_STATUS_CLEAN_CHECK_TIMEOUT: an exact positive integer, normalised (010 is 10); anything else is named and 20.
func TestCleanCheckTimeoutNormalised(t *testing.T) {
	for _, c := range []struct {
		val  string
		want time.Duration
	}{{"", 20}, {"abc", 20}, {"0", 20}, {"00", 20}, {"-1", 20}, {"1.5", 20}, {"1e3", 20}, {"5", 5}, {"010", 10}, {"007", 7}, {"99999999999999999999", 1 << 30}} {
		var got time.Duration
		st := gateStubs{cc: func(_, _ string, to time.Duration, _ cli.Stdio) probeResult { got = to; return probeResult{} }}
		runStubbed(t, nil, map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0", "RSDD_STATUS_CLEAN_CHECK_TIMEOUT": c.val}, st)
		if got != c.want*time.Second {
			t.Errorf("RSDD_STATUS_CLEAN_CHECK_TIMEOUT=%q: bound %v, want %v", c.val, got, c.want*time.Second)
		}
	}
}

// clean-check's two streams are read as `2>&1` did: stdout then stderr, one text.
func TestCleanCheckReadsBothStreams(t *testing.T) {
	st := gateStubs{cc: func(string, string, time.Duration, cli.Stdio) probeResult {
		return probeResult{out: "from stdout\n", err: "from stderr\n", rc: 1}
	}}
	o, _ := runStubbed(t, nil, map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0"}, st)
	if !strings.Contains(o.err, "WARN: clean-check: from stdout\nWARN: clean-check: from stderr\n") {
		t.Errorf("stderr %q", o.err)
	}
}

// A signal-killed clean-check (rc 128+N other than 137) is an unverifiable exit, not a timeout.
func TestCleanCheckSignalExit(t *testing.T) {
	st := gateStubs{cc: func(string, string, time.Duration, cli.Stdio) probeResult { return probeResult{rc: 143, out: "x\ny\n"} }}
	o, _ := runStubbed(t, nil, map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0"}, st)
	if want := "WARN: clean-check: unverifiable (exit 143: y) — terminal no-garbage check NOT confirmed\n"; o.err != want {
		t.Errorf("stderr %q, want %q", o.err, want)
	}
}

// With no toolbelt directory (RSDD_TOOLBELT_DIR unset) the script cannot be found: the typed unverifiable WARN.
func TestCleanCheckWithoutToolbelt(t *testing.T) {
	verifyWith(t, 0, "")
	_, _, errb := runWorld(t, st4("", "0", 0, "", row("high", "G1 done", "covered")), "--next")
	if want := "WARN: clean-check: unverifiable (clean-check.sh not found beside research-sdd-status.sh) — terminal no-garbage check NOT run\n"; errb != want {
		t.Errorf("stderr %q, want %q", errb, want)
	}
}

// ---- the production children ---------------------------------------------------------------------------------

func TestDefaultReconcilePrefix(t *testing.T) {
	self := func() (string, error) { return "/opt/rsdd/bin/rsdd", nil }
	got, err := defaultReconcilePrefix("/kit/toolbelt", self)
	if want := []string{"/opt/rsdd/bin/rsdd", "retro", "reconcile", "--toolbelt", "/kit/toolbelt"}; err != nil || !reflect.DeepEqual(got, want) {
		t.Errorf("with a toolbelt: %v, %v", got, err)
	}
	if got, _ = defaultReconcilePrefix("", self); !reflect.DeepEqual(got, []string{"/opt/rsdd/bin/rsdd", "retro", "reconcile"}) {
		t.Errorf("without a toolbelt: %v", got)
	}
	if _, err = defaultReconcilePrefix("/kit", func() (string, error) { return "", errors.New("no exe") }); err == nil {
		t.Error("an unknown binary path is an error")
	}
}

// execReconcile runs the prefix and the probe arguments from the caller's directory, hands the child the
// shim-style environment, and reports the shell's exit codes: the child's own, 124 for the bound, 127 when it
// cannot be started.
func TestExecReconcile(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "child.sh")
	must(t, os.WriteFile(script, []byte("#!/bin/sh\npwd; printf '%s\\n' \"$@\"; echo \"bin=$RSDD_BIN\"; echo err >&2\n[ \"$2\" = fail ] && exit 3\n[ \"$2\" = slow ] && sleep 5\n[ \"$2\" = kill ] && kill -TERM $$\n[ \"$2\" = hup ] && kill -HUP $$\nexit 0\n"), 0o755))
	old := reconcilePrefix
	t.Cleanup(func() { reconcilePrefix = old })
	reconcilePrefix = func(tb string, _ func() (string, error)) ([]string, error) {
		return []string{script, "--tb=" + tb}, nil
	}
	cwd := t.TempDir()
	s := cli.Stdio{Cwd: cwd, Env: func(k string) string { return map[string]string{"RSDD_TOOLBELT_DIR": "/tb"}[k] },
		Environ: func() []string { return []string{"PATH=" + os.Getenv("PATH"), "RSDD_BIN=/chosen/rsdd"} }}
	r := execReconcile([]string{"--issues-cache", "/c", "retro.md"}, 10*time.Second, s)
	real, _ := filepath.EvalSymlinks(cwd)
	if want := real + "\n--tb=/tb\n--issues-cache\n/c\nretro.md\nbin=/chosen/rsdd\n"; r.rc != 0 || r.out != want || r.err != "err\n" {
		t.Errorf("rc=%d out=%q err=%q", r.rc, r.out, r.err)
	}
	if r = execReconcile([]string{"fail"}, 10*time.Second, s); r.rc != 3 {
		t.Errorf("exit code of the child: %d, want 3", r.rc)
	}
	if r = execReconcile([]string{"kill"}, 10*time.Second, s); r.rc != 143 {
		t.Errorf("a child killed by SIGTERM: rc=%d, want 128+15", r.rc)
	}
	if r = execReconcile([]string{"hup"}, 10*time.Second, s); r.rc != 129 {
		t.Errorf("a child killed by SIGHUP: rc=%d, want 128+1", r.rc)
	}
	start := time.Now()
	if r = execReconcile([]string{"slow"}, 200*time.Millisecond, s); r.rc != 124 || time.Since(start) > 4*time.Second {
		t.Errorf("a probe past its bound: rc=%d after %v, want 124 well before the child ends", r.rc, time.Since(start))
	}
	reconcilePrefix = func(string, func() (string, error)) ([]string, error) {
		return []string{filepath.Join(dir, "absent")}, nil
	}
	if r = execReconcile([]string{"x"}, time.Second, s); r.rc != 127 || r.err == "" {
		t.Errorf("a child that cannot start: rc=%d err=%q, want 127 with the reason", r.rc, r.err)
	}
	reconcilePrefix = func(string, func() (string, error)) ([]string, error) { return nil, errors.New("no exe") }
	if r = execReconcile([]string{"x"}, time.Second, s); r.rc != 127 || !strings.Contains(r.err, "no exe") {
		t.Errorf("no binary path: rc=%d err=%q", r.rc, r.err)
	}
}

// The subprocess inventory (L29/L30), read off the golden the differential records from the frozen script: every
// gh call is the one read-only batch listing, every probe is `reconcile [--issues-cache <file>] <retro>`, every
// clean-check is `--target <corpus>`. No other program is recorded, the fake git of the oracle world logs nothing,
// and each kind is exercised by the table (so the recording wrappers are the ones the runs went through).
func TestS5SubprocessInventory(t *testing.T) {
	ghRE := regexp.MustCompile(`^issue list --repo angeles725/sdd-investigacion --state open --json body --limit [0-9]+ --jq \.\[\]\.body$`)
	recRE := regexp.MustCompile(`^(--issues-cache <CACHE> )?(\S+/)?[A-Za-z.]+\.md( \| cache="[^"\n]*")?$`)
	ccRE := regexp.MustCompile(`^--target <ROOT>/corpus$`)
	b, err := os.ReadFile(goldenS5)
	must(t, err)
	var nGH, nRec, nCC, nCache int
	for _, l := range strings.Split(string(b), "\n") {
		kind, rest, ok := strings.Cut(l, ": ")
		switch {
		case !ok:
		case kind == "gh":
			nGH++
			if !ghRE.MatchString(rest) {
				t.Errorf("unexpected gh call: %s", l)
			}
		case kind == "reconcile":
			nRec++
			if !recRE.MatchString(rest) {
				t.Errorf("unexpected reconcile call: %s", l)
			}
			if strings.HasPrefix(rest, "--issues-cache") {
				nCache++
			}
		case kind == "clean-check":
			nCC++
			if !ccRE.MatchString(rest) {
				t.Errorf("unexpected clean-check call: %s", l)
			}
		}
	}
	if nGH == 0 || nRec == 0 || nCC == 0 || nCache == 0 || nCache == nRec {
		t.Errorf("the table must exercise every child: gh=%d reconcile=%d (cached %d) clean-check=%d", nGH, nRec, nCache, nCC)
	}
	for _, bad := range []string{"\ngit: ", "\ntimeout: ", "\ngtimeout: ", "gh: pr ", "gh: issue create", "gh: issue comment", "gh: api"} {
		if strings.Contains(string(b), bad) {
			t.Errorf("the golden records %q", bad)
		}
	}
}

// ---- the retro enumeration -----------------------------------------------------------------------------------

func TestIsRetroPath(t *testing.T) {
	for _, c := range []struct {
		p    string
		want bool
	}{
		{"c/retros/a.md", true},
		{"c/retros/.md", true},
		{"c/x/retros/sub/a.md", true},
		{"/abs/c/retros/a.md", true},
		{"retros/a.md", false}, // find's `*/retros/*.md` needs a path before the directory
		{"c/retros/a.txt", false},
		{"c/retros/a.MD", false},
		{"c/retros", false},
		{"c/notretros/a.md", false},
		{"c/retros-old/a.md", false},
		{"c/.git/retros/a.md", false},
		{"c/retros/INDEX.md", false},
		{"c/retros/my-Index-2.md", false},
		{"c/retros/reindexed.md", false},
		{"c/retros/ind.md", true},
	} {
		if got := isRetroPath(c.p, filepath.Base(c.p)); got != c.want {
			t.Errorf("isRetroPath(%q) = %v, want %v", c.p, got, c.want)
		}
	}
}

// retroFiles prints paths as find does: the target as the caller wrote it, with no doubled slash after a trailing
// one, and a relative target 'retros' finds nothing (the pattern needs a directory part before it).
func TestRetroFilesSpelling(t *testing.T) {
	root := t.TempDir()
	for _, p := range []string{"corpus/retros/b.md", "corpus/retros/a.md", "retros/c.md"} {
		must(t, os.MkdirAll(filepath.Dir(filepath.Join(root, p)), 0o755))
		must(t, os.WriteFile(filepath.Join(root, p), nil, 0o644))
	}
	must(t, os.Symlink("corpus", filepath.Join(root, "link")))
	for _, c := range []struct {
		target string
		want   []string
	}{
		{"link", nil}, // find does not follow a symlinked start point without a trailing slash ...
		{"link/", []string{"link/retros/a.md", "link/retros/b.md"}}, // ... and follows it with one
		{"corpus", []string{"corpus/retros/a.md", "corpus/retros/b.md"}},
		{"corpus/", []string{"corpus/retros/a.md", "corpus/retros/b.md"}},
		{".", []string{"./corpus/retros/a.md", "./corpus/retros/b.md", "./retros/c.md"}}, // link is not followed from here either
		{"retros", nil},
	} {
		cx := &ctx{s: cli.Stdio{Cwd: root}, target: c.target}
		got, rc := cx.retroFiles()
		if rc != 0 || !reflect.DeepEqual(got, c.want) {
			t.Errorf("target %q: %v (rc %d), want %v", c.target, got, rc, c.want)
		}
	}
}

// ---- the coverage grammar ------------------------------------------------------------------------------------

func TestCoverageLines(t *testing.T) {
	v := func(n int, slug string) covLine { return covLine{n: n, slug: slug} }
	bad := covLine{malformed: true}
	for _, c := range []struct {
		name, src string
		want      []covLine
	}{
		{"plain", "covers_through: B7\n", []covLine{v(7, "-")}},
		{"focus", "covers_through: B7 focus=my.slug_1-x\n", []covLine{v(7, "my.slug_1-x")}},
		{"tabs", "covers_through:\tB7\t \n", []covLine{v(7, "-")}},
		{"tab before focus", "covers_through: B7\tfocus=s\t\n", []covLine{v(7, "s")}},
		{"crlf", "covers_through: B7\r\n", []covLine{v(7, "-")}},
		{"no newline", "covers_through: B7", []covLine{v(7, "-")}},
		{"leading zeros", "covers_through: B007\n", []covLine{v(7, "-")}},
		{"nine digits", "covers_through: B999999999\n", []covLine{v(999999999, "-")}},
		{"ten digits", "covers_through: B1000000000\n", []covLine{bad}},
		{"nine digits after zeros is ten", "covers_through: B0000000007\n", []covLine{bad}},
		{"no b", "covers_through: 7\n", []covLine{bad}},
		{"lower b", "covers_through: b7\n", []covLine{bad}},
		{"no space", "covers_through:B7\n", []covLine{bad}},
		{"empty value", "covers_through:\n", []covLine{bad}},
		{"trailing word", "covers_through: B7 done\n", []covLine{bad}},
		{"bad slug", "covers_through: B7 focus=a/b\n", []covLine{bad}},
		{"empty slug", "covers_through: B7 focus=\n", []covLine{bad}},
		{"two focus tokens", "covers_through: B7 focus=a focus=b\n", []covLine{bad}},
		{"indented", " covers_through: B7\n", nil},
		{"prose", "see covers_through: B7\n", nil},
		{"fence", "```\ncovers_through: B7\n```\ncovers_through: B8\n", []covLine{v(8, "-")}},
		{"tilde fence", "~~~\ncovers_through: B7\n~~~\n", nil},
		{"mismatched marker does not close", "```\n~~~\ncovers_through: B7\n", nil},
		{"longer fence closes with three", "````\ncovers_through: B1\n```\ncovers_through: B2\n", []covLine{v(2, "-")}},
		{"fence with an info string", "```go\ncovers_through: B1\n```\n", nil},
		{"indented fence is not a fence", " ```\ncovers_through: B1\n", []covLine{v(1, "-")}},
		{"two lines", "covers_through: B1\ncovers_through: B x\n", []covLine{v(1, "-"), bad}},
	} {
		if got := coverageLines(c.src); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: %+v, want %+v", c.name, got, c.want)
		}
	}
}

// A focus prefix that holds its own groups ("a(b)-" is the ERE of "ab-") does not move the digits the newest block
// is read from (the script read BASH_REMATCH[2], which is a prefix group there, and then computed on that text).
func TestNewestBlockWithGroupsInThePrefix(t *testing.T) {
	root := t.TempDir()
	for _, n := range []string{"ab-block3.md", "ab-block12.md", "ab-bloque7-x.md", "a(b)-block50.md", "z-block99.md"} {
		must(t, os.WriteFile(filepath.Join(root, n), nil, 0o644))
	}
	d := &coverDeriver{c: &ctx{s: cli.Stdio{Cwd: root, Err: &bytes.Buffer{}}, target: root}, state: root + "/RESEARCH-STATE-a(b).md", pfx: "a(b)-"}
	if got, found := d.newestBlock(); got != 12 || !found {
		t.Errorf("newest block %d (found %v), want 12", got, found)
	}
}

// The newest block reads at most 9 digits (a 10-digit id is skipped, as the script's {1,9} did), B0 is a block, and
// no block file at all is "not found", distinct from block 0.
func TestNewestBlockEdges(t *testing.T) {
	for _, c := range []struct {
		name  string
		files []string
		want  int
		found bool
	}{
		{"nine digits are read", []string{"p-block999999999.md", "p-block3.md"}, 999999999, true},
		{"ten digits are skipped", []string{"p-block1000000000.md", "p-block3.md"}, 3, true},
		{"block zero is a block", []string{"p-block0.md"}, 0, true},
		{"no block files", []string{"p-notes.md"}, 0, false},
	} {
		root := t.TempDir()
		for _, n := range c.files {
			must(t, os.WriteFile(filepath.Join(root, n), nil, 0o644))
		}
		d := &coverDeriver{c: &ctx{s: cli.Stdio{Cwd: root, Err: &bytes.Buffer{}}, target: root}, state: root + "/RESEARCH-STATE-p.md", pfx: "p-"}
		if got, found := d.newestBlock(); got != c.want || found != c.found {
			t.Errorf("%s: newest %d found %v, want %d %v", c.name, got, found, c.want, c.found)
		}
	}
}

// derive's fail-closed rules on retro coverage lines, through the typed lines they print: covers_through B0 is a real
// coverage value, and the "absent in N retro(s)" line is printed only when NO line was skipped for any reason (one
// malformed line plus one over-range line is still a skip, never "absent").
func TestDeriveCoverageEdges(t *testing.T) {
	for _, c := range []struct {
		name, retro, wantEff string
		wantErr             []string
		notErr              string
	}{
		{"covers_through B0 counts", "covers_through: B0 focus=s\n", "5", []string{"overridden by retro coverage (covers_through B0, newest block B5 → 5)"}, "absent in"},
		{"malformed plus over-range is not absent", "covers_through: Bx focus=s\ncovers_through: B9 focus=s\n", "20", []string{"malformed in", "exceeds newest block B5"}, "absent in"},
		{"only over-range is not absent", "covers_through: B9 focus=s\n", "20", []string{"exceeds newest block B5"}, "absent in"},
		{"nothing for this focus is absent", "covers_through: B2 focus=other\n", "20", []string{"covers_through: absent in 1 retro(s)"}, ""},
	} {
		root := t.TempDir()
		rf := filepath.Join(root, "retros", "r1.md")
		must(t, os.MkdirAll(filepath.Dir(rf), 0o755))
		must(t, os.WriteFile(rf, []byte(c.retro), 0o644))
		var errb bytes.Buffer
		d := &coverDeriver{c: &ctx{s: cli.Stdio{Cwd: root, Err: &errb}, target: root}, decl: "20", errw: &errb, myslug: "s"}
		eff, _ := d.derive([]string{rf}, 5)
		if eff != c.wantEff {
			t.Errorf("%s: effective %q, want %q (stderr %q)", c.name, eff, c.wantEff, errb.String())
		}
		for _, w := range c.wantErr {
			if !strings.Contains(errb.String(), w) {
				t.Errorf("%s: stderr lacks %q: %q", c.name, w, errb.String())
			}
		}
		if c.notErr != "" && strings.Contains(errb.String(), c.notErr) {
			t.Errorf("%s: stderr has %q: %q", c.name, c.notErr, errb.String())
		}
	}
}

// dirname is dirname(1) on the edges the slash handling decides.
func TestDirnameEdges(t *testing.T) {
	for in, want := range map[string]string{"/": "/", "///": "/", "/a": "/", "a": ".", "a/b/": "a", "/a/b": "/a", "a//b": "a", "": "."} {
		if got := dirname(in); got != want {
			t.Errorf("dirname(%q) = %q, want %q", in, got, want)
		}
	}
}

// ---- issue #2623: the typed messages of S1-S3 that no golden carried alone ------------------------------------

// STOP: cannot enumerate state files — the --emit-token mapping of a STOP verdict reads the corpus's state files
// and refuses when the listing fails (the script had no such failure: its find ignored errors).
func TestEmitTokenStopCannotEnumerateStateFiles(t *testing.T) {
	old := listStateFiles
	t.Cleanup(func() { listStateFiles = old })
	listStateFiles = func(string) ([]string, error) { return nil, errors.New("permission denied") }
	root := t.TempDir()
	must(t, os.WriteFile(filepath.Join(root, "RESEARCH-STATE.md"), []byte(probeState), 0o644))
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: func(string) string { return "" }, Cwd: root}
	stop := func(c *ctx) int { _, _ = c.s.Out.Write([]byte("STOP | exhausted (0)\n")); return 0 }
	rc := run([]string{root, "--next", "--emit-token"}, s, stop)
	if want := "STOP | exhausted (0)\nreturn-token: unavailable (STOP: cannot enumerate state files (permission denied))\n"; rc != 1 || out.String() != want {
		t.Errorf("rc=%d stdout=%q", rc, out.String())
	}
	// The same STOP with a listing that works maps to the campaign token: the refusal is the listing's.
	listStateFiles = old
	out.Reset()
	if rc = run([]string{root, "--next", "--emit-token"}, s, stop); rc != 0 || !strings.HasSuffix(out.String(), "return-token: STOP: campaign — exhausted (0)\n") {
		t.Errorf("working listing: rc=%d stdout=%q", rc, out.String())
	}
}

// WARN backlog-format row(s) outside ## Gap-backlog: one table row under another heading, with no Gap-backlog
// section anywhere and no other finding.
func TestBacklogRowsOutsideTheSectionWarnsAlone(t *testing.T) {
	out, errw := backlogRows(ln("## Notes", h4, "| high | G1 | x | pending |"), false)
	want := "WARN: 1 backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n"
	if out != "high\tG1\tpending\n" || errw != want {
		t.Errorf("stdout %q stderr %q", out, errw)
	}
	_, errw = backlogRows(ln("## Notes", h4, "| high | G1 | x | pending |", "| low | G2 | x | pending |"), false)
	if errw != strings.Replace(want, "1 backlog", "2 backlog", 1) {
		t.Errorf("two rows: stderr %q", errw)
	}
}

// WARN COVERED row has N cells in 4-col / 5-col table: a pipe inside the status cell, one table width at a time,
// each with no other finding. The 5-cell row of a 4-column table, and the 6-cell row of a 5-column table.
func TestCoveredRowWithAPipeInTheStatusCell(t *testing.T) {
	r4 := "| low | g3 | x | covered (a | b) |"
	_, errw := backlogRows(ln("## Gap-backlog", h4, r4), false)
	if want := "WARN: COVERED row has 5 cells in 4-col table (pipe in status cell) — review: " + r4 + "\n"; errw != want {
		t.Errorf("4-col: stderr %q, want %q", errw, want)
	}
	r5 := "| low | B1-G3 | x | y | covered (a | b) |"
	_, errw = backlogRows(ln("## Gap-backlog", h5, r5), false)
	if want := "WARN: COVERED row has 6 cells in 5-col table (pipe in status cell) — review: " + r5 + "\n"; errw != want {
		t.Errorf("5-col: stderr %q, want %q", errw, want)
	}
	// Not covered: the same widths are a malformed row, a different message.
	_, errw = backlogRows(ln("## Gap-backlog", h4, "| low | g3 | x | pending (a | b) |"), false)
	if strings.Contains(errw, "COVERED") || !strings.Contains(errw, "malformed backlog row (5 cells, expected 4") {
		t.Errorf("a pending row: stderr %q", errw)
	}
}

// The two sections that were seams are answered by the production entry: a counter past the threshold is
// RETRO-DUE (the derivation cannot apply without block files and says so), and an exhausted walk is the STOP.
func TestRunNextAnswersRetroDueAndTheExhaustedStop(t *testing.T) {
	verifyWith(t, 0, "")
	rc, out, errb := runWorld(t, st4("", "11", -1, "", row("high", "G1 live", "pending")), "--next")
	if rc != 0 || out != "RETRO-DUE | 11 blocks since last retro (§18 threshold: 10)\n" || !strings.Contains(errb, "covers_through not applied: no block files found for RESEARCH-STATE.md") {
		t.Errorf("retro-due: rc=%d stdout=%q stderr=%q", rc, out, errb)
	}
	for _, flags := range [][]string{{"--next"}, {"--next", "--root"}} {
		rc, out, errb = runWorld(t, st4("", "0", 0, "", row("high", "G1 done", "covered")), flags...)
		if rc != 0 || out != stopExhausted+"\n" || strings.Contains(errb, "not-yet-ported") {
			t.Errorf("%v: rc=%d stdout=%q stderr=%q", flags, rc, out, errb)
		}
	}
}
