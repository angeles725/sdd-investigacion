package toolcatalog

import (
	"bytes"
	"io"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// Port of the SessionStart hook over the check:
//
//	rsdd verify tool-catalog-hook [<toolbelt-dir>] [--full]
//
// It runs the check in process and prints the SessionStart envelope: a declared-clean sentinel when every logged
// tool is cataloged, nothing on an empty log, a COMPACT drift report otherwise (kit issue #1816; --full keeps the
// per-tool WARN lines). Like the script it always exits 0: a hook never fails the session. Every could-not-run
// context goes through hookenv.FailureContext (kit issue #2631).

// hookCheck is the check the hook runs: the real one, or a stand-in in a test.
type hookCheck func(dir string, l locale, out, errw io.Writer) int

// RunHook is the `verify tool-catalog-hook` command.
func RunHook(args []string, s cli.Stdio) int {
	v := fsview.View{Cwd: s.Cwd}
	return runHook(args, s, func(dir string, l locale, out, errw io.Writer) int { return check(v, dir, l, out, errw) })
}

func runHook(args []string, s cli.Stdio, run hookCheck) int {
	dir := s.Cwd
	if len(args) > 0 && args[0] != "--full" {
		dir, args = args[0], args[1:]
	}
	full := len(args) > 0 && args[0] == "--full"
	var buf bytes.Buffer // one writer for both streams, so the order is the script's `2>&1`
	// the check exits 1 only when it could not run, so a panic (cli.ExitOperational, also 1) shares that header
	rc := hookenv.Guard(&buf, func() int { return run(dir, localeOf(s.Env), &buf, &buf) })
	emitHook(s.Out, strings.TrimRight(buf.String(), "\n"), rc, full)
	return cli.ExitOK
}

// emitHook prints the envelope for one run of the check (trailing newlines stripped from out), or nothing.
func emitHook(w io.Writer, out string, rc int, full bool) {
	if ctx, emit := hookContext(out, rc, full); emit {
		hookenv.WriteSessionStart(w, ctx)
	}
}
