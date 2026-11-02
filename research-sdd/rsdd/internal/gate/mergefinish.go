package gate

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// finish is everything after an assess that is not review_due: the CI gate (--merge only), the allow line, and
// the merge itself.
func (g *mergeGate) finish() int {
	if g.doMerge {
		if code, done := g.ciGate(); done {
			return code
		}
	}
	if g.pr == "" {
		g.say("allow: %s (head=%s base=%s merge_base=%s) (range-only; not bound to a PR — use --pr N or --merge N)", g.reason, g.head, g.base, g.mb)
		return cli.ExitOK
	}
	g.say("allow: %s (head=%s base=%s merge_base=%s) (bound to PR #%s: head equal, range starts at or before the PR branch point)", g.reason, g.head, g.base, g.mb, g.pr)
	if !g.doMerge {
		return cli.ExitOK
	}

	c := g.r.GH(g.cwd, "pr", "merge", g.pr, "--squash", "--match-head-commit", g.head)
	if c.RC != 0 {
		mergeOut := cmdSub(string(c.Stdout) + string(c.Stderr))
		// Skip gh deprecation/warning noise so it cannot replace the real error.
		mergeLine := ""
		for _, l := range lines(mergeOut) {
			low := asciiLower(l)
			if strings.Contains(low, "deprecat") || strings.HasPrefix(low, "warning") {
				continue
			}
			mergeLine = cutBytes(l, 200)
			break
		}
		low := asciiLower(mergeOut)
		if strings.Contains(low, "head branch was modified") || strings.Contains(low, "match-head-commit") || strings.Contains(low, "head sha") { // MERGE-GATE-HEAD-REJECT
			g.say("refuse: head_mismatch (PR #%s head changed before merge: %s)", g.pr, mergeLine)
			return cli.ExitOperational
		}
		why := "gh pr merge failed for PR #" + g.pr
		if mergeLine != "" {
			why += ": " + mergeLine
		}
		return g.degraded(why)
	}
	g.say("merged: PR #%s (head=%s cwd=%s)", g.pr, g.head, g.cwd)
	g.closureEvidence()
	return cli.ExitOK
}

