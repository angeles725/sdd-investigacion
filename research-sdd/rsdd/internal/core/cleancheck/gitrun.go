package cleancheck

import (
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// selectors are the variables that would point git at a repository other than --target.
var selectors = map[string]bool{"GIT_DIR": true, "GIT_WORK_TREE": true, "GIT_COMMON_DIR": true, "GIT_INDEX_FILE": true}

// gitEnvironment is env without the repository selectors; the last value of a repeated name wins, as exec reads it.
func gitEnvironment(env []string) []string {
	last := map[string]int{}
	for i, kv := range env {
		if k, _, ok := strings.Cut(kv, "="); ok {
			last[k] = i
		}
	}
	var out []string
	for i, kv := range env {
		k, _, ok := strings.Cut(kv, "=")
		if ok && (selectors[k] || last[k] != i) {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// envValue is the value of key in env (the last one), and whether it is set.
func envValue(env []string, key string) (string, bool) {
	v, found := "", false
	for _, kv := range env {
		if k, val, ok := strings.Cut(kv, "="); ok && k == key {
			v, found = val, true
		}
	}
	return v, found
}

// gitRes is one finished git: stdout, stderr and the shell's exit code (127 not runnable, 124 timed out).
type gitRes struct {
	out, err string
	rc       int
}

// git is `git -C <target> args`. Stderr is kept even when git succeeds: the callers that left it visible forward it.
func (r *run) git(args ...string) gitRes {
	out, err := proc.Run(proc.Spec{
		Argv: append([]string{"git", "-C", r.targetP}, args...), Env: r.env,
		Timeout: kitmaint.ChildCeiling, MaxBytes: 64 << 20, Now: r.o.Now,
	})
	if err != nil {
		return gitRes{rc: 127, err: err.Error()}
	}
	res := gitRes{out: string(out.Stdout), err: string(out.Stderr), rc: out.ReturnCode}
	switch {
	case out.Reason == proc.ReasonTimeout:
		res.rc = 124
	case out.ReturnCode < 0:
		res.rc = 128 - out.ReturnCode
	}
	return res
}

// trimmed is stdout as a command substitution gives it: trailing newlines removed.
func (g gitRes) trimmed() string { return strings.TrimRight(g.out, "\n") }

// nulFields splits NUL-terminated output into its elements.
func nulFields(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\x00"), "\x00")
}
