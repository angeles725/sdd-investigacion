package show

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The S2 harness: scenarios over one state file (plus optional extra files), each with a list of ops. An op is a
// function of the frozen script (backlog_rows, count_investigable, ...) with its arguments; the differential test
// runs the op list in one bash process over the frozen excerpts, the replay test runs it through the Go port. Both
// produce the same rendering, which is the golden.

const goldenS2Dir = "testdata/golden/"

// op is one function call: name and arguments ("{ROOT}" is the world root).
type op []string

func o(args ...string) op { return op(args) }

type s2Scenario struct {
	name       string
	state      string
	extra      map[string]string // files relative to the world root (corpus/...)
	ops        []op
	unreadable bool // the state file is mode 000: skipped as root
}

// stateRel is where the state file lives in every world.
const stateRel = "corpus/RESEARCH-STATE.md"

func (sc s2Scenario) build(t testing.TB) string {
	t.Helper()
	root := t.TempDir()
	write := func(rel, body string) {
		full := filepath.Join(root, rel)
		must(t, os.MkdirAll(filepath.Dir(full), 0o755))
		must(t, os.WriteFile(full, []byte(body), 0o644))
	}
	write(stateRel, sc.state)
	for p, body := range sc.extra {
		write(p, body)
	}
	if sc.unreadable {
		must(t, os.Chmod(filepath.Join(root, stateRel), 0))
	}
	return root
}

func (op op) line(root string) string {
	parts := make([]string, len(op))
	for i, a := range op {
		parts[i] = shq(strings.ReplaceAll(a, "{ROOT}", root))
	}
	return strings.Join(parts, " ")
}

// shq single-quotes a word for bash.
func shq(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// runGoOps runs every op of sc through the Go port, each on its own ctx (the focus cache is per process in bash).
func runGoOps(t testing.TB, sc s2Scenario, root string) []outcome {
	t.Helper()
	var res []outcome
	for _, op := range sc.ops {
		args := make([]string, len(op))
		for i, a := range op {
			args[i] = strings.ReplaceAll(a, "{ROOT}", root)
		}
		var out, errb bytes.Buffer
		s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: func(string) string { return "" },
			Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: root}
		c := &ctx{s: s, target: filepath.Join(root, "corpus"), state: filepath.Join(root, stateRel), corpus: filepath.Join(root, "corpus")}
		rc := c.runOp(args)
		res = append(res, outcome{rc, out.String(), errb.String()})
	}
	return res
}

// renderS2 is the golden section of one scenario.
func renderS2(sc s2Scenario, outs []outcome, root string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "=== %s\n", sc.name)
	for i, op := range sc.ops {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(render("op "+op.line("<ROOT>"), outs[i], root)[len("=== "):])
	}
	return b.String()
}

// parseGoldenS2 splits a golden file into sections by scenario name.
func parseGoldenS2(t testing.TB, path string) map[string]string { return parseGolden(t, path) }

// op dispatch of the Go port (names are the functions of the frozen script).
func (c *ctx) runOp(args []string) int {
	text := c.stateText()
	arg := func(i int) string {
		if i < len(args) {
			return args[i]
		}
		return ""
	}
	p := func(s string) { fmt.Fprint(c.s.Out, s) }
	num := func(n int) { fmt.Fprintf(c.s.Out, "%d\n", n) }
	switch args[0] {
	case "backlog_rows":
		out, warn := backlogRows(text, arg(1) != "" && arg(1) != "0")
		p(out)
		fmt.Fprint(c.s.Err, warn)
		return 0
	case "deferred_scan":
		out, warn := deferredScan(text, arg(1) != "0")
		p(out)
		fmt.Fprint(c.s.Err, warn)
		return 0
	case "count_deferred":
		p(c.countDeferred())
		return 0
	case "count_investigable":
		n, rc := c.countInvestigable()
		num(n)
		return rc
	case "count_retyped_in_table":
		num(c.countRetyped())
		return 0
	case "warn_inplace_blocked":
		var n int
		fmt.Sscanf(arg(2), "%d", &n)
		c.warnInplaceBlocked(arg(1), n)
		return 0
	case "count_requires_execution":
		num(c.countRequiresExecution())
		return 0
	case "count_all_known_gaps":
		n := c.countAllKnownGaps()
		num(n)
		return b2rc(n == 0)
	case "count_uncounted_rows":
		n := c.countUncountedRows()
		num(n)
		return b2rc(n == 0)
	case "count_attributed_sg":
		num(c.countAttributedSG())
		return 0
	case "req_prose":
		v := c.reqProse()
		if v != "" {
			p(v + "\n")
		}
		return b2rc(v == "")
	case "env_get":
		if v, ok := c.envGet(arg(1)); ok {
			p(v + "\n")
		}
		return 0
	case "env_raw":
		v, ok := c.envRaw(arg(1))
		if ok {
			p(v + "\n")
		}
		return b2rc(!ok)
	case "cov_ratio":
		p(c.covRatioOf() + "\n")
		return 0
	case "pick":
		p(pick(arg(1), arg(2)) + "\n")
		return 0
	case "section":
		p(sectionBody(text, arg(1)))
		return 0
	case "stopctl":
		p(c.stopctl())
		return 0
	case "_read_focuses_tok_uncached":
		if !c.isFile(arg(1)) {
			return 1
		}
		if t := c.focusTokUncached(arg(1), arg(2)); t != "" {
			p(t + "\n")
		}
		return 0
	case "__into_twice":
		v := c.focusTokCached(arg(1), arg(2))
		w := c.focusTokCached(arg(1), arg(2))
		p(fmt.Sprintf("v=%s w=%s\n", v, w))
		return 0
	case "__inplace":
		n, rc := c.inplaceBlocked()
		num(n)
		return rc
	}
	panic("unknown op " + args[0])
}

func b2rc(b bool) int {
	if b {
		return 1
	}
	return 0
}