func cutBytes(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// appendNote is `ci_notes="${ci_notes:+$ci_notes$'\n'}$note"`.
func appendNote(notes, note string) string {
	if notes != "" {
		return notes + "\n" + note
	}
	return note
}

// ciGate reads the check runs of the EXACT head sha (not `gh pr checks`, which resolves the PR's current head)
// and refuses the merge unless every reported check is green and every required check is present.
func (g *mergeGate) ciGate() (code int, done bool) {
	c := g.r.GH(g.cwd, "api", "repos/{owner}/{repo}/commits/"+g.head+"/check-runs?per_page=100", "--paginate")
	if c.RC != 0 {
		// Surface gh's own error (bounded, single line) instead of a generic message.
		ciErr := cmdSub(cutBytes(strings.ReplaceAll(stripNUL(string(c.Stderr)), "\n", " "), 300))
		why := "cannot read check runs for head " + g.head + " (gh api failed"
		if ciErr != "" {
			why += ": " + ciErr
		}
		return g.degraded(why + ")"), true
	}
	runs, err := parseCheckRuns(cmdSub(string(c.Stdout)))
	if err != nil {
		return g.degraded("check runs for head " + g.head + " are unparseable or off-schema"), true
	}
	latest, noteList := ciNormalize(runs)
	notes := cmdSub(strings.Join(noteList, "\n"))
	req := ciRequired(g.required)

	// Required checks that never reported: when the PR's changed files match none of the workflow's
	// pull_request.paths the check never ran (kit issue #1867) - noted and dropped from the required set.
	// Anything not evaluable stays required (ci_missing).
	if absent := cmdSub(strings.Join(ciAbsent(latest, req), "\n")); absent != "" {
		var skipped []string
		files, nf, filesOK := g.prFiles()
		pfWhy := ""
		if !filesOK {
			files = ""
			pfWhy = "path filters not evaluated: cannot read the files of PR #" + g.pr + " (gh api failed or unparseable); missing required checks stay ci_missing"
		}
		for _, chk := range lines(absent) {
			if chk == "" {
				continue
			}
			if pfWhy != "" {
				notes = appendNote(notes, pfWhy)
				break
			}
			var res string
			switch {
			case files == "":
				res = "unknown the PR reports no changed files"
			case nf >= 3000:
				res = "unknown the PR lists " + strconv.Itoa(nf) + " changed files (GitHub caps the files list at 3000, so it may be truncated)"
			default:
				res = pfEval(osPFGit{g: g}, g.head, g.prBase, g.pr != "", chk, files)
			}
			switch {
			case strings.HasPrefix(res, "skip "):
				wf := strings.TrimPrefix(res, "skip ")
				n := wf
				if i := strings.LastIndexByte(wf, ' '); i >= 0 {
					n, wf = wf[i+1:], wf[:i]
				}
				notes = appendNote(notes, "required check "+chk+" skipped by path filter ("+wf+" pull_request.paths matches none of the "+n+" changed files)")
				skipped = append(skipped, chk)
			case strings.HasPrefix(res, "unknown "):
				notes = appendNote(notes, "required check "+chk+" not evaluated against path filters: "+strings.TrimPrefix(res, "unknown ")+"; stays required")
			}
		}
		if len(skipped) > 0 {
			req = removeAll(req, skipped)
		}
	}
	verdict := ciVerdict(latest, req)
	for _, n := range lines(notes) {
		if n != "" {
			g.say("note: %s", n)
		}
	}
	if verdict != "ok" {
		g.say("refuse: %s (head=%s) — CI for this exact head must be green before merging", verdict, g.head)
		return cli.ExitOperational, true
	}
	return 0, false
}

// removeAll is jq's `. - $list`: every occurrence of every listed name removed.
func removeAll(in, drop []string) []string {
	var out []string
	for _, v := range in {
		keep := true
		for _, d := range drop {
			if v == d {
				keep = false
				break
			}
		}
		if keep {
			out = append(out, v)
		}
	}
	return out
}

// prFiles reads the PR's changed files (`pulls/N/files --paginate`): every page must be an array, the count is
// the number of entries, and the names are each entry's filename plus its previous_filename when it has one.
func (g *mergeGate) prFiles() (files string, count int, ok bool) {
	c := g.r.GH(g.cwd, "api", "repos/{owner}/{repo}/pulls/"+g.pr+"/files?per_page=100", "--paginate")
	if c.RC != 0 {
		return "", 0, false
	}
	pages, parsed := jqSlurp(cmdSub(string(c.Stdout)))
	if !parsed || len(pages) == 0 {
		return "", 0, false
	}
	var entries []json.RawMessage
	for _, p := range pages {
		var items []json.RawMessage
		if jqType(p) != "array" || json.Unmarshal(p, &items) != nil {
			return "", 0, false
		}
		entries = append(entries, items...)
	}
	var names []string
	for _, e := range entries {
		fn, ok1 := jqIndex(e, "filename")
		prev, ok2 := jqIndex(e, "previous_filename")
		if !ok1 || !ok2 {
			return "", 0, false
		}
		names = append(names, jqRaw(fn))
		if !jqAbsent(prev) {
			names = append(names, jqRaw(prev))
		}
	}
	return cmdSub(strings.Join(names, "\n")), len(entries), true
}

// osPFGit answers the path-filter evaluation from the repository under --cwd.
type osPFGit struct{ g *mergeGate }

func (o osPFGit) LsTree(tree string) []string {
	c := o.g.r.Git(o.g.cwd, "ls-tree", "--name-only", tree, ".github/workflows/")
	out := cmdSub(string(c.Stdout))
	if out == "" {
		return nil
	}
	return lines(out)
}

func (o osPFGit) Show(tree, path string) (string, bool) {
	c := o.g.r.Git(o.g.cwd, "show", tree+":"+path)
	return string(c.Stdout), c.RC == 0
}
