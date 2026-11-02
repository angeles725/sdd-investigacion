package budget

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// env is the process surface the measurement needs: the caller's environment (hooks and the sandbox inherit it
// the way the script's children did), PATH lookups on THAT environment, and a bounded runner.
type env struct{ s cli.Stdio }

// lookPath is `command -v name`: the first executable regular file on PATH (the default PATH when unset).
func (e env) lookPath(name string) (string, bool) {
	path := e.s.Env("PATH")
	if path == "" {
		path = "/usr/local/bin:/usr/bin:/bin"
	}
	for _, d := range filepath.SplitList(path) {
		if d == "" {
			d = "."
		}
		p := filepath.Join(d, name)
		if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
			return p, true
		}
	}
	return "", false
}

// result is one finished child: its exit code as a shell sees it (128+N when killed by signal N, 127 when it
// could not start), and what it wrote.
type result struct {
	rc     int
	stdout []byte
	stderr []byte
}

// run starts argv[0] (already resolved) with the caller's environment plus extra, stdin as given. stdout and
// stderr go to the files when set, otherwise they are captured (stderr merged into stdout when merge is set).
func (e env) run(argv []string, stdin string, stdout *os.File, merge bool) result {
	// argv[0] is the resolved path; the program is told the bare name, as a shell tells it (cp: ... not /usr/bin/cp: ...).
	cmd := &exec.Cmd{Path: argv[0], Args: append([]string{filepath.Base(argv[0])}, argv[1:]...), Env: e.s.Environ(), Dir: e.s.Cwd}
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var ob, eb bytes.Buffer
	if stdout != nil {
		cmd.Stdout = stdout
	} else {
		cmd.Stdout = &ob
	}
	if merge {
		cmd.Stderr = cmd.Stdout
	} else {
		cmd.Stderr = &eb
	}
	err := cmd.Run()
	r := result{stdout: ob.Bytes(), stderr: eb.Bytes()}
	var ee *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &ee):
		r.rc = ee.ExitCode()
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			r.rc = 128 + int(ws.Signal())
		}
	default:
		r.rc = 127
	}
	return r
}

// firstLine is `head -1`; cut120 is `cut -c1-120` (GNU cut counts bytes for -c).
func firstLine(b []byte) string {
	if i := bytes.IndexByte(b, '\n'); i >= 0 {
		b = b[:i]
	}
	return string(b)
}

func cut120(s string) string {
	if len(s) > 120 {
		return s[:120]
	}
	return s
}

// probeBwrap is `bwrap --ro-bind / / true`: the empty string when bwrap can start, else the first line of what
// it said, cut to 120 bytes.
func (e env) probeBwrap(bwrap string) (string, bool) {
	r := e.run([]string{bwrap, "--ro-bind", "/", "/", "true"}, "", nil, true)
	if r.rc == 0 {
		return "", true
	}
	return cut120(firstLine(r.stdout)), false
}

// claudeEntries are the names `"$d"/* "$d"/.[!.]*` expands to that exist (`[ -e ]`, so a dangling symlink is
// skipped), minus worktrees: non-dot names first, then dot names not starting with "..", each sorted by byte.
func claudeEntries(dir string) []string {
	des, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var plain, dots []string
	for _, de := range des {
		n := de.Name()
		if n == "worktrees" {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, n)); err != nil {
			continue
		}
		switch {
		case !strings.HasPrefix(n, "."):
			plain = append(plain, n)
		case len(n) > 1 && n[1] != '.':
			dots = append(dots, n)
		}
	}
	sort.Strings(plain)
	sort.Strings(dots)
	return append(plain, dots...)
}

// copyClaude copies every entry of <dir> (minus worktrees) into dst with `cp -a`, so modes, symlinks and times
// survive. The result is the first stderr line of the LAST failing copy, cut to 120 bytes; empty means every
// copy worked (a failing cp that said nothing counts as worked, as in the script).
func (e env) copyClaude(dir, dst string) string {
	fail := ""
	cp, ok := e.lookPath("cp")
	for _, n := range claudeEntries(dir) {
		if !ok {
			fail = "cp: command not found"
			continue
		}
		r := e.run([]string{cp, "-a", filepath.Join(dir, n), dst + "/"}, "", nil, false)
		if r.rc != 0 {
			fail = cut120(firstLine(r.stderr))
		}
	}
	return fail
}

// atoiOr parses a non-negative decimal; ok is false when it does not fit (the script's bash arithmetic
// would have complained).
func atoiOr(s string) (int, bool) {
	n, err := strconv.Atoi(s)
	return n, err == nil && n >= 0
}

// allDigits reports a non-empty run of ASCII digits (the script's `*[!0-9]*` test, negated).
func allDigits(s string) bool {
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
