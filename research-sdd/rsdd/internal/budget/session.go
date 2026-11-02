// Package budget owns the rsdd commands for session-context budget measurement.
//
// session.go is the port of research-sdd/toolbelt/verify-session-budget.sh (kit issues #2129 and #2174):
//
//	rsdd budget session [--toolbelt DIR] [--harness claude|pi|both] <target-dir>
//
// It measures what a target's SessionStart hooks (Claude Code) or its pi / gentle-shell extensions hand to the
// model, against the 10,000-character per-field cap and the kit's < 8,000-character budget. Hooks are run in a
// bubblewrap sandbox, never against the live tree. The bash shim passes `--toolbelt <its own directory>`: the
// pi helper lib/session-budget-pi.mjs (JavaScript on purpose: it loads TypeScript extensions through node) and
// the default kit are found from it; run directly, the toolbelt is the one of the resolved kit (core/kit).
// The legacy output, exit codes and typed states are reproduced byte for byte; testdata/legacy holds the frozen
// script and differential_test.go compares the two over hand-built targets.
//
// Deliberate differences from the script, each pinned by a test (settings_test.go, count_test.go,
// session_test.go):
//
//   - jq is not needed: settings.json and the hook output are parsed in Go, so the script's
//     `state: degraded (jq unavailable; no hook was run)` has no equivalent.
//   - The characters of a plain-text hook are counted in Go (code points; bytes that are not valid UTF-8 are not
//     counted, as `wc -m` does), so the script's locale probe and its `degraded(no-utf8-locale ...)` do not exist.
//   - settings.json must be exactly one JSON object (the script's jq judged the last of a stream of values), and a
//     hook whose stdout is several concatenated JSON values is counted as plain text.
//   - A SessionStart or hooks value that is not an array selects nothing (jq iterated the values of an object).
//   - Matcher regular expressions use Go's RE2, not jq's Oniguruma: ordinary patterns agree, lookaround does not
//     compile here and degrades the run. The text after "cannot select SessionStart hooks for source <s>: " is
//     this program's own error text, not jq's.
//   - A non-string additionalContext or systemMessage is measured as compact JSON with the number's source
//     spelling kept (jq writes 1E2 as 1E+2); a JSON stdout with a lone-surrogate escape, which jq rejects, is
//     decoded with U+FFFD instead of being counted as plain text.
//   - A hookSpecificOutput that is not an object counts 0 without the script's stray `[: integer expression
//     expected` line on stderr.
//   - A timeout or settings value written with a leading zero is read as decimal; a number too large for int is
//     ignored (the script's bash arithmetic would have failed).
//   - `mktemp`'s own complaint on stderr when the temp dir cannot be created is not reproduced; the typed
//     `state: degraded (cannot create a temp dir)` line on stdout is.
//   - The glob order of .claude entries is bytewise (the script's followed the caller's collation).
//
// See docs/adding-a-command.md.
package budget

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

const (
	hookCap     = 10000 // characters Claude Code keeps of one hook field
	sessionCap  = 8000  // the kit budget for SessionStart in total
	usageLine   = "usage: verify-session-budget.sh [--harness claude|pi|both] <target-dir>"
	defaultHook = 60
)

// RunSession is the `budget session` command.
func RunSession(args []string, s cli.Stdio) int {
	toolbelt := ""
	if len(args) >= 2 && args[0] == "--toolbelt" {
		toolbelt, args = args[1], args[2:]
	}
	harness := "claude"
	if len(args) > 0 && args[0] == "--harness" {
		v := ""
		if len(args) > 1 {
			v = args[1]
		}
		switch v {
		case "claude", "pi", "both":
			harness, args = v, args[2:]
		default:
			fmt.Fprintln(s.Err, usageLine)
			return cli.ExitUsage
		}
	}
	if len(args) != 1 || args[0] == "" {
		fmt.Fprintln(s.Err, usageLine)
		return cli.ExitUsage
	}
	dir := args[0]
	if !filepath.IsAbs(dir) {
		dir = filepath.Join(s.Cwd, dir)
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		fmt.Fprintln(s.Err, usageLine)
		return cli.ExitUsage
	}
	target, err := filepath.EvalSymlinks(dir)
	if err != nil {
		fmt.Fprintln(s.Err, usageLine)
		return cli.ExitUsage
	}
	m := &meter{env: env{s}, out: s.Out, target: target, toolbelt: toolbelt}
	m.toCap = defaultHook
	if v := s.Env("RSDD_BUDGET_HOOK_TIMEOUT"); allDigits(v) && v != "0" {
		if n, ok := atoiOr(v); ok {
			m.toCap = n
		}
	}
	switch harness {
	case "both":
		m.claude()
		m.pi()
	case "pi":
		m.pi()
	default:
		m.claude()
	}
	return cli.ExitOK
}

// meter is one measurement run.
type meter struct {
	env
	out      io.Writer
	target   string
	toolbelt string
	toCap    int
}

func (m *meter) say(format string, a ...any) { fmt.Fprintf(m.out, format+"\n", a...) }

