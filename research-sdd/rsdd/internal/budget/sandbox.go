package budget

import (
	"bytes"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Containment: hooks write (the protocol hook records a session-sha file under <target>/.claude/), so they NEVER run against
// the live tree. Each runs in a bubblewrap sandbox with the whole filesystem read-only, <target>/.claude replaced by a
// throwaway COPY (minus .claude/worktrees) and a fresh TMPDIR, no network, no inherited IPC namespace, no controlling terminal,
// and the agent/socket variables removed. A bwrap that is absent or cannot start makes every hook degraded(no-sandbox: ...):
// nothing is ever run unprotected. (Propose-never-apply, CLAUDE.md section 8.)

// unsetVars are the agent/socket variables removed from every sandboxed run.
var unsetVars = []string{"SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_AGENT_INFO", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR"}

// namespaceFlags are the isolation switches shared by the Claude and pi sandboxes.
var namespaceFlags = []string{"--unshare-pid", "--unshare-net", "--unshare-ipc", "--new-session", "--die-with-parent"}

// sandboxReason probes the sandbox: bwrap present AND able to start, and timeout present. "" means usable.
func (e env) sandboxReason() string {
	bwrap := e.lookPath("bwrap")
	switch {
	case bwrap == "":
		return "bwrap not installed"
	case e.lookPath("timeout") == "":
		return "timeout not installed"
	}
	out, err := e.cmd(bwrap, "--ro-bind", "/", "/", "true").CombinedOutput()
	if err != nil {
		return "bwrap cannot start: " + firstLine(strings.TrimRight(string(out), "\n"))
	}
	return ""
}

// utf8Counts probes the locale: `wc -m` must count characters, not bytes (`printf 'é' | LC_ALL=C.UTF-8 wc -m` must read 1).
func (e env) utf8Counts() bool {
	wc := e.lookPath("wc")
	if wc == "" {
		return false
	}
	c := e.cmd(wc, "-m")
	c.Env = e.environ("LC_ALL=C.UTF-8")
	c.Stdin = strings.NewReader("é")
	out, _ := c.Output()
	return strings.TrimRight(strings.ReplaceAll(string(out), " ", ""), "\n") == "1"
}

// claudeEntries are the entries of <target>/.claude that get copied: the script's `"$d"/*` then `"$d"/.[!.]*` globs, each
// existing entry except one named worktrees. Order is byte order (the shell's was locale collation).
func claudeEntries(dir string) []string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(ents))
	for _, en := range ents {
		names = append(names, en.Name())
	}
	sort.Strings(names)
	var plain, dots []string
	for _, n := range names {
		switch {
		case n == "worktrees":
			continue
		case !strings.HasPrefix(n, "."):
			plain = append(plain, filepath.Join(dir, n))
		case len(n) >= 2 && n[1] != '.':
			dots = append(dots, filepath.Join(dir, n))
		}
	}
	var out []string
	for _, p := range append(plain, dots...) {
		if _, err := os.Stat(p); err == nil { // `[ -e ]`: a broken symlink is skipped
			out = append(out, p)
		}
	}
	return out
}

// copyClaude copies <target>/.claude (minus worktrees) into dst with `cp -a`. The result is the first stderr line of the LAST
// entry that failed to copy ("" when all copied; an empty message also reads as no failure, as in the script).
func (e env) copyClaude(target, dst string) (failure string) {
	cp := e.lookPath("cp")
	for _, p := range claudeEntries(filepath.Join(target, ".claude")) {
		if cp == "" {
			failure = "cp: command not found"
			continue
		}
		var stderr bytes.Buffer
		c := e.cmd(cp, "-a", p, dst+"/")
		c.Stderr = &stderr
		if err := c.Run(); err != nil {
			failure = firstLine(stderr.String())
		}
	}
	return failure
}

// freshDirs makes dir empty and present (`rm -rf; mkdir -p`).
func freshDirs(dirs ...string) {
	for _, d := range dirs {
		_ = os.RemoveAll(d)
		_ = os.MkdirAll(d, 0o755)
	}
}
