package lint

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// pyEngine runs the unported Python engine for --pack runs (U3.2, #2393). The packs are exec'd against the
// lint_block.py module, so the module itself stays in the toolbelt until the packs are ported.
type pyEngine struct {
	python string
	helper string
}

// helperPath is $LINT_BLOCK_HELPER, else <kit>/toolbelt/lint_block.py next to the running binary (<kit>/bin/rsdd).
func helperPath(s cli.Stdio) string {
	if h := s.Env("LINT_BLOCK_HELPER"); h != "" {
		return h
	}
	if exe, err := os.Executable(); err == nil {
		return filepath.Join(filepath.Dir(filepath.Dir(exe)), "toolbelt", "lint_block.py")
	}
	return ""
}

// newPyEngine probes python3 and the helper (the shell's two DEGRADED probes). It returns nil and the exit code
// to use when either is missing: a run that cannot lint is never reported as clean.
func newPyEngine(s cli.Stdio) (*pyEngine, int) {
	py, err := exec.LookPath("python3")
	if err != nil {
		fmt.Fprintln(s.Err, "lint-block: DEGRADED: python3 not found — nothing was linted (this is NOT a clean result)")
		return nil, 2
	}
	h := helperPath(s)
	if st, err := os.Stat(h); h == "" || err != nil || st.IsDir() {
		fmt.Fprintf(s.Err, "lint-block: DEGRADED: helper %s missing — nothing was linted (this is NOT a clean result)\n", h)
		return nil, 2
	}
	return &pyEngine{python: py, helper: h}, 0
}

// run executes `python3 lint_block.py args...` with stdin, streaming its stdout/stderr, and returns its exit code.
func (p *pyEngine) run(s cli.Stdio, args []string, stdin string) int {
	cmd := exec.Command(p.python, append([]string{p.helper}, args...)...)
	cmd.Dir = s.Cwd
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Stdout, cmd.Stderr = s.Out, s.Err
	err := cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &ee):
		return ee.ExitCode()
	default:
		fmt.Fprintf(s.Err, "lint-block: DEGRADED: cannot run %s: %v\n", p.helper, err)
		return 2
	}
}
