package kitwait

import (
	"bytes"
	"os"
	"os/exec"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// ExecMergeGate returns a MergeGate that runs a child in dir with stdout and stderr in one buffer (the bash `2>&1`).
// With script set it is `bash script args` (KIT_MERGE_GATE, a test double or an alternate gate); without it the
// binary named by self runs its own `gate merge args`, so the standalone tools need no merge-gate.sh and no bash hop.
func ExecMergeGate(env []string, dir, script, self string) func(args []string) (int, string) {
	return func(args []string) (int, string) {
		argv := append([]string{self, "gate", "merge"}, args...)
		if script != "" {
			argv = append([]string{"bash", script}, args...)
		}
		var buf bytes.Buffer
		c := exec.Command(argv[0], argv[1:]...)
		c.Dir, c.Env = dir, append(append([]string(nil), env...), "PWD="+dir)
		c.Stdout, c.Stderr = &buf, &buf
		if err := c.Run(); err != nil {
			if _, ok := err.(*exec.ExitError); !ok {
				return 127, buf.String()
			}
		}
		return kitmaint.ExitCode(c.ProcessState), buf.String()
	}
}

// Self is the path of the running rsdd binary ("" when it cannot be told: ExecMergeGate then fails with rc 127).
func Self() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return exe
}
