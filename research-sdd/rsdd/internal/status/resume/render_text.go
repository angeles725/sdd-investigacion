package resume

import (
	"errors"
	"strconv"
	"strings"
)

// The handoff is the jq program of resume-render.sh, function for function. A null or missing value is "unknown", never
// 0 or "none"; the two documented exceptions are an explicit repo.remote:null ("none configured") and an explicit
// worktree branch:null ("detached HEAD").

// cnt is def cnt(l; v).
func cnt(label string, v jv) string {
	if v == nil {
		return label + " unknown"
	}
	return label + " " + tostring(v)
}

// orUnknown is def or_unknown(v).
func orUnknown(v jv) string {
	if v == nil {
		return "unknown"
	}
	return tostring(v)
}

// shortSHA is def sha(v): the first seven characters (code points, as jq slices a string) of the value as a string.
func shortSHA(v jv) string {
	if v == nil {
		return "unknown"
	}
	r := []rune(tostring(v))
	if len(r) > 7 {
		r = r[:7]
	}
	return string(r)
}

// aheadBehind is def ab(o).
func aheadBehind(o *jobj) string {
	return cnt("ahead", o.get("ahead")) + " · " + cnt("behind", o.get("behind"))
}

// isBool reports v == b for a boolean b, jq's `==` between a value and a boolean.
func isBool(v jv, b bool) bool {
	x, ok := v.(bool)
	return ok && x == b
}

// worktreeLine is def wt.
func worktreeLine(w *jobj) string {
	var b strings.Builder
	b.WriteString("- `" + orUnknown(w.get("path")) + "` — ")
	switch {
	case !w.has("branch"):
		b.WriteString("branch unknown")
	case w.get("branch") == nil:
		b.WriteString("detached HEAD")
	default:
		b.WriteString("branch `" + tostring(w.get("branch")) + "`")
	}
	b.WriteString(" @ " + shortSHA(w.get("head")) + " · ")
	exists := w.get("exists")
	if !isBool(exists, false) && !isBool(exists, true) {
		b.WriteString("existence unknown · ")
	}
	if isBool(exists, false) {
		b.WriteString("DIRECTORY MISSING")
		if isBool(w.get("prunable"), true) {
			b.WriteString(" (prunable: `git worktree prune`)")
		}
		b.WriteString(" · dirty unknown · untracked unknown")
	} else {
		b.WriteString(cnt("dirty", w.get("dirty")) + " · " + cnt("untracked", w.get("untracked")))
	}
	b.WriteString(" · " + aheadBehind(w))
	return b.String()
}

// prLines is def prs.
func prLines(doc *jobj) []string {
	list, status := doc.get("prs"), doc.get("prs_status")
	if list == nil || status != "ok" {
		why := "prs_status missing"
		if truthy(status) {
			why = tostring(status)
		}
		line := "PR list unknown: " + why
		if list != nil {
			line += " (inconsistent: a PR list is present but its status is not ok; not trusted)"
		}
		return []string{line}
	}
	prs := list.([]jv)
	if len(prs) == 0 {
		return []string{"No open PRs (gh answered with an empty list)."}
	}
	var out []string
	for _, p := range prs {
		o := p.(*jobj)
		out = append(out, "- #"+orUnknown(o.get("number"))+" `"+orUnknown(o.get("branch"))+"` "+orUnknown(o.get("state"))+" — "+orUnknown(o.get("url")))
	}
	switch t := doc.get("prs_truncated"); {
	case isBool(t, true):
		out = append(out, "- PR list truncated at the gh limit: it may be incomplete.")
	case t == nil:
		out = append(out, "- PR list completeness unknown (prs_truncated null or missing).")
	}
	return out
}

// renderHandoff is the Markdown handoff of a validated document, one line per jq output. The only failure is the jq
// error of indexing a boolean repo (`repo:false` passes the shape check as {} and then fails at `.repo.toplevel`).
func renderHandoff(doc *jobj) (string, error) {
	repo := doc.get("repo")
	if isBool(repo, false) {
		return "", errors.New(`jq: error (at <unknown>): Cannot index boolean with string ("toplevel")`)
	}
	or := func(v jv, dflt string) string {
		if truthy(v) {
			return tostring(v)
		}
		return dflt
	}
	var toplevel, remote jv
	hasRemote := false
	if o, ok := repo.(*jobj); ok {
		toplevel, remote, hasRemote = o.get("toplevel"), o.get("remote"), o.has("remote")
	}
	remoteText := "unknown"
	switch {
	case !hasRemote:
	case remote == nil:
		remoteText = "none configured"
	default:
		remoteText = "`" + tostring(remote) + "`"
	}
	wts, brs := doc.get("worktrees").([]jv), doc.get("branches").([]jv)
	lines := []string{
		"# Resume handoff",
		"",
		"Generated " + or(doc.get("generated_at"), "unknown time") + " · repo `" + or(toplevel, "unknown") + "` · remote " + remoteText,
		"Base: `" + doc.get("base_ref").(string) + "` @ " + shortSHA(doc.get("base_sha")),
		"",
		"## Worktrees (" + strconv.Itoa(len(wts)) + ")",
	}
	if len(wts) == 0 {
		lines = append(lines, "None listed.")
	}
	for _, w := range wts {
		lines = append(lines, worktreeLine(w.(*jobj)))
	}
	lines = append(lines, "", "## Loose branches ("+strconv.Itoa(len(brs))+")")
	if len(brs) == 0 {
		lines = append(lines, "None: every local branch is checked out in a worktree.")
	}
	for _, b := range brs {
		o := b.(*jobj)
		lines = append(lines, "- `"+orUnknown(o.get("name"))+"` @ "+shortSHA(o.get("head"))+" · "+aheadBehind(o))
	}
	lines = append(lines, "", "## Open PRs")
	lines = append(lines, prLines(doc)...)
	lines = append(lines, "", "## Not derived",
		"Review receipts, in-flight workers and the next task have no git source; state them by hand.")
	return strings.Join(lines, "\n") + "\n", nil
}
