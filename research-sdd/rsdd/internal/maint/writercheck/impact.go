package writercheck

import (
	"errors"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// impactScript is the suite-impact.sh to run: $KIT_WRITER_CHECK_IMPACT, else the one of the kit this tool belongs to
// (the shim exports it from its own directory; a direct call resolves the kit like the portable hooks do). The empty
// string when neither names a file.
func (c *ctx) impactScript() string {
	if p := c.s.Env("KIT_WRITER_CHECK_IMPACT"); p != "" {
		return p
	}
	if p, _, err := kit.ResolveKitScript("toolbelt/tests/suite-impact.sh", c.s.Env); err == nil {
		return p
	}
	return ""
}

// isFile is `[ -f p ]`.
func isFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

// impact is the report of suite-impact.sh: the escalation reason (empty when it did not escalate) and the suites it
// maps each changed file to.
type impact struct {
	fullReason string
	mapped     map[string][]string
}

// suitesOf are the suites the map names for a changed file, sorted and unique.
func (i impact) suitesOf(file string) []string { return i.mapped[file] }

// runImpact runs suite-impact.sh over the range. The second result is the degraded reason when it could not look: an
// impact map that failed must never read as an empty requirement set.
func (c *ctx) runImpact(script string, r rangeSpec) (impact, string) {
	args := []string{"bash", script, "--repo", c.repo, "--base", c.o.base, "--format", "report"}
	if c.o.manifestDir != "" {
		args = append(args, "--manifest-dir", c.o.manifestDir)
	}
	if c.o.tolerate {
		args = append(args, "--tolerate-stale-manifest")
	}
	if r.worktree {
		args = append(args, "--worktree")
	} else if c.o.headGiven {
		args = append(args, "--head", c.o.head)
	}
	res, err := proc.Run(proc.Spec{Argv: args, Dir: c.s.Cwd, Env: c.env, Timeout: kitmaint.ChildCeiling, MaxBytes: 64 << 20, Now: c.s.Clock})
	if err != nil {
		var se *proc.SpawnError
		if errors.As(err, &se) {
			return impact{}, "bash not found on PATH"
		}
		return impact{}, "suite-impact.sh could not run: " + err.Error()
	}
	rc := res.ReturnCode
	switch {
	case res.Reason != "":
		rc = 124
	case rc < 0:
		rc = 128 - rc
	}
	if rc != 0 {
		msg := strings.ReplaceAll(string(res.Stderr[:min(len(res.Stderr), 300)]), "\n", " ")
		return impact{}, "suite-impact.sh exited " + strconv.Itoa(rc) + ": " + msg
	}
	return parseImpact(string(res.Stdout)), ""
}

// parseImpact reads the report: the first `Escalated to FULL: <reason>` line and every `<changed file> → <suite>`
// line (exactly one arrow, the file under research-sdd/).
func parseImpact(out string) impact {
	imp := impact{mapped: map[string][]string{}}
	seen, gotFull := map[[2]string]bool{}, false
	for _, l := range strings.Split(out, "\n") {
		if r, ok := strings.CutPrefix(l, "Escalated to FULL: "); ok && !gotFull {
			imp.fullReason, gotFull = r, true // the first such line decides, even when its reason is empty
		}
		if f := strings.Split(l, " → "); len(f) == 2 && strings.HasPrefix(f[0], "research-sdd/") && !seen[[2]string{f[0], f[1]}] {
			seen[[2]string{f[0], f[1]}] = true
			imp.mapped[f[0]] = append(imp.mapped[f[0]], f[1])
		}
	}
	for _, s := range imp.mapped {
		sort.Strings(s)
	}
	return imp
}
