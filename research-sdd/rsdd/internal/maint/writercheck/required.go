package writercheck

import (
	"regexp"
	"sort"
	"strings"
)

// suiteGlobs are the git pathspecs that find the suites naming a changed file directly.
var suiteGlobs = []string{"research-sdd/toolbelt/tests/*.test.sh", "research-sdd/install/tests/*.test.sh"}

// changedSuite is a changed suite path: `research-sdd/*/tests/*.test.sh` (a `*` crosses `/`), not a fixture.
var changedSuite = regexp.MustCompile(`^research-sdd/.*/tests/.*\.test\.sh$`)

const (
	noSuiteDetail  = "no suite names this changed file"
	requiredZero   = "required: 0 (no changed production script and no changed suite; the impact map found nothing to require)"
	fullNotePrefix = "full-gate-needed: "
)

// requirement is what a change obliges: the sorted suites, the notes and the findings the derivation raised.
type requirement struct {
	suites   []string
	notes    []string
	findings []finding
}

// require derives the required suites: for each changed production script the suites suite-impact maps it to (its
// closure, small by construction when it does not escalate) or, under a FULL escalation (a widely used file reaches
// most of the corpus), the suites that name the file directly, falling back to the map when none does; a production
// script no suite names is a `no-suite` finding. Every changed suite is required too.
func (c *ctx) require(r rangeSpec, changes []change, imp impact) requirement {
	var q requirement
	set := map[string]bool{}
	for _, f := range productionFiles(changes) {
		suites := []string(nil)
		if imp.fullReason != "" {
			suites = c.directSuites(r, f)
		}
		if len(suites) == 0 { // not escalated, or escalated but no suite names the file: whatever the map reaches
			suites = imp.suitesOf(f)
		}
		if len(suites) == 0 {
			q.findings = append(q.findings, finding{"no-suite", f, noSuiteDetail})
		}
		for _, s := range suites {
			set[s] = true
		}
	}
	for _, p := range changedSuites(changes) {
		set[p] = true
	}
	for s := range set {
		q.suites = append(q.suites, s)
	}
	sort.Strings(q.suites)
	if imp.fullReason != "" {
		q.notes = append(q.notes, fullNotePrefix+imp.fullReason)
	}
	if len(q.suites) == 0 {
		q.notes = append(q.notes, requiredZero)
	}
	return q
}

// livePath is the path a change leaves behind (the new one of a rename), "" for a deletion.
func livePath(ch change) string {
	if ch.status[0] == 'D' {
		return ""
	}
	return ch.path
}

// productionFiles are the changed production scripts, sorted and unique.
func productionFiles(changes []change) []string {
	return uniqueSorted(changes, func(p string) bool { return isProduction(p) })
}

// changedSuites are the changed suites (not fixtures), sorted and unique.
func changedSuites(changes []change) []string {
	return uniqueSorted(changes, func(p string) bool { return changedSuite.MatchString(p) && !strings.Contains(p, "/fixtures/") })
}

func uniqueSorted(changes []change, keep func(string) bool) []string {
	set := map[string]bool{}
	for _, ch := range changes {
		if p := livePath(ch); p != "" && keep(p) {
			set[p] = true
		}
	}
	var out []string
	for p := range set {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// directSuites are the suites whose text names the basename of file as a word: in the working tree (untracked files
// included) or at the head ref.
func (c *ctx) directSuites(r rangeSpec, file string) []string {
	bn := file[strings.LastIndex(file, "/")+1:]
	args := []string{"grep", "-l", "-z", "-F", "-w"}
	if r.worktree {
		args = append(args, "--untracked", "-e", bn)
	} else {
		args = append(args, "-e", bn, r.head)
	}
	args = append(args, "--")
	res := c.git(append(args, suiteGlobs...)...)
	var out []string
	for _, l := range strings.Split(res.Out, "\x00") {
		if !r.worktree {
			l = strings.TrimPrefix(l, r.head+":") // git names a path of a ref as <ref>:<path>
		}
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}
