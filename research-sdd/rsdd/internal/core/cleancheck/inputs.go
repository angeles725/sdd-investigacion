package cleancheck

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// resolveInputs is everything the script settled before it scanned anything: the git probe, the owner uid, the
// target and the tmp directory. It reports false once the run has ended (res holds the verdict).
func (r *run) resolveInputs() bool {
	r.env = gitEnvironment(r.o.Env)
	if len(kitmaint.MissingDeps(r.env, r.o.Cwd, "git")) > 0 {
		// REQUIRED_TOOLS of the script was `git find date sort id stat`; only git is still a dependency.
		r.stderr("clean-check: DEGRADED: git not found on PATH; nothing was measured")
		r.res.Verdict, r.res.Exit = Degraded, 3
		r.res.Degraded = append(r.res.Degraded, DegradedGit)
		return false
	}
	return r.resolveUID() && r.resolveTarget() && r.resolveTmp()
}

func (r *run) resolveUID() bool {
	raw := r.o.UID
	if raw == "" {
		self := os.Getuid
		if r.o.Self != nil {
			self = r.o.Self
		}
		raw = strconv.Itoa(self())
	}
	n, err := strconv.ParseUint(raw, 10, 63)
	if err != nil {
		return r.refuse("cannot determine the owner uid ('" + raw + "')")
	}
	r.uid = n
	return true
}

func (r *run) resolveTarget() bool {
	r.target = r.o.Target
	if r.target == "" {
		r.target = r.o.Cwd
	}
	if !kitmaint.IsDir(kitmaint.Abs(r.o.Cwd, r.target)) {
		return r.refuse("target not found: " + r.target)
	}
	p, err := physical(r.o.Cwd, r.target)
	if err != nil {
		return r.refuse("cannot enter target: " + r.target)
	}
	r.targetP = p
	// stdout alone decides: a git that succeeds may still warn on stderr. A failure carries git's own reason.
	g := r.git("rev-parse", "--is-inside-work-tree")
	if g.rc != 0 {
		msg := oneLine(strings.TrimRight(g.err, "\n"))
		if msg == "" {
			msg = "git exited non-zero without output"
		}
		return r.refuse("git rev-parse failed for target " + r.target + ": " + msg)
	}
	if g.trimmed() != "true" {
		return r.refuse("target is not inside a git work tree: " + r.target)
	}
	return true
}

func (r *run) resolveTmp() bool {
	r.tmp = r.o.Tmp
	if r.tmp == "" {
		if v, _ := envValue(r.o.Env, "TMPDIR"); v != "" {
			r.tmp = v
		} else {
			r.tmp = "/tmp"
		}
	}
	r.tmp = strings.TrimSuffix(r.tmp, "/") // one slash, as ${TMPD%/}
	if r.tmp == "" {
		r.tmp = "/"
	}
	if !kitmaint.IsDir(kitmaint.Abs(r.o.Cwd, r.tmp)) {
		return r.refuse("tmp dir not found: " + r.tmp)
	}
	p, err := physical(r.o.Cwd, r.tmp)
	if err != nil {
		return r.refuse("cannot enter tmp dir: " + r.tmp)
	}
	r.tmpP = p
	return true
}

// physical is `cd -P -- p && pwd -P`: p made absolute against cwd, every symlink and dot-dot resolved on disk.
func physical(cwd, p string) (string, error) {
	return filepath.EvalSymlinks(kitmaint.Abs(cwd, p))
}
