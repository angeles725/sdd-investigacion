package corpus

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// The secrets gate scans every regular file under the physical target (the working tree as it sits on disk, git-ignored
// files included, symlinks not followed, `.git` not authored content) through scan-secrets.sh --files-from, and, for a
// target that is itself a git repository root with at least one commit, the committed history too. See the header of the
// retired script for the git states told apart (kit issues #970, #1014, #1015); each branch below keeps its text.

// archiveWalkFiles is the default packaging list: `find root \( -name .git -type d \) -prune -o -type f -print0`.
// perm counts unreadable directories; any other read error means the list is not computable.
func archiveWalkFiles(root string) (paths []string, perm int, err error) {
	var walk func(dir string) error
	walk = func(dir string) error {
		ents, rerr := os.ReadDir(dir)
		if rerr != nil {
			if errors.Is(rerr, fs.ErrPermission) {
				perm++
				return nil
			}
			return rerr
		}
		for _, e := range ents {
			p := dir + "/" + e.Name()
			switch {
			case e.IsDir():
				if e.Name() == ".git" {
					continue
				}
				if werr := walk(p); werr != nil {
					return werr
				}
			case e.Type().IsRegular():
				paths = append(paths, p)
			}
		}
		return nil
	}
	if err = walk(root); err != nil {
		return nil, 0, err
	}
	sort.Strings(paths)
	return paths, perm, nil
}

// archiveSSBuildList writes the packaging list (NUL separated) to a temp file: 0 ready, 1 not computable, 2 computed but
// empty, 3 the physical target is unknown.
func (e *archiveEnv) archiveSSBuildList() int {
	e.ssUnreadable = 0
	if e.ssPhys == "" {
		return 3
	}
	f, err := os.CreateTemp(e.archiveTmpDir(), "tmp.")
	if err != nil {
		return 1
	}
	e.ssList = f.Name()
	defer f.Close()
	paths, perm, werr := e.hooks.walk(e.ssPhys)
	if werr != nil {
		return 1
	}
	if perm > 0 {
		e.ssUnreadable = perm
		e.warn("WARN: scan-secrets packaging list skipped %d unreadable path(s) — unreadable by this process, not scanned", perm)
	}
	var b strings.Builder
	for _, p := range paths {
		b.WriteString(p)
		b.WriteByte(0)
	}
	if _, err := f.WriteString(b.String()); err != nil {
		return 1
	}
	if len(paths) == 0 {
		return 2
	}
	return 0
}

// archiveSSWTScan sets ssWTRC to scan-secrets.sh's code over the packaging list; 90 = list not computable, 91 = empty.
func (e *archiveEnv) archiveSSWTScan() {
	rc := e.archiveSSBuildList()
	switch rc {
	case 0:
		e.ssWTRC = e.archiveSibling("scan-secrets.sh", "--files-from", e.ssList, e.ssPhys)
	case 3:
		e.ssWTRC = 90
		e.ssWhy = "the target directory could not be resolved physically (cd -P failed) — refusing rather than scanning an unknown location"
	case 1:
		e.ssWTRC = 90
		e.ssWhy = "the packaging list could not be computed (find failed) — refusing rather than scanning an unknown file set"
	default:
		e.ssWTRC = 91
		e.ssWhy = "the packaging list is EMPTY (no file under the target) — refusing rather than reporting a scan that looked at nothing"
	}
}

func (e *archiveEnv) archiveSSDegradedNote(rc int) string {
	if rc == 3 {
		return " — DEGRADED: an unreadable in-scope file or a grep read error, scan incomplete"
	}
	return ""
}

// archiveSSUnscanned prints the degraded verdict of a scan that skipped unreadable paths and fails the gate: a gate
// that could not look at every path is never a pass (kit issue #2633, the same rule as AR-VCORR). It reports whether
// it applied; ctx is the suffix of the working-tree-only verdict.
func (e *archiveEnv) archiveSSUnscanned(ctx string) bool {
	if e.ssUnreadable == 0 {
		return false
	}
	e.say("    scan-secrets  : DEGRADED — %d unreadable path(s) not scanned; the corpus was NOT fully checked for secret values%s", e.ssUnreadable, ctx)
	e.gateRC = 1
	return true
}

