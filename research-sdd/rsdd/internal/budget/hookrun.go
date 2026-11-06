package budget

// hookrun.go: the sandboxed run of one SessionStart hook (split out of session.go, behavior unchanged).

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

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
