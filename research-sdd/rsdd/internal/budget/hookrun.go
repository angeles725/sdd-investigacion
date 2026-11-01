package budget

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Running one hook: in the sandbox, with a minimal SessionStart payload for ITS source on stdin and CLAUDE_PROJECT_DIR=<target>,
// under `timeout -k 2 <effective cap>`. The effective cap is the hook's own `timeout` (default 600 s) limited to the script cap
// (RSDD_BUDGET_HOOK_TIMEOUT, default 60 s): a hook that outlives ITS OWN timeout is killed by Claude Code too and contributes
// nothing (timed-out, counted as 0 and on the state line); one that only outlives the script cap is degraded, never 0.

type hookKind int

const (
	kindDegraded hookKind = iota // not measurable: never counted
	kindOK
	kindTruncated
	kindTimedOut // outlived its own timeout: counts 0, typed
)

// hookResult is one hook run: the status text of its report line, its characters, and how to count it.
type hookResult struct {
	status string
	chars  int
	kind   hookKind
}

// probe is the state shared by every hook run of one Claude-harness report.
type probe struct {
	e         env
	target    string
	toCap     string // RSDD_BUDGET_HOOK_TIMEOUT, validated
	work      string
	jq        string
	timeout   string
	reason    string // sandbox unusable ("" = usable)
	utf8OK    bool
	sbClaude  string // throwaway copy of <target>/.claude
	sbTmp     string // fresh TMPDIR
	copyFail  string
	capped    []string // commands that hit the SCRIPT's cap: not run again in later sources
	outFile   string
	startJSON string
}

// prepSandbox makes the throwaway copy and TMPDIR afresh (measurements are order-independent).
func (p *probe) prepSandbox() {
	freshDirs(p.sbClaude, p.sbTmp)
	p.copyFail = ""
	if isDir(filepath.Join(p.target, ".claude")) {
		p.copyFail = p.e.copyClaude(p.target, p.sbClaude)
	}
}

// effectiveCap is the cap handed to timeout: the declared timeout (digits only, else 600) limited to [1, script cap].
func (p *probe) effectiveCap(decl string) string {
	eff := decl
	if eff == "" {
		eff = "600"
	}
	if cmpDec(eff, p.toCap) > 0 {
		eff = p.toCap
	}
	if cmpDec(eff, "1") < 0 {
		eff = "1"
	}
	return eff
}

// bwrapArgs is the sandbox argv of one hook run (everything between `timeout -k 2 N` and the hook command).
func (p *probe) bwrapArgs() []string {
	a := []string{"bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
		"--bind", p.sbClaude, filepath.Join(p.target, ".claude"), "--bind", p.sbTmp, p.sbTmp,
		"--setenv", "TMPDIR", p.sbTmp, "--setenv", "CLAUDE_PROJECT_DIR", p.target}
	for _, v := range unsetVars {
		a = append(a, "--unsetenv", v)
	}
	a = append(a, namespaceFlags...)
	return append(a, "--chdir", p.target)
}

// run measures one hook for one source.
func (p *probe) run(src, cmd, decl string) hookResult {
	deg := func(format string, a ...any) hookResult {
		return hookResult{status: fmt.Sprintf(format, a...), kind: kindDegraded}
	}
	if p.reason != "" {
		return deg("degraded(no-sandbox: %s)", p.reason)
	}
	if p.copyFail != "" {
		return deg("degraded(incomplete-sandbox-copy: %s)", p.copyFail)
	}
	for _, c := range p.capped {
		if c == cmd {
			return deg("degraded(timeout, not re-run: hit the %ss script cap in an earlier source)", p.toCap)
		}
	}
	if !onlyDigits(decl) {
		decl = ""
	}
	eff := p.effectiveCap(decl)
	out, err := os.Create(p.outFile)
	if err != nil {
		return deg("degraded(exit 1)")
	}
	defer out.Close()
	payload := fmt.Sprintf(`{"session_id":"budget-probe","hook_event_name":"SessionStart","source":"%s","cwd":"%s"}`, src, p.target)
	args := append([]string{"-k", "2", eff}, p.bwrapArgs()...)
	c := p.e.cmd(p.timeout, append(args, "bash", "-c", cmd)...)
	c.Stdin, c.Stdout = strings.NewReader(payload), out
	rc := exitCode(c.Run())
	if rc == 124 || rc == 137 {
		if decl != "" && cmpDec(decl, p.toCap) <= 0 {
			return hookResult{status: fmt.Sprintf("timed-out(hook timeout %ss)", decl), kind: kindTimedOut}
		}
		p.capped = append(p.capped, cmd)
		allows := decl
		if allows == "" {
			allows = "600"
		}
		return deg("degraded(timeout %ss: this script's cap; the hook allows %ss)", eff, allows)
	} else if rc != 0 {
		return deg("degraded(exit %d)", rc)
	}
	m, why := p.e.measureFile(p.jq, p.utf8OK, p.outFile)
	if why != "" {
		return deg("degraded(%s)", why)
	}
	if m.truncated {
		return hookResult{status: "TRUNCATED", chars: m.chars(), kind: kindTruncated}
	}
	return hookResult{status: "ok", chars: m.chars(), kind: kindOK}
}
