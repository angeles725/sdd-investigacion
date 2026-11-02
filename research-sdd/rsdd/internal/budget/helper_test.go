package budget

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// lib/session-budget-pi.mjs stays JavaScript (it loads TypeScript extensions through node), so Go execs it. Its
// own behaviour is pinned here, alone, without a sandbox: code points, status flags, final records, the
// injection routes it can and cannot measure, the per-handler wait and the names it reports.

func runHelper(t *testing.T, env []string, dir string, exts ...string) string {
	t.Helper()
	needTS(t)
	helper, err := filepath.Abs("../../../toolbelt/lib/session-budget-pi.mjs")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("node", append([]string{helper, dir}, exts...)...)
	cmd.Stdin = strings.NewReader("N\n")
	cmd.Env = append(os.Environ(), env...)
	var out bytes.Buffer
	cmd.Stdout = &out
	_ = cmd.Run()
	return strings.ReplaceAll(out.String(), "N\t", "")
}

func TestHelperAlone(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	emoji := write("a-emoji.ts", `export default (pi: any) => pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["emoji"] = "\u{1F600}".repeat(10); });`)
	pending := write("b-pending.ts", `export default (pi: any) => pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["p"] = "x sweeps pending (started now)"; });`)
	degraded := write("c-degraded.ts", `export default (pi: any) => pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["d"] = "hook DEGRADED: gone"; });`)
	silent := write("d-silent.ts", `export default (pi: any) => pi.on("before_agent_start", async () => {});`)
	throws := write("e-throws.ts", `export default (pi: any) => pi.on("before_agent_start", async () => { throw new Error("handler boom"); });`)
	r := runHelper(t, nil, dir, emoji, pending, degraded, silent, throws)
	for _, re := range []string{`^S\ta-emoji.ts\temoji\t10\tok$`, `^S\tb-pending.ts\tp\t[0-9]+\tpending$`, `^S\tc-degraded.ts\td\t[0-9]+\tdegraded-text$`,
		`^T\td-silent.ts\t0$`, `^E\te-throws.ts\tbefore_agent_start failed: handler boom`} {
		if !has(r, re) {
			t.Errorf("no record /%s/ (10 emoji are 10 code points, not 20 UTF-16 units; a throwing handler is E, not a zero) in\n%s", re, r)
		}
	}
	ls := lines(r)
	if finals := strings.Count(r, "\nT\t") + strings.Count(r, "\nE\t"); finals != 5 || ls[len(ls)-1] != "Z\t5" {
		t.Errorf("every extension gets exactly one T or E and the output ends with Z 5:\n%s", r)
	}

	fx := filepath.Join(fixturesRel, "pi-routes", ".pi", "extensions")
	r = runHelper(t, nil, dir, filepath.Join(fx, "msg.ts"), filepath.Join(fx, "sysprompt.ts"), filepath.Join(fx, "mutate.ts"))
	if !has(r, `^S\tmsg.ts\tmessage:note\t300\tok$`) {
		t.Errorf("a returned message's content is counted as a section:\n%s", r)
	}
	if !has(r, `^U\tsysprompt.ts\treturned systemPrompt`) || !has(r, `^U\tmutate.ts\tmutated event.systemPrompt`) || has(r, `^T\t(sysprompt|mutate).ts\t[1-9]`) {
		t.Errorf("a returned systemPrompt and an event.systemPrompt edit are typed U, never a 0-char success:\n%s", r)
	}

	r = runHelper(t, []string{"RSDD_BUDGET_PI_WAIT_MS=500"}, dir, filepath.Join(fixturesRel, "pi-hang", ".pi", "extensions", "hang.ts"), filepath.Join(fixturesRel, "pi-card", ".pi", "extensions", "card.ts"))
	if !has(r, `^E\thang.ts\tbefore_agent_start failed: timed out after 500ms`) || !has(r, `^S\tcard.ts\tcard-section\t2500\tok`) || !strings.HasSuffix(r, "Z\t2\n") {
		t.Errorf("a hanging handler yields ITS OWN E record after the per-handler wait; the next extension is still measured:\n%s", r)
	}

	sub := filepath.Join(fixturesRel, "pi-sub", ".pi", "extensions")
	r = runHelper(t, nil, sub, filepath.Join(sub, "index.ts"), filepath.Join(sub, "tools", "index.ts"))
	if !has(r, `^S\tindex.ts\tidx-root\t10`) || !has(r, `^S\ttools/index.ts\tidx-tools\t20`) {
		t.Errorf("extension names are paths below .pi/extensions:\n%s", r)
	}
}
