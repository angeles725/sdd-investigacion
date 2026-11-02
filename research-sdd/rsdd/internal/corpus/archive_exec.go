package corpus

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// archiveCmdSub is the `$(...)` rule: trailing newlines are cut.
func archiveCmdSub(s string) string { return strings.TrimRight(s, "\n") }

// archiveRunArgv runs argv (argv[0] is a path or a name looked up on the child's PATH) in the caller's working
// directory with the caller's environment. combined merges stderr into the output stream in order (`2>&1`); otherwise
// stderr is dropped (`2>/dev/null`). The code is the shell's: 127 for a program that is not there, 126 for one that
// cannot be executed, 128+N for a signal.
func (e *archiveEnv) archiveRunArgv(argv []string, combined bool) (string, int) {
	path := argv[0]
	if !strings.Contains(path, "/") {
		p, err := probe.New(e.env, e.s.Cwd).LookPath(path)
		if err != nil {
			return "", 127
		}
		path = p
	}
	st, err := os.Stat(path)
	switch {
	case err != nil:
		return "", 127
	case st.IsDir():
		return "", 126
	}
	var buf bytes.Buffer
	run := func(name string, args []string) error {
		c := exec.Command(name, args...)
		c.Dir, c.Env = e.s.Cwd, e.env
		c.Stdin = nil
		c.Stdout = &buf
		if combined {
			c.Stderr = &buf
		} else {
			c.Stderr = io.Discard
		}
		return c.Run()
	}
	err = run(path, argv[1:])
	var pe *os.PathError
	if errors.As(err, &pe) && errors.Is(pe.Err, syscall.ENOEXEC) {
		buf.Reset()
		if b, lerr := probe.New(e.env, e.s.Cwd).LookPath("bash"); lerr == nil {
			err = run(b, append([]string{path}, argv[1:]...))
		}
	}
	return buf.String(), archiveExitCode(err)
}

func archiveExitCode(err error) int {
	if err == nil {
		return 0
	}
	var xe *exec.ExitError
	if errors.As(err, &xe) {
		if ws, ok := xe.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return xe.ExitCode()
	}
	if errors.Is(err, os.ErrPermission) || errors.Is(err, syscall.EACCES) {
		return 126
	}
	return 127
}

// archiveSibling runs a sibling toolbelt script with stdout and stderr discarded (`>/dev/null 2>&1`).
func (e *archiveEnv) archiveSibling(script string, args ...string) int {
	_, rc := e.archiveRunArgv(append([]string{e.here + "/" + script}, args...), false)
	return rc
}

// archiveGit is `git -C dir args` with stderr dropped; a git that cannot be found yields code 127.
func (e *archiveEnv) archiveGit(dir string, args ...string) (string, int) {
	return e.archiveRunArgv(append([]string{"git", "-C", dir}, args...), false)
}

// archiveGitCombined is `git -C dir args 2>&1`.
func (e *archiveEnv) archiveGitCombined(dir string, args ...string) (string, int) {
	return e.archiveRunArgv(append([]string{"git", "-C", dir}, args...), true)
}

// archiveHaveGit is `command -v git`.
func (e *archiveEnv) archiveHaveGit() bool {
	_, err := probe.New(e.env, e.s.Cwd).LookPath("git")
	return err == nil
}

// archiveFirstLine is `printf '%s' x | head -1`.
func archiveFirstLine(s string) string {
	first, _, _ := strings.Cut(s, "\n")
	return first
}

// archiveCutBytes is `cut -c1-n`: GNU cut counts bytes.
func archiveCutBytes(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// archiveTmpDir is where `mktemp` creates files.
func (e *archiveEnv) archiveTmpDir() string {
	if d := e.s.Env("TMPDIR"); d != "" {
		return d
	}
	return "/tmp"
}
