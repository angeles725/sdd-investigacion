package gate

import (
	"encoding/json"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// CLOSURE EVIDENCE (kit issue #1812, --merge only): after a SUCCESSFUL `gh pr merge`, ONE comment is posted on
// each issue the PR closes, in the grammar reconcile-issues.sh accepts as shipped evidence (kit issue #1709): a
// `- commit: <merge sha>` line and one `- test: <path>` line per test file the PR changed. The closing-issue
// list comes from GitHub (one bounded GraphQL read of closingIssuesReferences), never from the PR body. The step
// can never fail the run: every failure prints a typed `closure-evidence: degraded: ...` line and the exit
// stays 0.

const closureQuery = `query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){nameWithOwner pullRequest(number:$pr){merged state mergeCommit{oid} closingIssuesReferences(first:50){totalCount nodes{number repository{nameWithOwner}}}}}}`

var (
	repoSlug = regexp.MustCompile(`^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`)
	sha40    = regexp.MustCompile(`^[0-9a-fA-F]{40}$`)
	testFile = regexp.MustCompile(`^research-sdd/(.+/)?tests/[^/]+\.test\.sh$`)
)

func (g *mergeGate) closureEvidence() {
	const ev = "closure-evidence"
	if g.noEvidence {
		g.say("%s: skipped: --no-closure-evidence", ev)
		return
	}

	// ONE repository for the whole step: the one `gh pr merge` used, i.e. GH_REPO when set, else the cwd remote.
	// It is passed explicitly to the read, the files read and every comment, so they can never resolve to
	// different repos.
	var repo string
	if ghRepo, _ := environLookup(g.s.Environ(), "GH_REPO"); ghRepo != "" {
		name := ghRepo[strings.LastIndexByte(ghRepo, '/')+1:]
		owner := ghRepo
		if i := strings.LastIndexByte(ghRepo, '/'); i >= 0 {
			owner = ghRepo[:i]
		}
		owner = owner[strings.LastIndexByte(owner, '/')+1:]
		repo = owner + "/" + name
	} else {
		c := g.r.GHBounded(g.cwd, "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
		repo = cmdSub(string(c.Stdout))
		if c.RC != 0 {
			g.say("%s: degraded: cannot resolve the repository the merge used (gh repo view: %s); nothing posted", ev, firstLine(c.Stderr, 200))
			return
		}
	}
	if !repoSlug.MatchString(repo) {
		g.say("%s: degraded: cannot resolve the repository the merge used (got '%s'); nothing posted", ev, repo)
		return
	}
	owner, name, _ := strings.Cut(repo, "/")

	c := g.r.GHBounded(g.cwd, "api", "graphql", "-F", "owner="+owner, "-F", "name="+name, "-F", "pr="+g.pr, "-f", "query="+closureQuery)
	switch {
	case c.RC == 124:
		g.say("%s: degraded: GraphQL read of PR #%s timed out (bound MERGE_GATE_GH_TIMEOUT, default 30 s); nothing posted", ev, g.pr)
		return
	case c.RC != 0:
		g.say("%s: degraded: cannot read the closing issues of PR #%s (gh api graphql exit %d: %s); nothing posted", ev, g.pr, c.RC, firstLine(c.Stderr, 200))
		return
	}
	vals, _ := jqStream(string(c.Stdout))
	switch jqEach(vals, closureVerdict) {
	case "ok":
	case "notmerged":
		g.say("%s: degraded: PR #%s is not reported merged (merged!=true or state!=MERGED); nothing posted", ev, g.pr)
		return
	case "nooid":
		g.say("%s: degraded: PR #%s has no usable 40-hex merge commit oid; nothing posted", ev, g.pr)
		return
	default:
		g.say("%s: degraded: the GraphQL answer for PR #%s is unparseable or off-schema; nothing posted", ev, g.pr)
		return
	}
	gotRepo := jqEach(vals, pathRaw("data", "repository", "nameWithOwner"))
	if asciiLower(gotRepo) != asciiLower(repo) {
		g.say("%s: degraded: the GraphQL answer is for repository %s but the merge used %s; nothing posted", ev, gotRepo, repo)
		return
	}
	msha := jqEach(vals, pathRaw("data", "repository", "pullRequest", "mergeCommit", "oid"))
	total := jqEach(vals, pathRaw("data", "repository", "pullRequest", "closingIssuesReferences", "totalCount"))
	issues := sortUniqNumeric(jqEach(vals, closureIssues(repo, false)))
	for _, l := range lines(jqEach(vals, closureIssues(repo, true))) {
		if l != "" {
			g.say("%s: note: PR #%s also closes %s in another repository; no evidence posted there", ev, g.pr, l)
		}
	}
	if n, err := strconv.ParseInt(total, 10, 64); err == nil && n > 50 {
		g.say("%s: degraded: PR #%s closes %d issues but only the first 50 were read; backfill the other %d by hand", ev, g.pr, n, n-50)
	}
	if len(issues) == 0 {
		g.say("%s: none: PR #%s closes no issue in %s (closingIssuesReferences has none)", ev, g.pr, repo)
		return
	}

	fc := g.r.GH(g.cwd, "api", "repos/"+repo+"/pulls/"+g.pr+"/files?per_page=100", "--paginate")
	if fc.RC != 0 {
		g.say("%s: degraded: cannot read the files of PR #%s (gh api failed)", ev, g.pr)
		return
	}
	testFiles, ok := changedTestFiles(cmdSub(string(fc.Stdout)))
	if !ok {
		g.say("%s: degraded: files of PR #%s are unparseable or off-schema", ev, g.pr)
		return
	}
	if len(testFiles) == 0 {
		g.say("%s: not posted: PR #%s changes no test file (research-sdd/**/tests/*.test.sh); a commit without a test is not shipped evidence", ev, g.pr)
		return
	}
	nTests := len(testFiles)
	if nTests > 10 {
		g.say("%s: note: %d test file(s) beyond cap 10 not listed", ev, nTests-10)
		nTests = 10
	}
	var tline []string
	for _, f := range testFiles[:nTests] {
		tline = append(tline, "- test: "+f)
	}
	text := "Closure evidence (merge-gate, PR #" + g.pr + "):\n- commit: " + msha + "\n" + cmdSub(strings.Join(tline, "\n"))
	failed := ""
	for _, issue := range issues {
		cc := g.r.GH(g.cwd, "issue", "comment", issue, "--repo", repo, "--body", text)
		if cc.RC == 0 {
			g.say("%s: posted: issue #%s (commit=%s tests=%d)", ev, issue, msha, nTests)
			continue
		}
		g.say("%s: degraded: could not comment on issue #%s (gh exit %d: %s)", ev, issue, cc.RC, firstLine(cc.Stderr, 200))
		failed += " #" + issue
	}
	if failed != "" {
		g.say("%s: degraded: not posted for issues:%s (backfill by hand)", ev, failed)
	}
}

// pathRaw is `jq -r '.a.b.c'` as a jqEach filter.
func pathRaw(keys ...string) func(json.RawMessage) (string, bool) {
	return func(v json.RawMessage) (string, bool) {
		f, ok := jqPath(v, keys...)
		if !ok {
			return "", false
		}
		return jqRaw(f), true
	}
}

// closureVerdict is the jq verdict over the GraphQL answer: shape | notmerged | nooid | ok.
func closureVerdict(v json.RawMessage) (string, bool) {
	r, ok := jqPath(v, "data", "repository")
	if !ok {
		return "", false
	}
	p, ok := jqIndex(r, "pullRequest")
	if !ok {
		return "", false
	}
	nwo, ok := jqIndex(r, "nameWithOwner")
	if !ok {
		return "", false
	}
	if jqType(nwo) != "string" || jqType(p) != "object" {
		return "shape", true
	}
	nodes, ok := jqPath(p, "closingIssuesReferences", "nodes")
	if !ok {
		return "", false
	}
	if jqType(nodes) != "array" {
		return "shape", true
	}
	total, ok := jqPath(p, "closingIssuesReferences", "totalCount")
	if !ok {
		return "", false
	}
	if jqType(total) != "number" {
		return "shape", true
	}
	merged, _ := jqIndex(p, "merged")
	state, _ := jqIndex(p, "state")
	if strings.TrimSpace(string(merged)) != "true" || !jsonStringIs(state, "MERGED") {
		return "notmerged", true
	}
	oid, ok := jqPath(p, "mergeCommit", "oid")
	if !ok {
		return "", false
	}
	text := ""
	if !jqAbsent(oid) {
		text = jqToString(oid)
	}
	// jq's test("^...{40}$") is Oniguruma's: `$` also matches before one trailing newline.
	if !sha40.MatchString(strings.TrimSuffix(text, "\n")) {
		return "nooid", true
	}
	return "ok", true
}

func jsonStringIs(v json.RawMessage, want string) bool {
	s, ok := jqString(v)
	return ok && s == want
}

// closureIssues is the jq node filter: the numbers of the closing issues of this repository (cross=false), or
// `<repo>#<number>` of the ones in another repository (cross=true). The first node that raises a jq error ends
// the filter for that answer.
func closureIssues(repo string, cross bool) func(json.RawMessage) (string, bool) {
	return func(v json.RawMessage) (string, bool) {
		nodes, ok := jqPath(v, "data", "repository", "pullRequest", "closingIssuesReferences", "nodes")
		var items []json.RawMessage
		if !ok || jqType(nodes) != "array" || json.Unmarshal(nodes, &items) != nil {
			return "", false
		}
		var out []string
		for _, n := range items {
			nwo, ok := jqPath(n, "repository", "nameWithOwner")
			if !ok {
				break
			}
			same := asciiLower(jqToString(nwo)) == asciiLower(repo)
			num, _ := jqIndex(n, "number")
			if cross {
				if !same {
					out = append(out, jqToString(nwo)+"#"+jqToString(num))
				}
				continue
			}
			f, isNum := jqNumber(num)
			if same && isNum && f >= 1 && math.Floor(f) == f {
				out = append(out, jqRaw(num))
			}
		}
		return strings.Join(out, "\n"), len(out) > 0
	}
}

// sortUniqNumeric is `sort -un` over lines.
func sortUniqNumeric(text string) []string {
	if text == "" {
		return nil
	}
	ls := lines(text)
	val := func(s string) float64 { f, _ := strconv.ParseFloat(strings.TrimSpace(s), 64); return f }
	sort.SliceStable(ls, func(i, j int) bool { return val(ls[i]) < val(ls[j]) })
	out := ls[:0]
	for i, l := range ls {
		if i == 0 || val(l) != val(ls[i-1]) {
			out = append(out, l)
		}
	}
	return out
}

// changedTestFiles is the sorted, unique list of non-removed changed files that are research-sdd test suites.
// ok is false when the files answer is not one or more pages of arrays of objects.
func changedTestFiles(raw string) (files []string, ok bool) {
	pages, parsed := jqSlurp(raw)
	if !parsed || len(pages) == 0 {
		return nil, false
	}
	var names []string
	for _, p := range pages {
		var items []json.RawMessage
		if jqType(p) != "array" || json.Unmarshal(p, &items) != nil {
			return nil, false
		}
		for _, e := range items {
			status, ok1 := jqIndex(e, "status")
			fn, ok2 := jqIndex(e, "filename")
			if !ok1 || !ok2 {
				return nil, false
			}
			if !jsonStringIs(status, "removed") {
				names = append(names, jqRaw(fn))
			}
		}
	}
	seen := map[string]bool{}
	for _, n := range lines(cmdSub(strings.Join(names, "\n"))) {
		if testFile.MatchString(n) && !seen[n] {
			seen[n] = true
			files = append(files, n)
		}
	}
	sort.Strings(files)
	return files, true
}
