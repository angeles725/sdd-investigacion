package writercheck

import (
	"fmt"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// execute is the run once the repository is known: the mode-specific argument rules, the range, the diff, and then
// --print-binding, --write-teeth-log or the check.
func (c *ctx) execute() int {
	o := &c.o
	s := c.s
	script := ""
	if o.write {
		switch {
		case len(o.positional) == 0:
			return usage(s, "--write-teeth-log needs at least one suite")
		case o.base == "":
			return usage(s, "--write-teeth-log needs --base (the log is bound to the changed files against it)")
		}
		o.worktree, o.headGiven = true, false // the log binds the WORKTREE contents against --base
	} else {
		switch {
		case o.base == "":
			return usage(s, "")
		case len(o.positional) > 0:
			return usage(s, "unexpected argument: "+o.positional[0])
		case o.worktree && o.headGiven:
			return usage(s, "--worktree and --head are mutually exclusive")
		}
		if o.logDir != "" {
			dir, err := kitmaint.ResolveDir(s.Cwd, o.logDir)
			if err != nil || !kitmaint.IsDir(dir) {
				return degrade(s, "teeth-log dir absent: "+o.logDir)
			}
			o.logDir = dir
		}
		if script = c.impactScript(); !o.printBinding && !isFile(kitmaint.Abs(s.Cwd, script)) {
			if script == "" {
				script = "(set KIT_WRITER_CHECK_IMPACT)"
			}
			return degrade(s, "suite-impact.sh not found: "+script)
		}
	}
	r, why := c.resolveRange()
	if why != "" {
		return degrade(s, why)
	}
	d, why := c.loadDiff(r)
	if why != "" {
		return degrade(s, why)
	}
	header := c.bindingHeader(r, d.changes)
	switch {
	case o.printBinding:
		fmt.Fprintln(s.Out, header)
		return exitOK
	case o.write:
		return c.write(header)
	}
	return c.check(r, d, header, script)
}

// resolveRange verifies the refs and fixes what the diff is taken against. The second result is the degraded reason.
func (c *ctx) resolveRange() (rangeSpec, string) {
	o := c.o
	if !c.git("rev-parse", "--verify", "--quiet", o.base+"^{commit}").OK() {
		return rangeSpec{}, "bad base ref: " + o.base
	}
	if o.worktree {
		mb := c.git("merge-base", o.base, "HEAD")
		if !mb.OK() {
			return rangeSpec{}, "no merge-base of " + o.base + " and HEAD"
		}
		return rangeSpec{worktree: true, base: strings.TrimRight(mb.Out, "\n")}, ""
	}
	if !c.git("rev-parse", "--verify", "--quiet", o.head+"^{commit}").OK() {
		return rangeSpec{}, "bad head ref: " + o.head
	}
	return rangeSpec{base: o.base, head: o.head}, ""
}

// write is --write-teeth-log: the timeout, the directory, then each suite's log.
func (c *ctx) write(header string) int {
	limit, ok := timeoutSeconds(c.s.Env("KIT_WRITER_CHECK_TIMEOUT"))
	if !ok {
		return degrade(c.s, fmt.Sprintf("KIT_WRITER_CHECK_TIMEOUT must be a positive integer, got: '%s'", c.s.Env("KIT_WRITER_CHECK_TIMEOUT")))
	}
	if err := os.MkdirAll(kitmaint.Abs(c.s.Cwd, c.o.writeDir), 0o755); err != nil {
		return degrade(c.s, "cannot create teeth-log dir: "+c.o.writeDir)
	}
	dir, err := kitmaint.ResolveDir(c.s.Cwd, c.o.writeDir)
	if err != nil {
		return degrade(c.s, "cannot create teeth-log dir: "+c.o.writeDir)
	}
	return c.writeLogs(dir, header, limit)
}
