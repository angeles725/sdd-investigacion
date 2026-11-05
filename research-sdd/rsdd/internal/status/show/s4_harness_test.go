package show

import (
	"bytes"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The S4 harness: full `research-sdd-status.sh <target> --next ...` invocations over crafted corpora. As in S3, the
// rendering is the golden: every invocation's rc, stdout and stderr, then the tree the runs left behind (--next
// must not write). The two sections of the script that belong to slice S5 (the retro-coverage derivation of
// RETRO-DUE and issues_due_gate) are replaced by the same authored stand-in on both sides, so the golden pins
// everything the verdict does around them.

const goldenS4 = goldenS2Dir + "s4.golden"

// fakeVerify makes verify-state answer a fixed report and exit code on both sides: the cases that feed the first
// failure extractor shapes a real verify-state does not produce on demand.
type fakeVerify struct {
	out string
	rc  int
}

type s4Scenario struct {
	s3Scenario
	fake *fakeVerify
	want string // the stdout of the first run starts with this; the guard that a scenario really reaches its verdict
}

// n4 is the one-state-file scenario: corpus/RESEARCH-STATE.md plus extra files, one run of `--next flags...`.
func n4(name, want, state string, extra files, flags ...string) s4Scenario {
	return m4(name, want, merge(files{stateRel: state}, extra), flags...)
}

// m4 is a scenario over an arbitrary file set (the target is {ROOT}/corpus).
func m4(name, want string, f files, flags ...string) s4Scenario {
	return s4Scenario{
		s3Scenario: s3Scenario{name: name, files: f, runs: [][]string{append([]string{"{ROOT}/corpus", "--next"}, flags...)}},
		want:       want,
	}
}

// s4Seams are the stand-ins for the S5 sections: the declared counter is kept, and the gate prints the STOP line
// every exhausted run ends in (the script's own `_stop_exhausted`).
var s4Seams = seams{
	coversDerive: func(_ *ctx, _, declared string) (string, string) { return declared, "" },
	issuesGate:   func(c *ctx) { fmt.Fprintf(c.s.Out, "%s%s\n", stopExhausted, c.buSuffix) },
}

func s4Tail(c *ctx) int {
	fmt.Fprintf(c.s.Out, "S4-TAIL mode=%s\n", c.opts.mode)
	return 0
}

// ---- verify-state: recorded calls -----------------------------------------------------------------------------

// verifyCall is one run of verify-state: its argv, stdout and exit code, with the world root written <ROOT>. The
// golden records the calls the frozen script made; the replay answers the port's calls from that record, in order,
// so the golden pins both what verify-state said and when, and with what, the port asked it.
type verifyCall struct {
	args []string
	out  string
	rc   int
}

// s4Env is how one side of a scenario reaches verify-state.
type s4Env struct {
	verify  func(args []string, s cli.Stdio) int // nil: the production exec of verify-state.sh
	env     func(key string) string
	environ func() []string
}

// replayEnv answers the port's verify-state calls from the golden's record and notes what was asked in got.
func replayEnv(want []verifyCall, root string, got *[]verifyCall) s4Env {
	return s4Env{
		env: func(string) string { return "" },
		verify: func(args []string, s cli.Stdio) int {
			served := verifyCall{out: "(no recorded call)", rc: 99}
			if i := len(*got); i < len(want) {
				served = want[i]
			}
			asked := make([]string, len(args))
			for i, a := range args {
				asked[i] = strings.ReplaceAll(a, root, "<ROOT>")
			}
			*got = append(*got, verifyCall{asked, served.out, served.rc})
			_, _ = io.WriteString(s.Out, strings.ReplaceAll(served.out, "<ROOT>", root))
			return served.rc
		},
	}
}

func runGoS4(t testing.TB, sc s4Scenario, root string, e s4Env) []outcome {
	t.Helper()
	if e.verify != nil {
		old := verifyState
		defer func() { verifyState = old }()
		verifyState = e.verify
	}
	var res []outcome
	for i := range sc.runs {
		var out, errb bytes.Buffer
		s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: e.env, Environ: e.environ,
			Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: filepath.Join(root, sc.cwd)}
		rc := run(sc.argv(i, root), s, syncOr(nextOr(s4Seams, s4Tail)))
		res = append(res, outcome{rc, out.String(), errb.String()})
	}
	return res
}

// ---- world builders ----------------------------------------------------------------------------------------

