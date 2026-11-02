package stageissues

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// execResult is one finished child process. NotFound means the program could not be found or started (bash
// `command -v` failing); RC is then 127.
type execResult struct {
	Out      string // stdout, plus stderr when the call merged them (`2>&1`)
	RC       int
	NotFound bool
}

// execFn runs name with args; merged sends stderr into Out in call order, otherwise stderr is discarded
// (`2>/dev/null`). Tests replace it.
type execFn func(name string, args []string, merged bool) execResult

// lookPath finds name on pathVar the way `command -v` does for a plain name: the first executable regular file.
func lookPath(pathVar, name string) (string, bool) {
	if strings.Contains(name, "/") {
		return name, isExecutable(name)
	}
	for _, d := range strings.Split(pathVar, ":") {
		if d == "" {
			d = "."
		}
		p := filepath.Join(d, name)
		if isExecutable(p) {
			return p, true
		}
	}
	return "", false
}

func isExecutable(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular() && st.Mode().Perm()&0o111 != 0
}

// osExec is the real execFn: programs resolve on the PATH of env (not the process's), run in dir, and inherit env.
func osExec(env []string, dir, pathVar string) execFn {
	return func(name string, args []string, merged bool) execResult {
		p, ok := lookPath(pathVar, name)
		if !ok {
			return execResult{RC: 127, NotFound: true}
		}
		cmd := exec.Command(p, args...)
		cmd.Args[0] = name
		cmd.Env, cmd.Dir = env, dir
		var out bytes.Buffer
		cmd.Stdout = &out
		if merged {
			cmd.Stderr = &out // the same writer: one pipe, so the two streams keep their order
		}
		err := cmd.Run()
		res := execResult{Out: out.String()}
		var ee *exec.ExitError
		switch {
		case err == nil:
		case errors.As(err, &ee):
			res.RC = ee.ExitCode()
			if res.RC < 0 { // killed by a signal: the shell reports 128+N, and the child is not inspectable here
				res.RC = 255
			}
		default:
			res.RC, res.NotFound = 127, true
		}
		return res
	}
}

// trimNL is command substitution: every trailing newline is dropped.
func trimNL(s string) string { return strings.TrimRight(s, "\n") }

// gitOut runs git with stderr discarded and returns its trimmed stdout; ok is false on any failure.
func (a *app) gitOut(args ...string) (string, bool) {
	r := a.run("git", args, false)
	if r.RC != 0 {
		return "", false
	}
	return trimNL(r.Out), true
}

func (a *app) run(name string, args []string, merged bool) execResult {
	return a.exec(name, args, merged)
}

// hasCommand is `command -v name`.
func (a *app) hasCommand(name string) bool { return a.have(name) }
