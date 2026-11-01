package fidelity

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// maxOutput caps a tool's combined output (a variable only so a test can lower it).
var maxOutput = 64 << 20

// procRun is the production Runner: core/proc with the caller's environment. A bound hit is status 124 (what
// `timeout` reports), a run killed by signal N is 128+N, a run cut at the output cap never reads as success, and
// a program that cannot start is 127 with the reason as its output.
func procRun(c Cmd) Result {
	res, err := proc.Run(proc.Spec{Argv: c.Argv, Dir: c.Dir, Env: c.Env, Timeout: c.Timeout, MaxBytes: maxOutput})
	var spawn *proc.SpawnError
	if errors.As(err, &spawn) || errors.Is(err, proc.ErrInvalidSpec) {
		return Result{RC: 127, Output: []byte(err.Error() + "\n")}
	}
	out := append(append([]byte{}, res.Stdout...), res.Stderr...)
	return Result{RC: exitStatus(res), Output: out}
}

// exitStatus maps a proc result to the status the shell would have seen.
func exitStatus(res proc.Result) int {
	rc := res.ReturnCode
	switch {
	case res.Reason == proc.ReasonTimeout:
		return 124
	case rc < 0:
		return 128 - rc
	case res.Reason == proc.ReasonOutputCap && rc == 0:
		return 1
	}
	return rc
}

// usableTool is `[ -f P ] && [ -x P ]`; a relative P is read against cwd. An empty P is never a file.
func usableTool(cwd, p string) bool {
	if !filepath.IsAbs(p) && cwd != "" {
		p = filepath.Join(cwd, p)
	}
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular() && canExec(p)
}
