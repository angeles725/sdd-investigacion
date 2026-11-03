package reconcile

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

// The closed-issue classes of reconcile-issues.sh (kit issues #1555, #1709, #1773): a row with no OPEN issue may
// have shipped through an issue closed as completed. This file holds the closed-cache record reader, the
// closure-evidence grammar and the git reachability probe; classify (audit.go) applies them.

const recordSep = "\x1e"

// closedRecords is _closed_record: the records (issues) of the closed-issue bodies that carry the exact signature
// "Source retro: <prefix> · <row>" for this row, concatenated, each line closed by a newline. With a record
// separator line anywhere in the bodies only separators split issues (a real issue carries its signature as a
// footer); without one a record runs from a "Source retro: " line to the next, and the lines before the first
// such line belong to no record - ignored counts them for the typed note.
func closedRecords(bodies, prefix, rowID string) (rec string, ignored int) {
	lines := strings.Split(bodies, "\n")
	sep := slices.Contains(lines, recordSep)
	pfx := "Source retro: " + prefix + " · "
	var cur, out strings.Builder
	hit, started := false, false
	flush := func() {
		if hit {
			out.WriteString(cur.String())
		}
		cur.Reset()
		hit = false
	}
	for _, l := range lines {
		if l == recordSep {
			flush()
			continue
		}
		if !sep {
			if strings.Contains(l, "Source retro: ") { // RECONCILE-RECORD-SIGSPLIT
				flush()
				started = true
			}
			if !started { // RECONCILE-RECORD-PREAMBLE
				ignored++
				continue
			}
		}
		cur.WriteString(l + "\n")
		if p := strings.Index(l, pfx); p >= 0 && leadingID(l[p+len(pfx):]) == rowID && rowID != "" {
			hit = true
		}
	}
	flush()
	return out.String(), ignored
}

var (
	reCommitWord = regexp.MustCompile(`(?i)(^|[^[:alnum:]])commits?([^[:alnum:]]|$)`)
	reTestWord   = regexp.MustCompile(`(?i)(^|[^[:alnum:]])tests?([^[:alnum:]]|$)`)
	reTestPath   = regexp.MustCompile(`\.test\.|_test\.|test_|/tests?/|(^|[^[:alnum:]])tests?/`)
)

// evidenceCommits is _evidence_commits: the hex tokens of 7 to 40 characters with at least one digit, found on
// the lines that name a commit, sorted bytewise and unique.
func evidenceCommits(rec string) []string {
	var out []string
	for _, l := range strings.Split(rec, "\n") {
		if !reCommitWord.MatchString(l) {
			continue
		}
		start := -1
		for i := 0; i <= len(l); i++ {
			if i < len(l) && isHex(l[i]) {
				if start < 0 {
					start = i
				}
				continue
			}
			if start >= 0 {
				if tok := l[start:i]; len(tok) >= 7 && len(tok) <= 40 && strings.ContainsAny(tok, "0123456789") {
					out = append(out, tok)
				}
				start = -1
			}
		}
	}
	slices.Sort(out)
	return slices.Compact(out)
}

