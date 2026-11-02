package gate

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// The change and retro scans of the gate. Every scan keeps the predicate of the command it replaces (see
// retrogatewalk.go); a deliberately unsorted directory order is the order `find` printed.

// reRetroPath is `grep -qE '(^|/)retros/[^/].*\.md$'` on one line of a path.
var reRetroPath = regexp.MustCompile(`(^|/)retros/[^/].*\.md$`)

// retroPathOK is the shared qualifier of a git-listed retro path (committed, staged or untracked): under a retros/
// directory at any depth, and not an index file (-iname '*index*.md', applied to any base name here as in the bash).
func retroPathOK(p string) bool {
	matched := false
	for _, line := range strings.Split(p, "\n") { // grep works per line, and a path can hold a newline
		if reRetroPath.MatchString(line) {
			matched = true
			break
		}
	}
	return matched && !strings.Contains(asciiLower(baseName(p)), "index")
}

// isResearchFile is _is_research_file: not a copy in a nested worktree, and a block file, RESEARCH-STATE*.md,
// CATALOG.md or INDEX.md.
func (g *retroGate) isResearchFile(p string) bool {
	if g.inNested(p) {
		return false
	}
	if _, err := kit.FilterBlockFiles(kit.SplitLines(p+"\n"), false, ""); err == nil {
		return true
	}
	base := baseName(p)
	return (strings.HasPrefix(base, "RESEARCH-STATE") && strings.HasSuffix(base, ".md")) || base == "CATALOG.md" || base == "INDEX.md"
}

