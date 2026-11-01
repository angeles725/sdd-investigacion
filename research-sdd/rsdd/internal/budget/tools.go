package budget

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// env is the instrument's view of the caller: environment and PATH come from cli.Stdio, never from the process.
//
// The instrument runs hooks through the `timeout` and `bwrap` binaries and measures through `jq` and `wc` exactly as the
// script did, so a missing or faulty tool produces the same typed degraded state it always did. os/exec is used directly
// (not core/proc) because the hook needs a stdin payload and an uncapped stdout file, neither of which core/proc offers.
type env struct{ s cli.Stdio }

const defaultPath = "/usr/local/bin:/usr/bin:/bin"

func (e env) get(k string) string { return e.s.Env(k) }

// environ is the caller's whole environment, with the given KEY=VALUE pairs set over it.
func (e env) environ(set ...string) []string {
	base := e.s.Environ()
	out := make([]string, 0, len(base)+len(set))
outer:
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		for _, s := range set {
			if sk, _, _ := strings.Cut(s, "="); sk == k {
				continue outer
			}
		}
		out = append(out, kv)
	}
	return append(out, set...)
}

// lookPath is `command -v name` on the caller's PATH: the first executable regular file ("" when there is none).
func (e env) lookPath(name string) string {
	path := e.s.Env("PATH")
	if path == "" {
		path = defaultPath
	}
	for _, d := range filepath.SplitList(path) {
		if d == "" {
			d = "."
		}
		p := filepath.Join(d, name)
		if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
			return p
		}
	}
	return ""
}

// cmd builds a command over the caller's environment.
func (e env) cmd(path string, args ...string) *exec.Cmd {
	c := exec.Command(path, args...)
	c.Args[0] = filepath.Base(path) // tools name themselves in their messages (cp: ..., jq: error ...), as when run by name
	c.Env = e.environ()
	return c
}

// exitCode is the shell's view of a finished command: the status, or 128+N for a signal, -1 when it never started.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	if ee, ok := err.(*exec.ExitError); ok {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return ee.ExitCode()
	}
	return -1
}

// firstLine is `printf '%s' "$x" | head -1 | cut -c1-120`: the first line, cut to 120 bytes (GNU cut -c is byte-wise).
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 120 {
		s = s[:120]
	}
	return s
}

// cmpDec compares two non-negative decimal digit strings numerically (leading zeros ignored), like `[ a -gt b ]`.
func cmpDec(a, b string) int {
	a, b = strings.TrimLeft(a, "0"), strings.TrimLeft(b, "0")
	if len(a) != len(b) {
		if len(a) < len(b) {
			return -1
		}
		return 1
	}
	return strings.Compare(a, b)
}

// onlyDigits reports a non-empty all-digit string (the negation of the script's `case ”|*[!0-9]*`).
func onlyDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
