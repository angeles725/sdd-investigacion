package skilldrift

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Behaviour tests that parity cannot express: the intended divergences (intended.go), the seams a test must reach with a fake,
// and the properties the legacy suites asserted with shell probes.

func TestCommandsAreValid(t *testing.T) {
	if err := cli.Validate(Commands); err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, c := range Commands {
		if c.Group != "verify" {
			t.Errorf("%s: group %q, want verify", c.Name, c.Group)
		}
		names[c.Name] = true
	}
	for _, want := range []string{"skill-drift", "skill-drift-hook"} {
		if !names[want] {
			t.Errorf("command %q is not registered", want)
		}
	}
}

// Intended divergence 1: through cli.Run a final exit code 3 is "degraded", so the absent report gets one extra line.
func TestAbsentThroughCLIAddsOneDegradedLine(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	w := newWorld(t, "")
	emptyClaudeRoot(t, w)
	env := w.runEnv(nil)
	var out, errb bytes.Buffer
	code := cli.Run(Commands, []string{"verify", "skill-drift", "--harness", "claude", "--home", w.home}, w.goStdio(env, &out, &errb))
	legacy := w.runBash("verify-skill-drift.sh", []string{"--harness", "claude", "--home", w.home}, env)
	if code != 3 || legacy.code != 3 {
		t.Fatalf("exit = %d (legacy %d), want 3", code, legacy.code)
	}
	if want := legacy.err + "DEGRADED: command reported a degraded state without a reason\n"; errb.String() != want {
		t.Errorf("stderr = %q, want the legacy line plus the cli's degraded line: %q", errb.String(), want)
	}
}

// Intended divergence 2: no toolbelt directory handed over.
func TestToolbeltDirUnknown(t *testing.T) {
	for _, name := range []string{"drift", "hook"} {
		t.Run(name, func(t *testing.T) {
			var out, errb bytes.Buffer
			s := cli.Stdio{Out: &out, Err: &errb, Env: func(string) string { return "" }, Environ: func() []string { return nil }, Cwd: t.TempDir()}
			if name == "drift" {
				code := RunDrift(nil, s)
				if code != 2 || !strings.Contains(errb.String(), "RSDD_TOOLBELT_DIR unset") || out.Len() != 0 {
					t.Errorf("exit %d stdout %q stderr %q", code, out.String(), errb.String())
				}
				return
			}
			if code := RunHook(nil, s); code != 0 || !strings.Contains(decode(out.String()), "RSDD_TOOLBELT_DIR is unset") {
				t.Errorf("a hook never fails the session but must announce it: exit %d out %q", code, out.String())
			}
		})
	}
}

// Intended divergence 3: bash is the exec seam; its absence is a typed degraded state, never an empty verdict.
func TestBashMissingIsTyped(t *testing.T) {
	w := newWorld(t, "")
	claudeSync(t, w)
	empty := filepath.Join(w.root, "emptybin")
	if err := os.MkdirAll(empty, 0o755); err != nil {
		t.Fatal(err)
	}
	r := w.runGoDrift([]string{"--harness", "claude", "--home", "@HOME@"}, w.runEnv([]string{"PATH=" + empty}))
	if r.code != 2 || !strings.Contains(r.err, "degraded: bash not found") || r.out != "" {
		t.Errorf("exit %d stdout %q stderr %q", r.code, r.out, r.err)
	}
}

func TestHarnessListUndefinedIsCouldNotRun(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	w := newWorld(t, "noadapters")
	write(t, filepath.Join(filepath.Dir(w.tb), "install", "adapters.sh"), "x=1\n", 0o644)
	env := w.runEnv(nil)
	all := w.runGoDrift([]string{"--all", "--home", "@HOME@"}, env)
	if all.code != 2 || !strings.Contains(all.err, "RESEARCH_SDD_HARNESSES is not defined") {
		t.Errorf("--all: exit %d stderr %q", all.code, all.err)
	}
	one := w.runGoDrift([]string{"--harness", "claude", "--home", "@HOME@"}, env)
	if one.code != 2 || !strings.Contains(one.err, `ERROR: unknown harness "claude"`) {
		t.Errorf("single: exit %d stderr %q", one.code, one.err)
	}
}