// st4 is a derived-consistent state file: the envelope and the Stop control section carry inv (the investigable
// count; -1 counts the rows that start `pending`), bsr is blocks_since_retro ("" omits it), hdr is raw header
// text before the envelope, extra is appended after the Stop control section.
func st4(hdr, bsr string, inv int, extra string, rows ...string) string {
	if inv < 0 {
		inv = 0
		for _, r := range rows {
			cells := strings.Split(r, "|")
			if len(cells) > 4 && strings.HasPrefix(strings.TrimSpace(cells[4]), "pending") {
				inv++
			}
		}
	}
	var b strings.Builder
	b.WriteString("# S — Research State\n\n")
	if hdr != "" {
		b.WriteString(hdr + "\n\n")
	}
	fmt.Fprintf(&b, "<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: %d\nrequires_execution_open: 0\nblocked_open: 0\n", inv)
	if bsr != "" {
		fmt.Fprintf(&b, "blocks_since_retro: %s\n", bsr)
	}
	b.WriteString("<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n")
	for _, r := range rows {
		b.WriteString(r + "\n")
	}
	fmt.Fprintf(&b, "\n## Stop control\n\n- **Open gaps — read-only investigable**: %d\n- **Open gaps — requires-execution**: 0\n- **Open gaps — blocked**: 0\n", inv)
	b.WriteString(extra)
	return b.String()
}

// row is a backlog table row.
func row(prio, gap, status string) string {
	return "| " + prio + " | " + gap + " | web | " + status + " |"
}

// one is the state of the scope fixtures: ONE high gap named after the file, with the given status.
func one(name, status string, inv int, bsr string) string {
	return st4("", bsr, inv, "", row("high", "the "+name+" gap", status))
}

// legacy is the broken sibling of kit #1543: a frozen envelope and an unknown priority token.
func legacy(heading string) string {
	return "# L — Research State\n\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 266\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n\n" +
		heading + "\n\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n| SES2 | the legacy gap | web | pending |\n"
}

// ---- the golden section ---------------------------------------------------------------------------------------

// A first-failure pointer is cut at 160 bytes, and verify-state's own text can carry the world root
// (`run: research-sdd-status.sh <target> --sync-state`): where the cut falls depends on the length of the root,
// which depends on the temp directory and the test that built the world. The path and what follows it, inside the
// pointer, are therefore not part of the rendering.
var cutRoot = regexp.MustCompile(`(\[first failure: [^\]\n]*research-sdd-status\.sh )[^\]\n]*\]`)

// renderS4 is the golden section of one scenario: the S3 rendering (every run, then the tree) and the verify-state
// calls of the runs.
func renderS4(t testing.TB, sc s4Scenario, outs []outcome, root string, calls []verifyCall) string {
	var b strings.Builder
	b.WriteString(cutRoot.ReplaceAllString(renderS3(t, sc.s3Scenario, outs, root), "${1}<ROOT>]"))
	b.WriteString("--- verify\n")
	for i, c := range calls {
		if strings.ContainsAny(strings.Join(c.args, ""), " \n") {
			t.Fatalf("a verify-state argument holds a blank: %q", c.args)
		}
		fmt.Fprintf(&b, "call %d: %s\nrc: %d\nout: %s\n", i+1, strings.Join(c.args, " "), c.rc, strconv.Quote(c.out))
	}
	b.WriteString("--- end verify\n")
	return b.String()
}

// parseVerifyBlock reads back the calls of a golden section.
func parseVerifyBlock(t testing.TB, section string) []verifyCall {
	t.Helper()
	i := strings.LastIndex(section, "--- verify\n")
	if i < 0 {
		t.Fatalf("no verify block in the golden section:\n%s", section)
	}
	blk, _, _ := strings.Cut(section[i+len("--- verify\n"):], "--- end verify\n")
	lines := splitLines(blk)
	var calls []verifyCall
	for k := 0; k+2 < len(lines); k += 3 {
		_, args, _ := strings.Cut(lines[k], ": ")
		var c verifyCall
		c.args = strings.Split(args, " ")
		if _, err := fmt.Sscanf(lines[k+1], "rc: %d", &c.rc); err != nil {
			t.Fatalf("verify block rc line %q: %v", lines[k+1], err)
		}
		out, err := strconv.Unquote(strings.TrimPrefix(lines[k+2], "out: "))
		if err != nil {
			t.Fatalf("verify block out line %q: %v", lines[k+2], err)
		}
		c.out = out
		calls = append(calls, c)
	}
	return calls
}

// focusRows is a FOCUSES.md with one row per (slug, status) pair.
func focusRows(pairs ...string) string {
	var b strings.Builder
	b.WriteString("| focus | status |\n|---|---|\n")
	for i := 0; i+1 < len(pairs); i += 2 {
		fmt.Fprintf(&b, "| %s | %s |\n", pairs[i], pairs[i+1])
	}
	return b.String()
}