// archiveSSWTOnlyVerdict is the verdict for a working-tree-only scan; ctx is the suffix for the ok/FAIL/ERROR lines.
func (e *archiveEnv) archiveSSWTOnlyVerdict(ctx string) {
	switch e.ssWTRC {
	case 0:
		if !e.archiveSSUnscanned(ctx) {
			e.say("    scan-secrets  : ok%s", ctx)
		}
	case 1:
		e.say("    scan-secrets  : FAIL — a high-confidence secret VALUE leaked into the working tree%s (SECRETS DISCIPLINE)", ctx)
		e.gateRC, e.ssLeakWT = 1, true
	case 90, 91:
		e.say("    scan-secrets  : ERROR — %s%s", e.ssWhy, ctx)
		e.gateRC = 1
	default:
		e.say("    scan-secrets  : ERROR — scan-secrets.sh did not run cleanly (exit %d)%s%s", e.ssWTRC, e.archiveSSDegradedNote(e.ssWTRC), ctx)
		e.gateRC = 1
	}
}

func (e *archiveEnv) archiveSecretsGate() {
	if p, ok := e.hooks.phys(e.target); ok {
		e.ssPhys = p
	}
	if !e.archiveHaveGit() {
		e.say("    scan-secrets  : ERROR — git not found on PATH — cannot tell whether $target is a git repository (needed to also scan committed history) — refusing rather than silently scanning the working tree only")
		e.gateRC = 1
		return
	}
	topOut, topRC := e.archiveGitCombined(e.target, "rev-parse", "--show-toplevel")
	topOut = archiveCmdSub(topOut)
	_, dotGitErr := os.Stat(filepath.Join(e.target, ".git"))
	switch {
	case topRC != 0 && strings.Contains(strings.ToLower(topOut), "not a git repository") && dotGitErr != nil:
		// confirmed NOT a git repo: working-tree-only fallback over the packaging list
		e.archiveSSWTScan()
		e.archiveSSWTOnlyVerdict("")
	case topRC != 0:
		e.say("    scan-secrets  : ERROR — could not determine whether $target is a git repository (git rev-parse --show-toplevel: %s) — refusing rather than guessing", archiveCutBytes(archiveFirstLine(topOut), 160))
		e.gateRC = 1
	case e.archivePhysOf(topOut) != e.ssPhys: // SS-NESTED-PHYSICAL
		e.warn("WARN: history not scanned — target is inside enclosing repo %s", topOut)
		e.archiveSSWTScan()
		e.archiveSSWTOnlyVerdict(" (working tree only — target nested inside " + topOut + ", see WARN above)")
	case e.archiveUnborn():
		e.warn("WARN: history not scanned — repository has no commits yet")
		e.archiveSSWTScan()
		e.archiveSSWTOnlyVerdict(" (working tree only — repository has no commits yet, see WARN above)")
	default:
		e.archiveSSWTScan()
		histRC := e.archiveSibling("scan-secrets.sh", "--committed", e.target)
		where := ""
		if e.ssWTRC == 1 {
			where = "the working tree"
		}
		if histRC == 1 {
			if where != "" {
				where += " and committed history"
			} else {
				where = "committed history"
			}
		}
		switch {
		case where != "":
			e.say("    scan-secrets  : FAIL — a high-confidence secret VALUE leaked into %s (SECRETS DISCIPLINE)", where)
			e.gateRC = 1
			e.ssLeakWT, e.ssLeakHist = e.ssWTRC == 1, histRC == 1
		case e.ssWTRC == 90 || e.ssWTRC == 91:
			e.say("    scan-secrets  : ERROR — %s", e.ssWhy)
			e.gateRC = 1
		case e.ssWTRC != 0 || histRC != 0:
			e.say("    scan-secrets  : ERROR — did not run cleanly (working-tree rc=%d, committed-history rc=%d)%s — check git/awk/tr are available and $target has at least one commit", e.ssWTRC, histRC, e.archiveSSDegradedNote(e.ssWTRC))
			e.gateRC = 1
		case e.archiveSSUnscanned(""):
		default:
			e.say("    scan-secrets  : ok")
		}
	}
}

// archivePhysOf is `cd -P p && pwd -P`, empty when it fails.
func (e *archiveEnv) archivePhysOf(p string) string {
	r, _ := e.hooks.phys(p)
	return r
}

// archiveUnborn is the unborn-repository test: no HEAD and no ref anywhere (`git init` without a commit, #1014).
func (e *archiveEnv) archiveUnborn() bool {
	if _, rc := e.archiveGit(e.target, "rev-parse", "--verify", "-q", "HEAD"); rc == 0 {
		return false
	}
	refs, rc := e.archiveGit(e.target, "for-each-ref", "--count=1", "refs/")
	return rc == 0 && archiveCmdSub(refs) == ""
}

func (e *archiveEnv) archiveCleanup() {
	if e.ssList != "" {
		_ = os.Remove(e.ssList)
	}
}
