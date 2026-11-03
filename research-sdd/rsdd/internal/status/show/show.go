// Package show is `rsdd status show`, the port of toolbelt/research-sdd-status.sh (issue #2549). It lands in
// slices; this one carries the argument parsing and validation, --emit-token, the state-file pick with its
// BOOTSTRAP answers, and the is_blocked reader. The script stays authoritative until the last slice: every
// section after the pick is reported as not yet ported (typed, exit 1), never answered silently.
package show

import (
	"fmt"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// ctx is what the later sections of the script read once the pick is done: the target as the caller wrote it
// (the script prints it verbatim), the state file and its directory.
type ctx struct {
	s      cli.Stdio
	opts   options
	target string
	state  string
	corpus string

	focCache map[string]string // _RSDD_FOC_TOK_CACHE: the FOCUSES.md token per (file, state basename)
	buSuffix string            // _BU_SUFFIX: the [backlog-unreadable] qualifier of an exhausted STOP

	verifyDown string // why verify-state could not run (empty: it ran)

	blockedHook func(gap string) int // a test replaces the is_blocked read (0 blocked, 1 not, 2 unknown)
}

// tail is the part of the run after the pick. A slice that ports more sections replaces notPorted.
type tail func(c *ctx) int

// Run is `rsdd status show <target-dir> [flags]`.
func Run(args []string, s cli.Stdio) int {
	return run(args, s, syncOr(nextOr(pendingSeams, notPorted)))
}

// notPorted answers a run that got past the pick: the later sections are not in Go yet.
func notPorted(c *ctx) int {
	fmt.Fprintf(c.s.Err, "rsdd: status show: not-yet-ported: %s after the state-file pick; use toolbelt/research-sdd-status.sh (issue #2549)\n", c.opts.mode)
	return cli.ExitOperational
}

func run(args []string, s cli.Stdio, t tail) int {
	c := &ctx{s: s}
	if len(args) > 0 {
		c.target = args[0]
	}
	if !c.isDir(c.target) {
		fmt.Fprintln(s.Err, "usage: research-sdd-status.sh <target-dir> [--next|--sync-state] [--focus <slug>]")
		return cli.ExitUsage
	}
	o, usage := parseArgs(args[1:])
	if usage != "" {
		fmt.Fprintln(s.Err, usage)
		return cli.ExitUsage
	}
	c.opts = o
	if o.emitToken {
		return emitToken(args, s, t)
	}
	if rc, done := c.pick(kit.ResolveStateFile); done {
		return rc
	}
	return t(c)
}

// abs is the path the process can open: relative paths are relative to the Stdio working directory. Printed
// paths keep the caller's spelling (see show).
func (c *ctx) abs(p string) string {
	if strings.HasPrefix(p, "/") {
		return p
	}
	return c.s.Cwd + "/" + p
}

// show maps a path built from abs(target) back to the spelling the script would print.
func (c *ctx) show(p string) string {
	if p == "" {
		return ""
	}
	if root := c.abs(c.target); root != c.target && strings.HasPrefix(p, root) {
		return c.target + p[len(root):]
	}
	return p
}

// isDir is `[ -d p ]`.
func (c *ctx) isDir(p string) bool {
	st, err := os.Stat(c.abs(p))
	return p != "" && err == nil && st.IsDir()
}

// isFile is `[ -f p ]`.
func (c *ctx) isFile(p string) bool {
	st, err := os.Stat(c.abs(p))
	return p != "" && err == nil && st.Mode().IsRegular()
}

// dirname is dirname(1): trailing slashes dropped, then the last component, then the slashes before it.
func dirname(p string) string {
	t := strings.TrimRight(p, "/")
	if t == "" && p != "" {
		return "/"
	}
	p = t
	i := strings.LastIndex(p, "/")
	if i < 0 {
		return "."
	}
	p = strings.TrimRight(p[:i], "/")
	if p == "" {
		return "/"
	}
	return p
}