// Intended divergence 3: a failing mktemp is could-not-run, in both modes.
func TestMktempFailureIsCouldNotRun(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	w := newWorld(t, "")
	piInstalled(t, w)
	env := w.runEnv([]string{"TMPDIR=@ROOT@/no-such-tmp"})
	one := w.runGoDrift([]string{"--harness", "pi", "--home", "@HOME@"}, env)
	if one.code != 2 || !strings.Contains(one.err, `ERROR: could not render profile for harness "pi"`) {
		t.Errorf("single: exit %d stderr %q", one.code, one.err)
	}
	all := w.runGoDrift([]string{"--all", "--home", "@HOME@"}, env)
	if all.code != 2 || !strings.Contains(all.err, "could-not-run harness=pi (profile render failed)") {
		t.Errorf("--all: exit %d stderr %q", all.code, all.err)
	}
}

// legacy 15 / 15b: the header and the per-harness fix line of the real report are at most 200 characters.
func TestDriftReportLineWidths(t *testing.T) {
	c := hcase{kit: "real", home: claudeStale}
	w, env := c.prepare(t)
	ctx := decode(w.runGoHook(c, env).out)
	lines := strings.Split(ctx, "\n")
	if len(lines[0]) == 0 || len(lines[0]) > 200 {
		t.Errorf("header is %d characters: %q", len(lines[0]), lines[0])
	}
	found := false
	for _, l := range lines {
		if strings.Contains(l, "force-skill") {
			found = true
			if len(l) > 200 {
				t.Errorf("fix line is %d characters: %q", len(l), l)
			}
		}
	}
	if !found {
		t.Errorf("no fix line in %q", ctx)
	}
}

// legacy K18 K18b K18c: an unreadable fetch age leaves the commit count in charge, and verbose says so.
func TestKitStaleUnreadableFetchAge(t *testing.T) {
	broken := func(string) (int64, error) { return 0, errors.New("stat failed") }
	run := func(kdir string, verbose bool) string {
		env := []string{}
		if verbose {
			env = []string{"RESEARCH_SDD_KIT_STALE_VERBOSE=1"}
		}
		c := hcase{kit: "stub", kdir: kdir, env: env}
		w, renv := c.prepare(t)
		var out, errb bytes.Buffer
		runHook(w.goStdio(renv, &out, &errb), hookDeps{drift: func([]string, cli.Stdio) int { return 0 }, mtime: broken})
		return decode(out.String())
	}
	if got := run("k25", false); !strings.Contains(got, "behind=25") || !strings.Contains(got, "fetch_age=?d") {
		t.Errorf("K18: count must still govern with fetch_age=?, got %q", got)
	}
	if got := run("k3", false); got != "" {
		t.Errorf("K18b: unreadable age within the count threshold must be silent, got %q", got)
	}
	if got := run("k3", true); !strings.Contains(got, "kit-stale status=degraded reason=cannot read the age of the last fetch") {
		t.Errorf("K18c: verbose must type the unreadable age, got %q", got)
	}
}

// legacy 15 TOOTH: the awk widths count characters, the 170-byte finding cut counts bytes (and may split a character).
func TestWidthSemantics(t *testing.T) {
	if got := clip(strings.Repeat("é", 300), 280); utf8.RuneCountInString(got) != 280 || !utf8.ValidString(got) {
		t.Errorf("clip must cut at 280 characters on a character boundary, got %d characters, valid=%v", utf8.RuneCountInString(got), utf8.ValidString(got))
	}
	if got := clip("abc", 3); got != "abc" {
		t.Errorf("clip must keep a string of exactly the width, got %q", got)
	}
	if got := clip("abc", 0); got != "" {
		t.Errorf("clip to 0 must be empty, got %q", got)
	}
	f := findings("verify harness=pi status=degraded reason=" + strings.Repeat("é", 100))
	if len(f) != maxFindingBytes || utf8.ValidString(f) {
		t.Errorf("a finding is cut at %d bytes, splitting the character at the edge: len=%d valid=%v", maxFindingBytes, len(f), utf8.ValidString(f))
	}
	ents := strings.Repeat("é", 400) + ",b.md"
	r := driftReport("verify harness=pi status=drift drifted=" + ents)
	for _, l := range strings.Split(r, "\n") {
		if strings.HasPrefix(l, "  - ") && utf8.RuneCountInString(l) > 4+driftWidth {
			t.Errorf("entry line has %d characters", utf8.RuneCountInString(l))
		}
	}
}

