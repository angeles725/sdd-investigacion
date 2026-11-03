package kit

import (
	"path/filepath"
	"slices"
	"strings"
)

// ShimEnv is the environment a Go command gives a toolbelt shim it execs: any Go command that execs a shim passes
// its env through this. A shim given RSDD_BIN runs that binary; without it, it checks its source fingerprint on
// every call (about 40-50 ms against about 19 ms) and rebuilds after a source change. The contract:
//   - It returns a new slice; environ is never modified.
//   - A nil environ is returned as nil: a nil exec.Cmd.Env inherits the parent's environment, so `cmd.Env =
//     ShimEnv(cmd.Env, ...)` never strips it, but it gets no RSDD_BIN either. Pass the command's own environment
//     (cli.Stdio.Environ) to hand the binary over. An empty non-nil environ stays empty apart from RSDD_BIN.
//   - RSDD_BIN is read as exec reads it: the last "RSDD_BIN=" entry wins. A non-empty value is kept unchanged.
//   - Otherwise every "RSDD_BIN=" entry is dropped and RSDD_BIN=<self()> is appended, made absolute and with
//     symlinks resolved; a path EvalSymlinks cannot resolve is used in its absolute form.
//   - When self or filepath.Abs fails, the copy is returned unchanged.
func ShimEnv(environ []string, self func() (string, error)) []string {
	if environ == nil {
		return nil // inherit, as exec does: only cli/stdio.go reads the process environment (archtest)
	}
	out := append([]string(nil), environ...)
	if v := lastRSDDBin(environ); v != "" {
		return out
	}
	exe, err := self()
	if err != nil {
		return out
	}
	if exe, err = filepath.Abs(exe); err != nil { // the shim runs from another directory: the path must not be relative
		return out
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	out = slices.DeleteFunc(out, func(kv string) bool { return strings.HasPrefix(kv, "RSDD_BIN=") })
	return append(out, "RSDD_BIN="+exe)
}

// lastRSDDBin is the value exec gives the child: the last RSDD_BIN entry ("" when unset).
func lastRSDDBin(environ []string) string {
	for i := len(environ) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(environ[i], "RSDD_BIN="); ok {
			return v
		}
	}
	return ""
}