// isDirLink is `[ -L p ] && [ -d p ]`.
func isDirLink(p string) bool {
	li, err := os.Lstat(p)
	if err != nil || li.Mode()&fs.ModeSymlink == 0 {
		return false
	}
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// detectChanges runs Parts A, B and C: did a research file change since the session start. Part A (committed or
// staged changes against the session sha) runs only with a sha; Part B (files newer than the session file) with a
// session file; Part C follows directory symlinks one hop.
func (g *retroGate) detectChanges(sessionFile string) bool {
	changed := false
	if !g.degraded { // Part A
		for _, f := range g.gitLines("diff", "--cached", "--relative", "--name-only", g.sessionSHA) {
			if f == "" {
				continue
			}
			full := g.target + "/" + f
			if g.isResearchFile(full) {
				changed = true
			}
			if isDirLink(full) && !g.inNested(full) { // RG-DIRLINK-ADDED
				changed = true
			}
		}
	}
	ref, err := os.Stat(sessionFile)
	hasSession := err == nil && ref.Mode().IsRegular()
	if hasSession && !changed { // Part B: stops at the first research file, the walk has no other effect
		changed = g.newerResearch(g.target, ref.ModTime(), true)
	}
	// The timeout is validated on every run that gets this far, like the bash, whether or not Part C runs.
	timeout, label := g.dirlinkTimeout()
	if !g.degraded && hasSession { // Part C
		if g.dirlinkScan(ref.ModTime(), timeout, label) {
			changed = true
		}
	}
	return changed
}

// newerResearch is `find -H root -newer ref -type f -name '*.md' -not -path '*/.git/*'` filtered by
// _is_research_file; it reports whether any file qualified. With prune a directory that cannot hold a qualifying
// file (a .git directory, a nested worktree) is not entered: the result is the same, the walk is cheaper.
func (g *retroGate) newerResearch(root string, ref time.Time, prune bool) bool {
	found := false
	findWalk(context.Background(), root, walkNoLimit, nil, func(p string, typ fs.FileMode, _ int) walkCtl {
		if typ.IsDir() {
			if prune && (lastSegment(p) == ".git" || g.inNested(p)) {
				return walkSkip
			}
			return walkOn
		}
		if typ.IsRegular() && strings.HasSuffix(p, ".md") && !hasGitSegment(p) && newerThan(p, ref) && g.isResearchFile(p) {
			found = true
			return walkStop
		}
		return walkOn
	})
	return found
}

func newerThan(p string, ref time.Time) bool {
	st, err := os.Lstat(p)
	return err == nil && st.ModTime().After(ref)
}

// mtimeOf is `stat -c %Y p || echo 0`: the mtime of the entry itself (a symlink is not followed), in seconds.
func mtimeOf(p string) int64 {
	st, err := os.Lstat(p)
	if err != nil {
		return 0
	}
	return st.ModTime().Unix()
}

// newestBlockMtime is the degraded-mode reference: the newest research file, CATALOG.md excepted (it is generated
// seconds after the retro, #1229). -type f never matches a symlink entry.
func (g *retroGate) newestBlockMtime() int64 {
	nb := int64(0)
	findWalk(context.Background(), g.target, walkNoLimit, nil, func(p string, typ fs.FileMode, _ int) walkCtl {
		if typ.IsDir() {
			if lastSegment(p) == ".git" || g.inNested(p) {
				return walkSkip
			}
			return walkOn
		}
		if typ.IsRegular() && strings.HasSuffix(p, ".md") && !hasGitSegment(p) && g.isResearchFile(p) && baseName(p) != "CATALOG.md" {
			if m := mtimeOf(p); m > nb {
				nb = m
			}
		}
		return walkOn
	})
	return nb
}

// retroOK is the filter every retro candidate passes: a file, not in a nested worktree, not excluded.
func (g *retroGate) retroOK(full string) bool {
	if !isRegular(full) || g.inNested(full) {
		return false
	}
	return !isExcludedRetro(full)
}

// isExcludedRetro is retro_is_excluded.
func isExcludedRetro(p string) bool {
	d, err := retrogrammar.Read(p)
	return err == nil && retrogrammar.IsExcluded(d)
}

// newestRetro finds the newest qualifying retro and its mtime (seconds). With a session sha a retro qualifies when
// it was ADDED since the session start (committed or staged, renames excluded) or is a file under a retros/
// directory newer than the session file (covers untracked and gitignored ones). Depth is unbounded here. Degraded
// runs fall back to `find -maxdepth 4` and the mtime comparison.
func (g *retroGate) newestRetro(sessionFile string) (newest string, mtime int64) {
	consider := func(full string) {
		if m := mtimeOf(full); m > mtime {
			mtime, newest = m, full
		}
	}
	if g.degraded {
		for _, rf := range g.findRetros(true) {
			if g.inNested(rf) || isExcludedRetro(rf) {
				continue
			}
			consider(rf)
		}
		return newest, mtime
	}
	// (a) -M forces rename detection on whatever diff.renames says, so a renamed old retro (R) never counts as added.
	for _, rpath := range g.gitLines("diff", "--cached", "--relative", "--name-only", "--diff-filter=A", "-M", g.sessionSHA) {
		if rpath == "" || !retroPathOK(rpath) {
			continue
		}
		if full := g.target + "/" + rpath; g.retroOK(full) {
			consider(full)
		}
	}
	// (b) untracked and gitignored retros newer than the session file: ls-files --others without
	// --exclude-standard, so tracked (committed or staged) files stay out and a git-mv-ed retro is not "new".
	ref, err := os.Stat(sessionFile)
	if err != nil || !ref.Mode().IsRegular() {
		return newest, mtime
	}
	for _, rpath := range g.gitLines("ls-files", "--others") {
		if rpath == "" || !retroPathOK(rpath) {
			continue
		}
		full := g.target + "/" + rpath
		if !isRegular(full) {
			continue
		}
		if st, err := os.Stat(full); err != nil || !st.ModTime().After(ref.ModTime()) { // [ -nt ]
			continue
		}
		if g.retroOK(full) {
			consider(full)
		}
	}
	return newest, mtime
}

// findRetros is `find -H TARGET -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' -not -iname '*index*.md'`
// in find's order. quiet drops the traversal errors (2>/dev/null); the issue-seeding scan lets them through.
func (g *retroGate) findRetros(quiet bool) []string {
	var out []string
	res := findWalk(context.Background(), g.target, 4, nil, func(p string, _ fs.FileMode, _ int) walkCtl {
		if matchRetroPath(p) && !hasGitSegment(p) && !matchIndexName(baseName(p)) {
			out = append(out, p)
		}
		return walkOn
	})
	if !quiet {
		for _, e := range res.errs {
			g.errf("%s\n", e)
		}
	}
	return out
}

// ── Part C: directory symlinks (#1311, #1352, #1404) ─────────────────────────

var (
	reDLTimeout = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?$`)
	reDLZero    = regexp.MustCompile(`^0+(\.0+)?$`)
)

// dirlinkTimeout is RETRO_GATE_DIRLINK_TIMEOUT: a positive number of seconds, else a typed WARN and the 5 s
// default (0 would be an unbounded walk on a Stop hook, a non-number a failed walk).
func (g *retroGate) dirlinkTimeout() (time.Duration, string) {
	v := g.s.Env("RETRO_GATE_DIRLINK_TIMEOUT")
	if v == "" {
		v = "5"
	}
	if !reDLTimeout.MatchString(v) || reDLZero.MatchString(v) {
		g.errf("retro-gate: WARN: RETRO_GATE_DIRLINK_TIMEOUT='%s' is not a positive number — using the default 5 s\n", v)
		v = "5"
	}
	f, _ := strconv.ParseFloat(v, 64)
	return time.Duration(f * float64(time.Second)), v
}

// scratchAvailable is the old `mktemp` probe: Part C needs a scratch file to run, and without one the scan is
// skipped with ONE typed WARN. Here the scan keeps its results in memory; the probe keeps the failure mode (an
// unusable TMPDIR) and leaves nothing behind.
func (g *retroGate) scratchAvailable() bool {
	dir := g.s.Env("TMPDIR")
	if dir == "" {
		dir = "/tmp"
	}
	f, err := os.CreateTemp(dir, "tmp.")
	if err != nil {
		return false
	}
	_ = f.Close()
	_ = os.Remove(f.Name())
	return true
}

// dirlinkScan is Part C: a research directory that is a SYMLINK inside the target is invisible to Parts A and B,
// so each such link is followed ONE hop and Part B's rule applied behind it. Candidates come from git (tracked
// mode-120000 entries plus untracked non-ignored paths); when git cannot enumerate, a bounded find over the target
// is the fallback. A gitignored link is never enumerated (documented tradeoff). It reports whether research
// changed behind a link.
func (g *retroGate) dirlinkScan(ref time.Time, timeout time.Duration, label string) bool {
	tgt, err := filepath.EvalSymlinks(g.target)
	if err != nil {
		tgt = g.target
	}
	homeDir := g.s.Env("HOME")
	if homeDir == "" {
		homeDir = "/nonexistent"
	}
	home := ""
	if h, err := filepath.EvalSymlinks(homeDir); err == nil {
		home = h
	}
	var cands []string
	if !g.scratchAvailable() { // SENTINEL-DIRLINK-SCRATCH
		g.errf("retro-gate: WARN: directory-symlink scan skipped: cannot create a scratch file (mktemp failed) for %s — symlinked research directories not scanned\n", baseName(g.target))
		g.unverif = 1
		return false
	}
	if c, ok := g.gitLinkCandidates(); ok {
		cands = c
	} else {
		cands = g.findLinkCandidates(timeout, label)
	}
	changed := false
	for _, lnk := range cands {
		if lnk == "" {
			continue
		}
		lr, err := filepath.EvalSymlinks(lnk)
		if err != nil {
			continue
		}
		if lr == "/" || lr == home || (lr != tgt && strings.HasPrefix(tgt, lr+"/")) { // RG-DIRLINK-ANCESTOR
			g.errf("retro-gate: WARN: directory symlink %s resolves to %s (/, $HOME or an ancestor of the target) — not scanned\n", strings.TrimPrefix(lnk, g.target+"/"), lr)
			continue
		}
		if lr == tgt || strings.HasPrefix(lr, tgt+"/") { // RG-DIRLINK-INSIDE: parts A and B already cover it
			continue
		}
		if g.inNested(lnk) {
			continue
		}
		rc, files := g.linkWalk(lnk, ref, timeout)
		if rc != 0 { // RG-DIRLINK-WALK-WARN
			g.unverif = 1
			g.errf("retro-gate: WARN: directory-symlink walk incomplete (rc=%d) under %s — research behind it may be missed\n", rc, strings.TrimPrefix(lnk, g.target+"/"))
		}
		for _, f := range files {
			if g.isResearchFile(f) {
				changed = true
			}
		}
	}
	return changed
}

// gitLinkCandidates is the git leg: `ls-files -s -z` (mode 120000) plus `ls-files -o --exclude-standard -z`, each
// path kept when it is a symlink to a directory. NUL-delimited end to end, so a name with a newline is one path.
// ok is false when git could not enumerate.
func (g *retroGate) gitLinkCandidates() ([]string, bool) {
	tracked, err := g.runner().Run(g.target, "ls-files", "-s", "-z")
	if err != nil {
		return nil, false
	}
	untracked, err := g.runner().Run(g.target, "ls-files", "-o", "--exclude-standard", "-z")
	if err != nil {
		return nil, false
	}
	var paths []string
	for _, rec := range strings.Split(string(tracked), "\x00") {
		if _, p, ok := strings.Cut(rec, "\t"); ok && strings.HasPrefix(rec, "120000 ") {
			paths = append(paths, p)
		}
	}
	for _, rec := range strings.Split(string(untracked), "\x00") {
		if rec != "" {
			paths = append(paths, rec)
		}
	}
	var cands []string
	for _, p := range paths {
		if isDirLink(g.target + "/" + p) {
			cands = append(cands, strings.TrimSuffix(g.target, "/")+"/"+p)
		}
	}
	return cands, true
}

// findLinkCandidates is the fallback: `timeout T find -H TARGET -path '*/.git' -prune -o -type l -xtype d -print0`.
func (g *retroGate) findLinkCandidates(timeout time.Duration, label string) []string {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	var cands []string
	res := findWalk(ctx, g.target, walkNoLimit, g.hooks.onEntry, func(p string, typ fs.FileMode, _ int) walkCtl {
		if strings.HasSuffix(p, "/.git") {
			return walkSkip
		}
		if typ&fs.ModeSymlink != 0 {
			if st, err := os.Stat(p); err == nil && st.IsDir() {
				cands = append(cands, p)
			}
		}
		return walkOn
	})
	rc := res.rc
	if rc != 0 {
		g.unverif = 1
	}
	switch rc {
	case 0:
	case 124:
		g.errf("retro-gate: WARN: directory-symlink scan timed out after %ss for %s — symlinked research directories not scanned\n", label, baseName(g.target))
	default:
		g.errf("retro-gate: WARN: directory-symlink scan incomplete (rc=%d) for %s — symlinked research directories may be missed\n", rc, baseName(g.target))
	}
	return cands
}

// linkWalk is `timeout T find -H LINK -newer REF -type f -name '*.md' -not -path '*/.git/*'`: the files and the
// status of the walk (the partial list of a timed-out walk is kept, as the bash read what find had printed).
func (g *retroGate) linkWalk(lnk string, ref time.Time, timeout time.Duration) (int, []string) {
	if g.hooks.walkRC != nil {
		if rc := g.hooks.walkRC(lnk); rc != 0 {
			return rc, nil
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	var files []string
	res := findWalk(ctx, lnk, walkNoLimit, g.hooks.onEntry, func(p string, typ fs.FileMode, _ int) walkCtl {
		if typ.IsRegular() && strings.HasSuffix(p, ".md") && !hasGitSegment(p) && newerThan(p, ref) {
			files = append(files, p)
		}
		return walkOn
	})
	return res.rc, files
}