func TestFindingsKeepOnlyTypedLinesAndCapAtFour(t *testing.T) {
	in := strings.Join([]string{
		"verify harness=claude status=match files=3",
		"verify harness=pi status=degraded a", "verify kit status=degraded no", "verify kit status=behind b",
		"noise", "verify harness=x status=degraded c", "verify harness=y status=degraded d", "verify harness=z status=degraded e",
	}, "\n")
	want := "verify harness=pi status=degraded a\nverify kit status=behind b\nverify harness=x status=degraded c\nverify harness=y status=degraded d"
	if got := findings(in); got != want {
		t.Errorf("findings = %q, want %q", got, want)
	}
}

func TestThresholdValidation(t *testing.T) {
	cases := []struct {
		val  string
		set  bool
		want int
		note string
	}{
		{"", false, 20, ""}, {"5", true, 5, ""}, {"007", true, 7, ""}, {"0", true, 0, ""}, {"999999", true, 999999, ""},
		{"", true, 20, "verify kit-stale: invalid K='', using 20"}, {"1234567", true, 20, "verify kit-stale: invalid K='1234567', using 20"},
		{"-1", true, 20, "verify kit-stale: invalid K='-1', using 20"}, {"a[$(x)]", true, 20, "verify kit-stale: invalid K='ax', using 20"},
	}
	for _, c := range cases {
		e := newEnvView(cli.Stdio{Environ: func() []string {
			if c.set {
				return []string{"K=" + c.val}
			}
			return nil
		}})
		var notes []string
		if got := threshold(e, "K", 20, &notes); got != c.want {
			t.Errorf("threshold(%q set=%v) = %d, want %d", c.val, c.set, got, c.want)
		}
		if got := strings.Join(notes, "|"); got != c.note {
			t.Errorf("note for %q = %q, want %q", c.val, got, c.note)
		}
	}
	if got := sanitize(strings.Repeat("a", 40)); len(got) != 30 {
		t.Errorf("sanitize keeps 30 bytes, got %d", len(got))
	}
}

// The envelope encoding is held to jq's own output, byte for byte.
func TestSessionStartMatchesJq(t *testing.T) {
	needTool(t, "jq", "RSDD_REQUIRE_JQ")
	for _, s := range []string{"", "plain", "quote \" slash \\ tab\t nl\n cr\r bs\b ff\f", "ctl \x01\x1f del \x7f", "é — 😀 <&>  ", "bad \xff\xfe", "trail\n"} {
		var got bytes.Buffer
		writeSessionStart(&got, s)
		c := exec.Command("jq", "-n", "--arg", "c", s, `{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}`)
		want, err := c.Output()
		if err != nil {
			t.Fatal(err)
		}
		if got.String() != string(want) {
			t.Errorf("%q: got %q, jq %q", s, got.String(), want)
		}
	}
}

// legacy H4e: a stalled grandchild holding the output must not hold the hook past the bound, and nothing is left running.
func TestVerifyBoundStopsTheWholeGroup(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	w := newWorld(t, "stub")
	mark := filepath.Join(w.root, "grandchild-alive")
	script := "#!/usr/bin/env bash\n( sleep 1.5; : > " + mark + " ) &\nsleep 30\n"
	write(t, filepath.Join(w.tb, "install-verify-stub.sh"), script, 0o755)
	e := newEnvView(cli.Stdio{Environ: func() []string { return w.runEnv(nil) }})
	r := runVerify(e, filepath.Join(w.tb, "install-verify-stub.sh"), w.root, 1)
	if !r.timedOut || r.rc != 124 {
		t.Fatalf("timedOut=%v rc=%d, want a timeout (124)", r.timedOut, r.rc)
	}
	// the grandchild would write its marker 1.5 s after the start; the bound (1 s) killed its group first
	time.Sleep(2500 * time.Millisecond)
	if _, err := os.Stat(mark); err == nil {
		t.Error("the grandchild outlived the bound: the process group was not stopped")
	}
}

// legacy H4f: a real exit 137 (or 124) of the command is an exit code, not a timeout.
func TestRealExitCodesAreNotTimeouts(t *testing.T) {
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	for _, rc := range []string{"137", "124", "143"} {
		w := newWorld(t, "stub")
		write(t, filepath.Join(w.tb, "install-verify-stub.sh"), "#!/usr/bin/env bash\nexit "+rc+"\n", 0o755)
		e := newEnvView(cli.Stdio{Environ: func() []string { return w.runEnv(nil) }})
		r := runVerify(e, filepath.Join(w.tb, "install-verify-stub.sh"), w.root, 5)
		if r.timedOut || rc != strconv.Itoa(r.rc) {
			t.Errorf("exit %s: timedOut=%v rc=%d", rc, r.timedOut, r.rc)
		}
	}
}