func isHex(c byte) bool { return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F' }

// evidenceHasTest is _evidence_has_test: a path-like test token on a line that names a test.
func evidenceHasTest(rec string) bool {
	for _, l := range strings.Split(rec, "\n") {
		if reTestWord.MatchString(l) && reTestPath.MatchString(l) {
			return true
		}
	}
	return false
}

// session is the state one run shares across the retros it audits: the ancestry probe is lazy and runs once, and
// the shallow-clone rows are counted for ONE run-level note.
type session struct {
	runner  git.Runner
	gitDir  string
	mainRef string

	probed    bool
	gitOK     bool
	shallow   int
	shallowEg string
}

func newSession(kitRoot string, env func(string) string) *session {
	s := &session{gitDir: kitRoot, mainRef: "origin/main"}
	if v := env("RECONCILE_ISSUES_GIT_DIR"); v != "" {
		s.gitDir = v
	}
	if v := env("RECONCILE_ISSUES_MAIN_REF"); v != "" {
		s.mainRef = v
	}
	var genv []string
	for _, k := range []string{"PATH", "HOME", "LANG", "LC_ALL", "TMPDIR"} {
		if v := env(k); v != "" {
			genv = append(genv, k+"="+v)
		}
	}
	s.runner = git.Runner{Env: genv}
	return s
}

// probe is _git_probe: git present, the dir a repository, the main ref known locally (no fetch). Anything else is
// a typed degraded line, written once; the rows are then reported borderline, never shipped.
func (s *session) probe(r *Report) bool {
	if s.probed {
		return s.gitOK
	}
	s.probed = true
	_, err := s.runner.Run(s.gitDir, "rev-parse", "--git-dir")
	var ee *git.ExitError
	switch {
	case errors.Is(err, git.ErrMissing):
		r.degrade("degraded: git not found on PATH — cannot verify that cited commits reach %s; rows are reported borderline, not shipped", s.mainRef)
		return false
	case errors.As(err, &ee):
		r.degrade("degraded: %s is not a git repository — cannot verify that cited commits reach %s; rows are reported borderline, not shipped", s.gitDir, s.mainRef)
		return false
	case err != nil: // timeout, output cap: could not look is not "not a repository"
		r.degrade("degraded: git could not be run in %s (%v) — cannot verify that cited commits reach %s; rows are reported borderline, not shipped", s.gitDir, err, s.mainRef)
		return false
	}
	if _, ok, err := s.runner.ResolveCommit(s.gitDir, s.mainRef); err != nil && !errors.As(err, &ee) {
		r.degrade("degraded: git could not resolve ref %s in %s (%v) — cannot verify that cited commits reach it; rows are reported borderline, not shipped", s.mainRef, s.gitDir, err)
		return false
	} else if err != nil || !ok {
		r.degrade("degraded: ref %s is not known locally in %s (no fetch is performed) — cannot verify that cited commits reach it; rows are reported borderline, not shipped", s.mainRef, s.gitDir)
		return false
	}
	s.gitOK = true
	return true
}

// verdict is the outcome of the reachability check of one row: reach is the first cited commit that reaches the
// main ref, missing the reasons the evidence is incomplete (joined by "; ").
type verdict struct {
	reach   string
	missing []string
}

// check applies the closure-evidence rule to the closed-issue records of a row (kit issue #1709).
func (s *session) check(r *Report, rec string) verdict {
	var v verdict
	commits := evidenceCommits(rec)
	if len(commits) == 0 {
		v.missing = append(v.missing, "no commit cited")
	}
	if !evidenceHasTest(rec) { // RECONCILE-EVIDENCE-TEST
		v.missing = append(v.missing, "no test cited")
	}
	if len(commits) == 0 {
		return v
	}
	if !s.probe(r) {
		v.missing = append(v.missing, "commit reachability could not be verified (degraded)")
		return v
	}
	// EVERY cited token is evaluated (no early stop), so the result never depends on sort order.
	resolved, eg := false, ""
	for _, c := range commits {
		// The first SHA-looking token (an a-f letter; a date or PR number has none) names the shallow note.
		if eg == "" && strings.ContainsAny(c, "abcdefABCDEF") {
			eg = c
		}
		// Not a commit object locally (date, PR number, fork SHA, ambiguous short SHA): not evidence.
		if _, err := s.runner.Run(s.gitDir, "cat-file", "-e", c+"^{commit}"); err != nil { // RECONCILE-COMMIT-PRESENT
			continue
		}
		resolved = true
		if v.reach == "" {
			if ok, _ := s.runner.IsAncestor(s.gitDir, c, s.mainRef); ok { // RECONCILE-ANCESTRY
				v.reach = c
			}
		}
	}
	// Nothing resolved in a shallow clone: "absent" cannot be told from "not fetched" (kit issue #1773). Counted
	// for ONE run-level note; the row stays borderline and the run is not failed.
	shallow := false
	if !resolved {
		out, _ := s.runner.Run(s.gitDir, "rev-parse", "--is-shallow-repository")
		shallow = strings.TrimRight(string(out), "\n") == "true"
	}
	switch {
	case shallow: // RECONCILE-SHALLOW-NOTE
		s.shallow++
		if s.shallowEg == "" {
			s.shallowEg = eg
		}
		v.missing = append(v.missing, "no cited commit resolves in this shallow clone (not fetched, so reachability cannot be verified)")
	case v.reach == "":
		v.missing = append(v.missing, fmt.Sprintf("no cited commit reachable from local ref %s (no fetch performed; a stale ref reads as unreachable)", s.mainRef))
	}
	return v
}

// shallowNote is _emit_shallow_note: one line per run, never a failure.
func (s *session) shallowNote(r *Report) {
	if s.shallow == 0 {
		return
	}
	eg := ""
	if s.shallowEg != "" {
		eg = " (e.g. " + s.shallowEg + ")"
	}
	r.note("shallow-clone: %s is a shallow clone and no cited commit resolved locally for %d row(s)%s; those rows stay borderline, not shipped — run 'git fetch --unshallow' (or raise the CI fetch-depth) to verify them", s.gitDir, s.shallow, eg)
}