func verdict(total int) string {
	if total >= sessionCap {
		return "OVER BUDGET"
	}
	return "OK"
}

// tmpRoot is where `mktemp -d` puts a directory: $TMPDIR, else /tmp.
func (m *meter) tmpRoot() string {
	if t := m.s.Env("TMPDIR"); t != "" {
		return t
	}
	return "/tmp"
}

// toolbeltDir is the directory holding lib/session-budget-pi.mjs: the flag, else the resolved kit's.
func (m *meter) toolbeltDir() string {
	if m.toolbelt != "" {
		return m.toolbelt
	}
	if p, _, err := kit.ResolveKitScript("toolbelt/lib/session-budget-pi.mjs", kit.Getenv(m.s.Env)); err == nil {
		return filepath.Dir(filepath.Dir(p))
	}
	return ""
}

// claude is the default harness: the SessionStart hooks of <target>/.claude/settings.json, per source.
func (m *meter) claude() {
	m.say("verify-session-budget: %s", m.target)
	settings := filepath.Join(m.target, ".claude", "settings.json")
	if fi, err := os.Stat(settings); err != nil || !fi.Mode().IsRegular() {
		m.say("state: absent-input (no %s)", settings)
		return
	}
	data, err := os.ReadFile(settings)
	doc, ok := parseSettings(data)
	if err != nil || !ok {
		m.say("state: degraded (settings.json is not a readable JSON object; no hook was run)")
		return
	}
	work, err := os.MkdirTemp(m.tmpRoot(), "tmp.")
	if err != nil {
		m.say("state: degraded (cannot create a temp dir)")
		return
	}
	defer os.RemoveAll(work)

	streams := map[string][]record{}
	anyrec := false
	for _, src := range sources {
		stream, err := selectHooks(doc, src)
		if err != nil {
			m.say("state: degraded (cannot select SessionStart hooks for source %s: %s); no hook was run", src, err)
			return
		}
		streams[src] = splitRecords(stream)
		if stream != "" {
			anyrec = true
		}
	}
	if !anyrec {
		m.say("state: empty-input (no SessionStart command hook matches startup, resume, clear, compact or fork in %s)", settings)
		return
	}

	h := &hookRunner{meter: m, work: work}
	h.probe()

	worstTotal, worstSrc := -1, ""
	ndegAll, ntoAll, nhooksAll, ntruncAll := 0, 0, 0, 0
	degSrcs := ""
	for _, src := range sources {
		recs := streams[src]
		if len(recs) == 0 {
			m.say("source %s: (no matching SessionStart hooks)", src)
			continue
		}
		m.say("source %s:", src)
		h.prep()
		n, total, ndeg := 0, 0, 0
		seen := map[string]bool{}
		for _, rec := range recs {
			if seen[rec.cmd] {
				continue
			}
			seen[rec.cmd] = true
			n++
			nhooksAll++
			line, chars, kind := h.run(src, rec.cmd, rec.decl)
			shown := strings.ReplaceAll(rec.cmd, "\n", " \\n ")
			if kind == kindDeg {
				m.say("hook[%d] chars=n/a status=%s cmd=%s", n, line, shown)
				ndeg++
				continue
			}
			m.say("hook[%d] chars=%d status=%s cmd=%s", n, chars, line, shown)
			total += chars
			if kind == kindTrunc {
				ntruncAll++
			}
			if kind == kindZero {
				ntoAll++
			}
		}
		partial := ""
		if ndeg > 0 {
			partial = fmt.Sprintf(" (partial: %d degraded)", ndeg)
		}
		m.say("aggregate[%s]: %d chars (budget < %d) %s%s", src, total, sessionCap, verdict(total), partial)
		ndegAll += ndeg
		if ndeg > 0 {
			if degSrcs != "" {
				degSrcs += ","
			}
			degSrcs += src
		}
		if total > worstTotal {
			worstTotal, worstSrc = total, src
		}
	}
	partial := ""
	if ndegAll > 0 {
		partial = fmt.Sprintf(" (partial: %d degraded in %s)", ndegAll, degSrcs)
	}
	m.say("aggregate: %d chars (budget < %d) %s%s worst-source=%s", worstTotal, sessionCap, verdict(worstTotal), partial, worstSrc)
	if ndegAll > 0 {
		m.say("state: degraded (%d of %d hook runs could not be measured; %d timed-out)", ndegAll, nhooksAll, ntoAll)
	} else {
		m.say("state: ok (%d hook runs, %d truncated, %d timed-out)", nhooksAll, ntruncAll, ntoAll)
	}
}

type hookKind int

const (
	kindDeg hookKind = iota
	kindOK
	kindTrunc
	kindZero
)

// hookRunner runs the hooks of one measurement in the sandbox.
type hookRunner struct {
	*meter
	work          string
	sandboxReason string
	copyFail      string
	capped        []string
	timeoutPath   string
	bwrapPath     string
}

