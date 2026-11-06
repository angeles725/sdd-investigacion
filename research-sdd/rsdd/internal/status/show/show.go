// Package show is `rsdd status show`, the port of toolbelt/research-sdd-status.sh (issue #2549). It lands in
// slices. Ported so far, which is every mode of the script: argument parsing and validation, --emit-token, the
// state-file pick with its BOOTSTRAP answers, the is_blocked reader, the counters and envelope readers, --sync-state
// (S3), --next with its STALE / RETRO-DUE / ISSUES-DUE gates (S4, S5), and the default report (S6) with its §8c
// campaign queue block and document-cycle outline (S7). The script stays authoritative until the last slice (S8
// turns it into a shim over this package).
package show

import (
	"fmt"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
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

// tail is the part of the run after the pick.
type tail func(c *ctx) int

// Run is `rsdd status show <target-dir> [flags]`.
func Run(args []string, s cli.Stdio) int {
	return run(args, s, syncOr(nextOr(liveSeams, (*ctx).report)))
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
	if rc, done := c.pick(resolveState); done {
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
