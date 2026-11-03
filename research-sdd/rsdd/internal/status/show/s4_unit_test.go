package show

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The cases the oracle cannot reach: a blocked-section read that fails (the script's rc 2 of is_blocked needs an
// extractor that cannot run), and the pure helpers at their edges.

func TestRetroFires(t *testing.T) {
	for in, want := range map[string]bool{
		"10": false, "11": true, "011": true, "010": false, "": false, "abc": false, "-3": false, "1 1": false, "1x": false,
		"9223372036854775807": true, "9223372036854775808": false, "0": false, "100": true,
	} {
		if got := retroFires(in); got != want {
			t.Errorf("retroFires(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestIsGapID(t *testing.T) {
	for in, want := range map[string]bool{
		"G1": true, "1": true, "a": true, "G1.2_x-y": true, "": false, "_G1": false, ".G1": false, "-G1": false, "G 1": false,
		"G*": false, "G1/": false, "é": false, "G1é": false, "G1\n": false,
	} {
		if got := isGapID(in); got != want {
			t.Errorf("isGapID(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestQueueMatches(t *testing.T) {
	for _, c := range []struct {
		lead, id string
		want     bool
	}{
		{"G1", "G1", true}, {"G1 first", "G1", true}, {"G1:x", "G1", true}, {"G1)", "G1", true}, {"G1é", "G1", true},
		{"G10", "G1", false}, {"G1-b", "G1", false}, {"G1.2", "G1", false}, {"G1_x", "G1", false}, {"G1a", "G1", false}, {"G1Z", "G1", false},
		{"g1", "G1", false}, {"XG1", "G1", false}, {"", "G1", false}, {"G", "G1", false}, {"G1", "G", false},
	} {
		if got := queueMatches(c.lead, c.id); got != c.want {
			t.Errorf("queueMatches(%q, %q) = %v, want %v", c.lead, c.id, got, c.want)
		}
	}
}

func TestStripMarks(t *testing.T) {
	for in, want := range map[string]string{
		"G1": "G1", "**G1": "G1", "~~G1": "G1", "`G1": "G1", "**~~G1": "G1", "~~**G1": "G1", "**`G1": "G1", "`**G1": "G1", "`~~**G1": "**G1",
		"**~~`G1": "G1", "**~~`**G1": "G1", "G1**": "G1**", "": "",
	} {
		if got := stripMarks(in); got != want {
			t.Errorf("stripMarks(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRelState(t *testing.T) {
	for _, c := range []struct{ target, in, want string }{
		{"corpus", "corpus/RESEARCH-STATE.md", "RESEARCH-STATE.md"},
		{"corpus/", "corpus/a/RESEARCH-STATE-x.md", "a/RESEARCH-STATE-x.md"},
		{"corpus//", "corpus//x.md", "x.md"},
		{"corpus//", "corpus/x.md", "corpus/x.md"},
		{"corpus", "other/x.md", "other/x.md"},
		{"corpus", "corpusx/x.md", "corpusx/x.md"},
		{"corpus", "corpus", "corpus"},
		{"/", "/x.md", "x.md"},
	} {
		c0 := &ctx{target: c.target}
		if got := c0.relState(c.in); got != c.want {
			t.Errorf("relState(target %q, %q) = %q, want %q", c.target, c.in, got, c.want)
		}
	}
}

func TestVerifyArgs(t *testing.T) {
	if got := strings.Join(verifyArgs("t"), " "); got != "t" {
		t.Errorf("no focus: %q", got)
	}
	if got := strings.Join(verifyArgs("t", "f"), " "); got != "t --focus f" {
		t.Errorf("focus: %q", got)
	}
}

// execVerify is the script's `"$here/verify-state.sh" args`: the exit code is the script's, and a helper that is not
// there is the shell's 127, one that cannot run 126.
func TestExecVerify(t *testing.T) {
	tb, cwd := t.TempDir(), t.TempDir()
	script := func(body string, mode os.FileMode) {
		t.Helper()
		p := filepath.Join(tb, "verify-state.sh")
		if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body), mode); err != nil || os.Chmod(p, mode) != nil {
			t.Fatal(err)
		}
	}
	run := func(dir string) (rc int, out, errb string) {
		var o, e strings.Builder
		s := stdio2(&o, &e, cwd, dir)
		return execVerify([]string{"t", "--focus", "x"}, s), o.String(), e.String()
	}
	if rc, out, errb := run(""); rc != 127 || out != "" || errb != "" {
		t.Errorf("no toolbelt dir: rc=%d out=%q err=%q", rc, out, errb)
	}
	if rc, _, _ := run(tb); rc != 127 {
		t.Errorf("no script: rc=%d, want 127", rc)
	}
	script("exit 0\n", 0o644)
	if rc, _, _ := run(tb); rc != 126 {
		t.Errorf("script without the execute bit: rc=%d, want 126", rc)
	}
	script("echo \"args=$*\"; echo \"cwd=$(pwd -P)\"; echo \"env=$S4_PROBE\"; echo oops >&2; exit 3\n", 0o755)
	wantCwd, _ := filepath.EvalSymlinks(cwd)
	rc, out, errb := run(tb)
	if rc != 3 || out != "args=t --focus x\ncwd="+wantCwd+"\nenv=probe\n" || errb != "oops\n" {
		t.Errorf("rc=%d out=%q err=%q", rc, out, errb)
	}
	script("exit 0\n", 0o755)
	if rc, _, _ := run(tb); rc != 0 {
		t.Errorf("exit 0: rc=%d", rc)
	}
	script("kill -9 $$\n", 0o755)
	if rc, _, _ := run(tb); rc != 128 {
		t.Errorf("killed by a signal: rc=%d, want 128", rc)
	}
}

// The extractor at its byte edges: the cut is at 160 bytes, backs off continuation bytes and never splits a rune.
func TestFirstFailureLineCut(t *testing.T) {
	hdr := "== verify-state: f (target: t) ==\n   FAIL   "
	for _, c := range []struct{ name, text, want string }{
		{"160 kept", strings.Repeat("b", 160), "f: " + strings.Repeat("b", 160)},
		{"161 cut", strings.Repeat("b", 161), "f: " + strings.Repeat("b", 157) + "..."},
		{"rune straddles", strings.Repeat("b", 156) + "€€€€", "f: " + strings.Repeat("b", 156) + "..."},
		{"0x80 continuation byte is backed off too", strings.Repeat("b", 156) + "ĀĀĀ", "f: " + strings.Repeat("b", 156) + "..."},
		{"0xBF continuation byte is backed off too", strings.Repeat("b", 156) + "¿¿¿", "f: " + strings.Repeat("b", 156) + "..."},
		{"rune ends at the cut", strings.Repeat("b", 154) + "€€€€", "f: " + strings.Repeat("b", 154) + "€..."},
		{"ascii after a rune", strings.Repeat("é", 78) + strings.Repeat("b", 10), "f: " + strings.Repeat("é", 78) + "b..."},
		{"only continuation bytes back off to the start, as the awk's n>0", strings.Repeat("\x80", 200), "f: ..."},
	} {
		if got := firstFailureLine(hdr + c.text + "\n"); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
	for _, c := range []struct{ name, report, want string }{
		{"empty", "", ""},
		{"header only", "== verify-state: f ==\n", ""},
		{"fail", "   FAIL   x\n", "?: x"},
		{"pending then value", "== verify-state: f (target: t) ==\n   FAIL   a:\n      v\n", "f: a: v"},
		{"pending at end", "== verify-state: f (target: t) ==\n   FAIL   a:\n", "f: a:"},
		{"pending then blank value", "   FAIL   a:\n\nx\n", "?: a: "},
		{"trailing newlines are dropped before the value line is looked for", "   FAIL   a:\n\n", "?: a:"},
		{"pending skips a header", "   FAIL   a:\n== verify-state: g (target: t) ==\n  v\n", "g: a: v"},
		{"non-fail lines are ignored", "WARN   x\n   FAIL   y\n", "?: y"},
		{"fail needs its three-space indent", "  FAIL   y\n", ""},
	} {
		if got := firstFailureLine(c.report); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

// _bu_compute: a file that cannot be counted is never a zero.
func TestBuCompute(t *testing.T) {
	root := t.TempDir()
	good := filepath.Join(root, "RESEARCH-STATE.md")
	one := strings.Replace(st4("", "0", 0, "", row("high", "done", "covered"), "| 1 | numbered | web | pending |"), "## Gap-backlog (prioritized)", "## Gap backlog", 1)
	two := strings.Replace(one, "| 1 | numbered", "| 2 | numbered two | web | pending |\n| 1 | numbered", 1)
	other := filepath.Join(root, "RESEARCH-STATE-b.md")
	for p, body := range map[string]string{good: one, other: two} {
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	s, _, _ := stdio(root)
	c := &ctx{s: s, target: root, state: "keep"}
	for _, tc := range []struct {
		files []string
		want  string
	}{
		{nil, ""},
		{[]string{good}, " [backlog-unreadable: 1 rows]"},
		{[]string{good, other}, " [backlog-unreadable: 3 rows]"},
		{[]string{good, filepath.Join(root, "missing.md")}, " [backlog-unreadable: unverified]"},
		{[]string{filepath.Join(root, "missing.md"), good}, " [backlog-unreadable: unverified]"},
		{[]string{filepath.Join(root, "missing.md")}, " [backlog-unreadable: unverified]"},
	} {
		c.buSuffix = "stale"
		c.buCompute(tc.files)
		if c.buSuffix != tc.want {
			t.Errorf("buCompute(%d files) = %q, want %q", len(tc.files), c.buSuffix, tc.want)
		}
		if c.state != "keep" {
			t.Errorf("buCompute left the state at %q", c.state)
		}
	}
}

// An unreadable blocked section is rc 2 of is_blocked: no gap is handed out, in the walk and in the queue, and the
// refusal is the DEGRADED line and exit 3. The state is consistent, so verify-state passes and the walk is reached.
func TestResolveDegradedIsFatal(t *testing.T) {
	root := t.TempDir()
	state := filepath.Join(root, "RESEARCH-STATE.md")
	text := st4("next_session_queue: G1, G9", "0", -1, "", row("high", "G1 first gap", "pending"), row("low", "G2 second", "pending"))
	if err := os.WriteFile(state, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	s, _, _ := stdio(root)
	c := &ctx{s: s, target: root, state: state}
	const rel = "RESEARCH-STATE.md"
	wantDeg := "DEGRADED | blocked-rows read failed while resolving G1 first gap in " + rel + " — no gap is handed out; fix the failure named on stderr, then re-run"
	if out, rc := c.resolveNextWith(func(string) int { return 2 }); rc != 3 || out != wantDeg {
		t.Errorf("walk: rc=%d out=%q", rc, out)
	}
	if out, rc := c.resolveNextWith(func(g string) int { return map[bool]int{true: 0, false: 1}[g == "G1 first gap"] }); rc != 0 || out != "NEXT | low | G2 second" {
		t.Errorf("walk past a blocked gap: rc=%d out=%q", rc, out)
	}
	if out, rc := c.resolveNextWith(func(string) int { return 0 }); rc != 0 || out != stopExhausted {
		t.Errorf("walk, all blocked: rc=%d out=%q", rc, out)
	}
	if out, rc := c.resolveNextWith(func(string) int { return 7 }); rc != 3 || out != wantDeg {
		t.Errorf("any rc above 1 is degraded: rc=%d out=%q", rc, out)
	}
	c.opts.queue = true
	var errb strings.Builder
	c.s.Err = &errb
	if out, rc := c.resolveNextQWith(func(string) int { return 2 }); rc != 3 || out != wantDeg {
		t.Errorf("queue: rc=%d out=%q", rc, out)
	}
	if strings.Contains(errb.String(), "queue-unknown-gap") {
		t.Errorf("a degraded queue read must stop at once, stderr: %q", errb.String())
	}
	if out, rc := c.resolveNextQWith(func(string) int { return 1 }); rc != 0 || out != "NEXT | high | G1 first gap" || !strings.Contains(errb.String(), "queue-unknown-gap [root]: queued id [G9] (position 2)") {
		t.Errorf("queue serves: rc=%d out=%q stderr=%q", rc, out, errb.String())
	}
}

// The DEGRADED refusals of the --next block itself, through the real run with the is_blocked read replaced.
func TestNextDegradedRefusals(t *testing.T) {
	verifyWith(t, 0, "")
	two := files{
		"corpus/RESEARCH-STATE.md":     st4("", "0", -1, "", row("high", "G1 first gap", "pending")),
		"corpus/RESEARCH-STATE-old.md": st4("", "0", -1, "", row("high", "O1 old gap", "pending")),
		"corpus/FOCUSES.md":            focusRows("old", "stopped"),
	}
	for _, c := range []struct {
		name  string
		flags []string
		files files
		want  string
	}{
		{"unscoped walk", nil, merge(two, files{"corpus/FOCUSES.md": focusRows("old", "open")}),
			"DEGRADED | blocked-rows read failed while resolving O1 old gap in RESEARCH-STATE-old.md — no gap is handed out; fix the failure named on stderr, then re-run\n"},
		{"scoped walk", []string{"--root"}, two,
			"DEGRADED | blocked-rows read failed while resolving G1 first gap in RESEARCH-STATE.md — no gap is handed out; fix the failure named on stderr, then re-run\n"},
		{"stopped focus count", nil, two,
			"DEGRADED | blocked-rows read failed while counting the paused/stopped focus RESEARCH-STATE-old.md — the no-active-focus count would be inflated; fix the failure named on stderr, then re-run\n"},
		{"queue never falls back", []string{"--queue"}, files{"corpus/RESEARCH-STATE.md": st4("next_session_queue: G1", "0", -1, "", row("high", "G1 first gap", "pending"))},
			"DEGRADED | blocked-rows read failed while resolving G1 first gap in RESEARCH-STATE.md — no gap is handed out; fix the failure named on stderr, then re-run\n"},
	} {
		sc := m4(c.name, "", c.files, append([]string{}, c.flags...)...)
		root := sc.build(t)
		s, out, _ := stdio(root)
		s.Cwd = root
		rc := run(sc.argv(0, root), s, func(cx *ctx) int {
			cx.blockedHook = func(string) int { return 2 }
			return nextOr(s4Seams, s4Tail)(cx)
		})
		if got := strings.ReplaceAll(out.String(), root, "<ROOT>"); rc != 3 || got != c.want {
			t.Errorf("%s: rc=%d stdout=%q", c.name, rc, got)
		}
	}
}

// A seam that is not ready ends the run as not yet ported and prints nothing on stdout, in each of its three call
// sites (the retro derivation, the scoped gate, the aggregate gate).
func TestNextSeamNotReady(t *testing.T) {
	verifyWith(t, 0, "")
	for _, c := range []struct {
		name, state string
		flags       []string
		want        string
	}{
		{"retro", one("root", "pending", 1, "11"), nil, "RETRO-DUE covers_through derivation"},
		{"gate scoped", one("root", "covered", 0, "0"), []string{"--root"}, "issues_due_gate"},
		{"gate aggregate", one("root", "covered", 0, "0"), nil, "issues_due_gate"},
	} {
		sc := n4(c.name, "", c.state, nil, c.flags...)
		root := sc.build(t)
		s, out, errb := stdio(root)
		s.Cwd = root
		rc := run(sc.argv(0, root), s, nextOr(pendingSeams, s4Tail))
		if want := "rsdd: status show: not-yet-ported: " + c.want + " of --next; use toolbelt/research-sdd-status.sh (issue #2549)\n"; rc != 1 || out.Len() != 0 || errb.String() != want {
			t.Errorf("%s: rc=%d stdout=%q stderr=%q", c.name, rc, out.String(), errb.String())
		}
	}
}

// stdio2 is a Stdio for execVerify: the toolbelt directory the shim would hand over and an environment of its own.
func stdio2(o, e io.Writer, cwd, toolbelt string) cli.Stdio {
	return cli.Stdio{Out: o, Err: e, Cwd: cwd,
		Env:     func(k string) string { return map[string]string{"RSDD_TOOLBELT_DIR": toolbelt}[k] },
		Environ: func() []string { return []string{"S4_PROBE=probe", "PATH=" + os.Getenv("PATH")} }}
}