func (h *hookRunner) dotclaude() string { return filepath.Join(h.work, "dotclaude") }
func (h *hookRunner) sbtmp() string     { return filepath.Join(h.work, "tmp") }

// probe decides once whether hooks may run: bwrap present AND able to start, and timeout present.
func (h *hookRunner) probe() {
	var ok bool
	if h.bwrapPath, ok = h.lookPath("bwrap"); !ok {
		h.sandboxReason = "bwrap not installed"
		return
	}
	if h.timeoutPath, ok = h.lookPath("timeout"); !ok {
		h.sandboxReason = "timeout not installed"
		return
	}
	if why, ok := h.probeBwrap(h.bwrapPath); !ok {
		h.sandboxReason = "bwrap cannot start: " + why
	}
}

// prep makes the throwaway copy of <target>/.claude and a fresh TMPDIR, afresh for every source.
func (h *hookRunner) prep() {
	_ = os.RemoveAll(h.dotclaude())
	_ = os.RemoveAll(h.sbtmp())
	_ = os.MkdirAll(h.dotclaude(), 0o755)
	_ = os.MkdirAll(h.sbtmp(), 0o755)
	h.copyFail = ""
	src := filepath.Join(h.target, ".claude")
	if fi, err := os.Stat(src); err != nil || !fi.IsDir() {
		return
	}
	h.copyFail = h.copyClaude(src, h.dotclaude())
}

// bwrapArgs is the containment of one hook run: the whole filesystem read-only, <target>/.claude a throwaway
// copy, no network, no inherited IPC namespace, no controlling terminal, the agent/socket variables removed.
func (h *hookRunner) bwrapArgs(cmd string) []string {
	return []string{
		"bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
		"--bind", h.dotclaude(), filepath.Join(h.target, ".claude"), "--bind", h.sbtmp(), h.sbtmp(),
		"--setenv", "TMPDIR", h.sbtmp(), "--setenv", "CLAUDE_PROJECT_DIR", h.target,
		"--unsetenv", "SSH_AUTH_SOCK", "--unsetenv", "SSH_AGENT_PID", "--unsetenv", "GPG_AGENT_INFO",
		"--unsetenv", "DBUS_SESSION_BUS_ADDRESS", "--unsetenv", "XDG_RUNTIME_DIR",
		"--unshare-pid", "--unshare-net", "--unshare-ipc", "--new-session", "--die-with-parent", "--chdir", h.target,
		"bash", "-c", cmd,
	}
}

// run runs one hook for a source. line is the status text; chars its measured count; kind how it counts.
func (h *hookRunner) run(src, cmd, decl string) (line string, chars int, kind hookKind) {
	if h.sandboxReason != "" {
		return "degraded(no-sandbox: " + h.sandboxReason + ")", 0, kindDeg
	}
	if h.copyFail != "" {
		return "degraded(incomplete-sandbox-copy: " + h.copyFail + ")", 0, kindDeg
	}
	for _, c := range h.capped {
		if c == cmd {
			return fmt.Sprintf("degraded(timeout, not re-run: hit the %ds script cap in an earlier source)", h.toCap), 0, kindDeg
		}
	}
	declN, declOK := 0, allDigits(decl)
	if declOK {
		var ok bool
		if declN, ok = atoiOr(decl); !ok {
			declN = int(^uint(0) >> 1)
		}
	} else {
		decl = ""
	}
	eff := 600
	if declOK {
		eff = declN
	}
	if eff > h.toCap {
		eff = h.toCap
	}
	if eff < 1 {
		eff = 1
	}
	outFile, err := os.CreateTemp(h.work, "out.")
	if err != nil {
		return "degraded(exit 1)", 0, kindDeg
	}
	defer func() { outFile.Close(); os.Remove(outFile.Name()) }()
	stdin := fmt.Sprintf(`{"session_id":"budget-probe","hook_event_name":"SessionStart","source":"%s","cwd":"%s"}`, src, h.target)
	argv := append([]string{h.timeoutPath, "-k", "2", strconv.Itoa(eff)}, h.bwrapArgs(cmd)...)
	r := h.env.run(argv, stdin, outFile, false)
	if r.rc == 124 || r.rc == 137 {
		if declOK && declN <= h.toCap {
			return fmt.Sprintf("timed-out(hook timeout %ds)", declN), 0, kindZero
		}
		h.capped = append(h.capped, cmd)
		allow := "600"
		if declOK {
			allow = decl
		}
		return fmt.Sprintf("degraded(timeout %ds: this script's cap; the hook allows %ss)", eff, allow), 0, kindDeg
	}
	if r.rc != 0 {
		return fmt.Sprintf("degraded(exit %d)", r.rc), 0, kindDeg
	}
	data, err := os.ReadFile(outFile.Name())
	if err != nil {
		return "degraded(exit 1)", 0, kindDeg
	}
	first, second := hookChars(data)
	chars, kind, line = first+second, kindOK, "ok"
	if first > hookCap || second > hookCap {
		kind, line = kindTrunc, "TRUNCATED"
	}
	return line, chars, kind
}
