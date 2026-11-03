package kit

import (
	"path/filepath"
	"slices"
	"strings"
)

// ShimEnv is the environment a Go command gives a toolbelt shim it execs: any Go command that execs a shim passes
// its env through this. A shim without RSDD_BIN re-hashes the Go sources on every call (about 1.1 s against 19 ms
// with it), so the shim gets the running binary unless the caller already chose one. It returns a copy of environ;
// a non-empty RSDD_BIN is kept as given, and when self fails the copy is returned unchanged.
func ShimEnv(environ []string, self func() (string, error)) []string {
	out := append([]string(nil), environ...)
	for _, kv := range environ {
		if v, ok := strings.CutPrefix(kv, "RSDD_BIN="); ok && v != "" {
			return out
		}
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
	out = slices.DeleteFunc(out, func(kv string) bool { return kv == "RSDD_BIN=" }) // an empty value is replaced
	return append(out, "RSDD_BIN="+exe)
}
