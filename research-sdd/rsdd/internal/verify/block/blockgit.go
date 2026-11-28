package block

import (
	"os/exec"
	"strings"
)

// gitCommand builds every subprocess the command spawns; a test records through it (kit issue #2600).
var gitCommand = exec.Command

// gitTopLevel is `git -C "$target" rev-parse --show-toplevel 2>/dev/null` (empty on any failure).
func (b *blockRun) gitTopLevel() string {
	cmd := gitCommand("git", "-C", b.target, "rev-parse", "--show-toplevel")
	cmd.Dir = b.s.Cwd
	cmd.Env = b.s.Environ()
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}
