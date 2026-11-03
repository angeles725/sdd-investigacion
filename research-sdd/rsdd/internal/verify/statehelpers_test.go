//go:build unix

package verify

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/observed"
)

// Differential tests of the in-process replacements for the external tools the script shelled out to (xargs,
// jq, realpath), plus focused tests of the awk ports. A missing tool FAILS: a skipped differential proves
// nothing.

func need(t *testing.T, tool string) string {
	t.Helper()
	p, err := exec.LookPath(tool)
	if err != nil {
		t.Fatalf("%s is required by this differential test: %v", tool, err)
	}
	return p
}

func nonEmptyLines(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func TestXargsTokensMatchGNUXargs(t *testing.T) {
	need(t, "xargs")
	inputs := []string{
		"", " ", "a", "a b", "  a\tb\nc  ", `a "b c" d`, `a 'b c' d`, `a\ b`, `a\"b`, `"a"'b'c`, `''`, `""`, `a '' b`,
		`'g\h'`, `"g\h"`, `x "y`, `a b 'c d`, "a 'b\nc'", "a \"b\nc\"", `a\`, `\`, `\\`, `a\\b`, "a\\\nb", `bash "$CLAUDE_PROJECT_DIR/h h.sh"`,
		`env X=1 python3 tools/x.py --flag`, `a"b"c'd'e`, `é ü "ñ x"`, `-x --y z.sh`, `"a\"b"`, `'a'\''b'`, "a\x01b", "a\rb", "  \n\n ", "a\n\nb",
	}
	for _, in := range inputs {
		cmd := exec.Command("xargs", "-n1", "printf", "%s\n")
		cmd.Stdin = strings.NewReader(in)
		var out bytes.Buffer
		cmd.Stdout = &out
		_ = cmd.Run() // an unmatched quote makes xargs fail after the arguments before it
		var got strings.Builder
		for _, tok := range xargsTokens(in) {
			got.WriteString(tok + "\n")
		}
		if want, have := nonEmptyLines(out.String()), nonEmptyLines(got.String()); strings.Join(want, "\x00") != strings.Join(have, "\x00") {
			t.Errorf("xargs tokens of %q:\n  xargs %q\n     go %q", in, want, have)
		}
	}
}

func TestSettingsCommandsMatchJQ(t *testing.T) {
	jq := need(t, "jq")
	docs := []string{
		``, ` `, `null`, `{}`, `{"hooks":null}`, `{"hooks":false}`, `{"hooks":{}}`, `{"hooks":"x"}`, `{"hooks":[{"command":"a.sh"}]}`,
		`{"hooks":{"b":{"command":"B"},"a":{"command":"A","x":[{"command":"X"}]},"c":1}}`,
		`{"hooks":{"a":{"command":"a","command":"b"}}}`,
		`{"hooks":{"a":{"command":null},"b":{"command":false},"c":{"command":""},"d":{"command":0}}}`,
		`{"hooks":{"a":{"command":"x\ny"},"b":{"command":"\u00e9\t\"q\""}}}`,
		`{"hooks":{"a":{"command":["x","y"]},"b":{"command":true},"c":{"command":{"k":[1,{"z":null}],"e":[],"o":{}}}}}`,
		`{"hooks":{"a":{"command":"<&>"},"b":{"command":["<&>","\u007f"]}}}`,
		`{"hooks":`, `{"hooks":{"a":}`, `[1,2]`, `"str"`, `7`, `true`, `{"hooks":{}} {"hooks":{"a":{"command":"second.sh"}}}`, `{"hooks":{}} junk`, `{"a":1,}`, `{'a':1}`,
		"\xef\xbb\xbf" + `{"hooks":{"a":{"command":"bom.sh"}}}`, `{"hooks":{"a":{"command":"a"}}}` + "\n\n", `}`, `{"hooks":{"a":{"command":"a"}}`,
		`{"hooks":{"a":{"command":1.0},"b":{"command":[1.50,1e2]}}}`,
	}
	for _, doc := range docs {
		cmd := exec.Command(jq, "-r", `(.hooks // {}) | [.. | objects | .command? // empty] | .[]`)
		cmd.Stdin = strings.NewReader(doc)
		var out bytes.Buffer
		cmd.Stdout = &out
		jerr := cmd.Run()
		got, gerr := settingsCommands([]byte(doc))
		if (jerr != nil) != (gerr != nil) {
			t.Errorf("jq on %q: jq failed=%v, go failed=%v (%v)", doc, jerr != nil, gerr != nil, gerr)
			continue
		}
		if jerr == nil && cmdSubst(out.String()) != got {
			t.Errorf("jq on %q:\n  jq %q\n  go %q", doc, cmdSubst(out.String()), got)
		}
	}
}

func TestRealpathMatchesCoreutils(t *testing.T) {
	rp := need(t, "realpath")
	root := t.TempDir()
	mk := func(p, content string) {
		sdWrite(t, filepath.Join(root, p), content)
	}
	link := func(target, name string) {
		if err := os.Symlink(target, filepath.Join(root, name)); err != nil {
			t.Fatal(err)
		}
	}
	mk("a/file", "x")
	mk("a/b/deep", "x")
	link("a", "toa")
	link("a/b", "tob")
	link("../a/file", "a/rel")
	link(filepath.Join(root, "a", "file"), "abs")
	link("loop2", "loop1")
	link("loop1", "loop2")
	link("nowhere", "dangling")
	link("a/nowhere", "dangling-in-dir")
	link("a/file/x", "through-file")
	link(".", "dot")
	link("..", "dotdot")
	probes := []string{
		"a/file", "a/./file", "a/b/../file", "toa/file", "tob/deep", "tob/../file", "a/rel", "abs", "loop1", "dangling", "dangling-in-dir",
		"a/missing", "a/missing/x", "missing", "missing/x", "through-file", "a/file/", "a/file/x", "dot/a/file", "dotdot/" + filepath.Base(root) + "/a/file", ".", "a/..", "a/b/../..", "toa/../a", "toa/missing",
	}
	v := fsView{View: fsview.View{Cwd: root}}
	for _, p := range probes {
		for _, in := range []string{p, filepath.Join(root, p), filepath.Join(root, p) + "/"} {
			if strings.HasSuffix(in, "/") && in == filepath.Join(root, p)+"/" && strings.HasSuffix(p, "/") {
				continue
			}
			cmd := exec.Command(rp, "--", in)
			cmd.Dir = root
			var out bytes.Buffer
			cmd.Stdout = &out
			rerr := cmd.Run()
			got, ok := v.realpath(in)
			if (rerr == nil) != ok {
				t.Errorf("realpath %q: coreutils ok=%v, go ok=%v (%q)", in, rerr == nil, ok, got)
				continue
			}
			if ok && strings.TrimSuffix(out.String(), "\n") != got {
				t.Errorf("realpath %q: coreutils %q, go %q", in, strings.TrimSuffix(out.String(), "\n"), got)
			}
		}
	}
}

func TestChildGapNegationWindow(t *testing.T) {
	cases := []struct {
		line string
		open bool // an entry that carries needs: and is not closed counts
	}{
		{"- a CLOSED — needs: x", false},
		{"- a NOT CLOSED — needs: x", true},
		{"- a Not CLOSED needs: x", true},
		{"- a no longer closed needs: x", true},
		{"- a not yet CLOSED needs: x", true},
		{"- a no repro — CLOSED needs: x", false},
		{"- a not needed, CLOSED needs: x", false},
		{"- a NOT — CLOSED needs: x", true},
		{"- a NOT YET - CLOSED needs: x", true},
		{"- a X-NO CLOSED needs: x", false},
		{"- a CLOSED-LOOP needs: x", true},
		{"- a ENCLOSED needs: x", true},
		{"- a CLOSEDCLOSED needs: x", true},
		{"- a CERRADO needs: x", false},
		{"- a [Cerrado] needs: x", false},
		{"- ~~a~~ needs: x", false},
		{"- **~~a~~** needs: x", false},
		{"- a ~~partial~~ needs: x", true},
		{"- a ✅ needs: x", false},
		{"- a needs: x", true},
		{"- a no needs here", false},
	}
	for _, c := range cases {
		want := 0
		if c.open {
			want = 1
		}
		if got := childGapCount([]string{c.line}); got != want {
			t.Errorf("childGapCount(%q) = %d, want %d", c.line, got, want)
		}
	}
	// the needs: on a continuation line before the next bullet or blank counts once; a closed bullet hides it
	if got := childGapCount([]string{"- a", "  needs: x", "  needs: y", "", "- b CLOSED", "  needs: z", "- c", "  more", "  needs: w"}); got != 2 {
		t.Errorf("continuation lines: got %d, want 2", got)
	}
}

func TestArithSumIsBashArithmetic(t *testing.T) {
	if got := arithSum("1", "2", "010"); got != 11 {
		t.Errorf("1+2+010 = %d, want 11 (010 is octal)", got)
	}
	if got := arithSum("0", "00", "007"); got != 7 {
		t.Errorf("0+00+007 = %d, want 7", got)
	}
	defer func() {
		r := recover()
		if ab, ok := r.(arithAbort); !ok || ab.tok != "09" {
			t.Fatalf("recover() = %v, want an arithAbort for 09", r)
		}
	}()
	arithSum("1", "09")
}

func TestBacklogRowsStreamsAndWarnings(t *testing.T) {
	src := strings.Join([]string{
		"## Gap-backlog",
		"| Priority | Gap | Type | Status |",
		"|---|---|---|---|",
		"| High | one | w | **Pending** (x) |",
		"| high (ctx) | two | w | pending |",
		"| bogus | three | w | pending |",
		"| low | four | w | pending | extra |",
		"| deferred | five | w | parked |",
		"## Elsewhere",
		"| Priority | Gap | Type | Status |",
		"|---|---|---|---|",
		"| low | six | w | pending |",
		"",
	}, "\n")
	var errb bytes.Buffer
	got := backlogRows(src, &errb)
	if want := []string{"high\tone\tpending** (x)", "INVALID_PRIORITY\tbogus", "low\tsix\tpending"}; strings.Join(got.lines, "|") != strings.Join(want, "|") {
		t.Errorf("rows = %q, want %q", got.lines, want)
	}
	for _, w := range []string{
		"WARN: non-conforming qualifier priority [high (ctx)]",
		"backlog: unknown priority [bogus] in row: | bogus | three | w | pending |",
		"WARN: malformed backlog row (5 cells, expected 4 — a cell may contain a pipe): | low | four | w | pending | extra |",
		"WARN: 1 backlog-format row(s) outside ## Gap-backlog section",
	} {
		if !strings.Contains(errb.String(), w) {
			t.Errorf("stderr lacks %q:\n%s", w, errb.String())
		}
	}
}

func TestStateExitMapAndUsage(t *testing.T) {
	d := t.TempDir()
	sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdJoin("# s", "coverage metric: 1/1", sdEnvelope("covered_blocks", "0", "investigable_open", "0", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | g | w | pending |"))
	run := func(args ...string) (int, string, string) {
		var out, errb bytes.Buffer
		rc := cli.Run(Commands, append([]string{"verify", "state"}, args...), cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb,
			Env: func(string) string { return "" }, Environ: func() []string { return nil }, Clock: time.Now, Cwd: d})
		return rc, out.String(), errb.String()
	}
	if rc, out, _ := run(d); rc != 1 || !strings.Contains(out, "== exit 1 ==") || !strings.Contains(out, "FAIL") {
		t.Errorf("stale state: rc=%d out=%q, want the legacy exit 1 and a FAIL line", rc, out)
	}
	if rc, _, errs := run(); rc != 2 || errs != usageLine+"\n" {
		t.Errorf("no args: rc=%d stderr=%q, want 2 and the usage line", rc, errs)
	}
	if rc, out, _ := run(d, "--focus", "none"); rc != 2 || out != "" {
		t.Errorf("absent focus: rc=%d out=%q, want 2 and no report", rc, out)
	}
	dir := t.TempDir()
	if rc, _, errs := run(dir); rc != 2 || !strings.Contains(errs, "no RESEARCH-STATE*.md under "+dir) {
		t.Errorf("empty dir: rc=%d stderr=%q, want 2 and the absent-input message", rc, errs)
	}
}

func TestGapDriftDegradedWithoutToolbelt(t *testing.T) {
	d := t.TempDir()
	sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | B1-G1 text | w | pending |"))
	got := sdGo(t, d, false, d)
	if !strings.Contains(got.Stdout, "WARN   gap-drift: degraded — check-gap-drift.sh not found beside verify-state.sh") {
		t.Errorf("without RSDD_TOOLBELT_DIR the gap-drift check must say it did not run:\n%s", got.Stdout)
	}
}

// sdGoToolbelt runs the Go command with RSDD_TOOLBELT_DIR set to tb: the directory the shim hands over, where
// check-gap-drift.sh is looked for.
func sdGoToolbelt(t *testing.T, cwd, tb string, args ...string) observed.Run {
	t.Helper()
	env := append(sdEnviron(t.TempDir()), "RSDD_TOOLBELT_DIR="+tb)
	get := func(k string) string {
		for _, e := range env {
			if v, ok := strings.CutPrefix(e, k+"="); ok {
				return v
			}
		}
		return ""
	}
	var out, errb bytes.Buffer
	rc := RunState(args, cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: get, Environ: func() []string { return env },
		Clock: func() time.Time { return time.Time{} }, Cwd: cwd})
	if rc == Stale {
		rc = 1
	}
	return observed.New(out.String(), errb.String(), rc)
}

// TestGapDriftCheckerOutcomes pins how the report treats check-gap-drift.sh (kit #2457; these were the bash
// mutation controls vs-warn-lines, vs-missing-checker, vs-failed-checker, vs-untyped-exit1, vs-missing-helper and
// vs-rows-guard of check-gap-drift.test.sh, which mutated the verify-state.sh text before it became a shim).
func TestGapDriftCheckerOutcomes(t *testing.T) {
	withRows := sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | B1-G1 text | w | pending |")
	noRows := sdJoin(sdEnvelope("covered_blocks", "0", "investigable_open", "1", "blocked_open", "0"), "## Gap-backlog", sdTable4+"| high | plain gap | w | pending |")
	stub := func(t *testing.T, body string) string {
		tb := t.TempDir()
		sdWrite(t, filepath.Join(tb, "check-gap-drift.sh"), "#!/usr/bin/env bash\n"+body)
		return tb
	}
	realScriptOnly := func(t *testing.T) string { // the real checker without its lib/ helpers
		b, err := os.ReadFile(filepath.Join(sdLegacyDir(t), "check-gap-drift.sh"))
		if err != nil {
			t.Fatal(err)
		}
		tb := t.TempDir()
		sdWrite(t, filepath.Join(tb, "check-gap-drift.sh"), string(b))
		return tb
	}
	cases := []struct {
		name    string
		state   string
		tb      func(*testing.T) string
		want    []string
		notWant []string
	}{
		{"absent checker in a toolbelt dir", withRows, func(t *testing.T) string { return t.TempDir() },
			[]string{"WARN   gap-drift: degraded — check-gap-drift.sh not found beside verify-state.sh"}, nil},
		{"checker exit 2", withRows, func(t *testing.T) string { return stub(t, "echo boom >&2\nexit 2\n") },
			[]string{"WARN   gap-drift: degraded — check-gap-drift.sh failed (exit 2): boom"}, nil},
		{"checker exit 1 with no typed line", withRows, func(t *testing.T) string { return stub(t, "echo oops >&2\nexit 1\n") },
			[]string{"WARN   gap-drift: degraded — check-gap-drift.sh failed (exit 1): oops"}, nil},
		{"checker exit 1 with a typed DRIFT? line is a finding, not a failure", withRows, func(t *testing.T) string { return stub(t, "echo 'DRIFT? B1-G1 x'\nexit 1\n") },
			[]string{"WARN   gap-drift: DRIFT? B1-G1 x — copy the child-gap text verbatim from the block bullet (METHODOLOGY §7)"}, []string{"check-gap-drift.sh failed"}},
		{"UNPARSED line is relayed as a finding", withRows, func(t *testing.T) string { return stub(t, "echo 'UNPARSED B1-G1'\nexit 1\n") },
			[]string{"WARN   gap-drift: UNPARSED B1-G1 — copy the child-gap text verbatim from the block bullet (METHODOLOGY §7)"}, []string{"check-gap-drift.sh failed"}},
		{"DEGRADED line is relayed", withRows, func(t *testing.T) string { return stub(t, "echo 'DEGRADED no words'\nexit 0\n") },
			[]string{"WARN   gap-drift: DEGRADED no words"}, []string{"check-gap-drift.sh failed"}},
		{"checker present but its helper lib is missing", withRows, realScriptOnly,
			[]string{"WARN   gap-drift: degraded — check-gap-drift.sh failed (exit 2)"}, nil},
		{"no B<n>-G<m> rows: the checker is not consulted", noRows, func(t *testing.T) string { return t.TempDir() },
			nil, []string{"gap-drift"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := t.TempDir()
			sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), c.state)
			got := sdGoToolbelt(t, d, c.tb(t), d)
			for _, w := range c.want {
				if !strings.Contains(got.Stdout, w) {
					t.Errorf("missing %q in:\n%s", w, got.Stdout)
				}
			}
			for _, w := range c.notWant {
				if strings.Contains(got.Stdout, w) {
					t.Errorf("unexpected %q in:\n%s", w, got.Stdout)
				}
			}
		})
	}
}
