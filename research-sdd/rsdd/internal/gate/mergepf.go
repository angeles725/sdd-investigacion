package gate

import (
	"regexp"
	"strconv"
	"strings"
)

// PATH FILTERS (kit issue #1867): a required check whose workflow never ran for this PR's changed files is not
// "missing". This is the port of ci_glob_re, CI_WF_AWK, ci_pf_pat_ok, ci_pf_tree and ci_pf_eval of merge-gate.sh.
// Read-only and bound to the verified head: workflow files come from a git TREE of --cwd (never the worktree).
//
// The scanner understands exactly the block shapes this repo's workflows use; any other shape is reported (unsup,
// other), never guessed. The awk's `-v chk=...` escape processing is reproduced for the usual sequences only.

// pfGit is what the path-filter evaluation asks of the repository.
type pfGit interface {
	// LsTree is the lines of `git ls-tree --name-only <tree> .github/workflows/`; nothing on failure.
	LsTree(tree string) []string
	// Show is `git show <tree>:<path>`.
	Show(tree, path string) (string, bool)
}

// pfScan is what CI_WF_AWK prints: PAT lines, JOB, PR, IGNORE, FLOW, OTHER and UNSUP.
type pfScan struct {
	pats   []string
	job    bool
	pr     bool
	ignore bool
	flow   bool
	other  string
	unsup  string
}

// pfStrip is the awk strip(): a trailing ` # comment`, surrounding blanks, then one pair of surrounding quotes.
func pfStrip(v string) string {
	for i := 0; i < len(v); i++ {
		if v[i] != ' ' && v[i] != '\t' {
			continue
		}
		j := i
		for j < len(v) && (v[j] == ' ' || v[j] == '\t') {
			j++
		}
		if j < len(v) && v[j] == '#' {
			v = v[:i]
			break
		}
	}
	v = strings.TrimLeft(v, " \t")
	v = strings.TrimRight(v, " \t")
	if len(v) >= 2 && ((v[0] == '"' && v[len(v)-1] == '"') || (v[0] == '\'' && v[len(v)-1] == '\'')) {
		v = v[1 : len(v)-1]
	}
	return v
}

// afterColon is awk's sub(/^[^:]*:/, "", s): the text after the first colon, s itself without one.
func afterColon(s string) string {
	if i := strings.IndexByte(s, ':'); i >= 0 {
		return s[i+1:]
	}
	return s
}

// beforeColon is awk's sub(/:.*/, "", s).
func beforeColon(s string) string {
	if i := strings.IndexByte(s, ':'); i >= 0 {
		return s[:i]
	}
	return s
}

// pfJobKey is `line ~ /^[A-Za-z0-9_-]+:/`.
func pfJobKey(line string) bool {
	i := 0
	for i < len(line) {
		c := line[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-' {
			i++
			continue
		}
		break
	}
	return i > 0 && i < len(line) && line[i] == ':'
}

// pfScanWorkflow runs CI_WF_AWK over the workflow text src for the job check name chk.
func pfScanWorkflow(src, chk string) pfScan {
	var sc pfScan
	var (
		sec, ev, mode, cur, key, val string
		eind, kind, jind, cind       int
		seenJobs                     bool
		ids                          []string
	)
	name := map[string]string{}
	unsup := func(w string) {
		if sc.unsup == "" {
			sc.unsup = w
		}
	}
	text := src + "\n"
	for _, raw := range strings.Split(text[:len(text)-1], "\n") {
		if t := strings.TrimLeft(raw, " \t"); t == "" || t[0] == '#' {
			continue
		}
		ind := len(raw) - len(strings.TrimLeft(raw, " "))
		line := raw[ind:]
		if ind == 0 {
			sec, eind, ev, kind, mode, jind, cur, cind = "", 0, "", 0, "", 0, "", 0
			switch {
			case strings.HasPrefix(line, "on:"):
				sec = "on"
				rest := pfStrip(line[3:])
				if rest == "pull_request" {
					sc.pr = true
				} else if strings.Contains(rest, "pull_request") || strings.Contains(rest, "merge_group") {
					sc.pr = true
					sc.other = "pull_request or merge_group inside an inline on: value"
				}
			case strings.HasPrefix(line, "jobs:"):
				sec = "jobs"
				seenJobs = true
				if pfStrip(line[5:]) != "" {
					unsup("jobs is not a block mapping")
				}
			}
			continue
		}
		switch sec {
		case "on":
			if eind == 0 {
				eind = ind
			}
			if ind == eind {
				ev = pfStrip(beforeColon(line))
				mode, kind = "", 0
				if ev == "pull_request" {
					sc.pr = true
					if pfStrip(afterColon(line)) != "" {
						sc.flow = true
					}
				} else if ev == "pull_request_target" || ev == "merge_group" {
					sc.other = ev + " trigger"
				}
				continue
			}
			if ev != "pull_request" {
				continue
			}
			isItem := strings.HasPrefix(line, "-")
			if kind == 0 && !isItem {
				kind = ind
			}
			if ind == kind && !isItem {
				key = beforeColon(line)
				val = pfStrip(afterColon(line))
				mode = ""
				switch key {
				case "paths":
					if val != "" {
						sc.flow = true
					} else {
						mode = "paths"
					}
				case "paths-ignore":
					sc.ignore = true
				}
				continue
			}
			if mode == "paths" && isItem {
				sc.pats = append(sc.pats, pfStrip(strings.TrimLeft(line[1:], " \t")))
			}
		case "jobs":
			if jind == 0 {
				jind = ind
			}
			if ind == jind {
				if !pfJobKey(line) {
					unsup("job key shape: " + line)
					cur = ""
					continue
				}
				id := beforeColon(line)
				name[id] = id
				ids = append(ids, id)
				cur, cind = id, 0
				continue
			}
			if cur != "" {
				if cind == 0 {
					cind = ind
				}
				if ind == cind && strings.HasPrefix(line, "name:") {
					v := pfStrip(line[5:])
					if v == "" || strings.Contains(v, "${{") || strings.ContainsAny(v[:1], ">|&*!") {
						unsup("job name shape of " + cur)
					} else {
						name[cur] = v
					}
				}
			}
		}
	}
	for _, id := range ids {
		if name[id] == chk {
			sc.job = true
		}
	}
	if !seenJobs {
		unsup("no jobs: block")
	}
	return sc
}

// awkVar is what `awk -v chk=<s>` makes of s: the escape sequences \\ \" \/ \a \b \f \n \r \t \v are processed.
func awkVar(s string) string {
	if !strings.Contains(s, "\\") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 == len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		case 'r':
			b.WriteByte('\r')
		case 'a':
			b.WriteByte(7)
		case 'b':
			b.WriteByte(8)
		case 'f':
			b.WriteByte(12)
		case 'v':
			b.WriteByte(11)
		default:
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

var pfPatChars = regexp.MustCompile(`^[A-Za-z0-9_.*/@-]+$`)

// pfPatOK succeeds only for the forms pfGlobRE emulates exactly: letters, digits, `_ . / @ -`, `*`, and `**`
// solely as a trailing `/**`. Anything else is never guessed.
func pfPatOK(p string) bool {
	if !pfPatChars.MatchString(p) {
		return false
	}
	p = strings.TrimSuffix(p, "/**")
	return !strings.Contains(p, "**")
}

// pfGlobRE is ci_glob_re (`**` crosses directories, `*` does not, everything else is literal) wrapped in the
// anchors the grep adds.
func pfGlobRE(p string) *regexp.Regexp {
	var b strings.Builder
	for _, c := range p {
		if strings.ContainsRune(`[](){}.+^$|?\`, c) {
			b.WriteByte('\\')
		}
		b.WriteRune(c)
	}
	re := strings.ReplaceAll(b.String(), "**", "@@DS@@")
	re = strings.ReplaceAll(re, "*", "[^/]*")
	re = strings.ReplaceAll(re, "@@DS@@", ".*")
	return regexp.MustCompile("^" + re + "$")
}

// lines is `<<<"$s"`: the lines of s.
func lines(s string) []string { return strings.Split(s, "\n") }

// pfAnyLine reports whether some line of files fully matches re.
func pfAnyLine(re *regexp.Regexp, files string) bool {
	for _, l := range lines(files) {
		if re.MatchString(l) {
			return true
		}
	}
	return false
}

var yamlName = regexp.MustCompile(`\.ya?ml$`)

// pfTree judges ONE tree: every workflow in it that carries a job named chk is read and decides; the check is
// skipped only when ALL carriers skip. It returns `skip <wf>[,<wf>...]`, `run` or `unknown <why>`.
func pfTree(g pfGit, tree, label, chk, files string) string {
	var names []string
	for _, l := range g.LsTree(tree) {
		if yamlName.MatchString(l) {
			names = append(names, l)
		}
	}
	wfs := cmdSub(strings.Join(names, "\n"))
	if wfs == "" {
		return "unknown no workflow files in the " + label + " tree (.github/workflows)"
	}
	carriers, anyRun := 0, false
	skipped := ""
	for _, wf := range lines(wfs) {
		src, ok := g.Show(tree, wf)
		if !ok {
			return "unknown cannot read " + wf + " in the " + label + " tree"
		}
		sc := pfScanWorkflow(cmdSub(src), awkVar(chk))
		if sc.unsup != "" {
			return "unknown cannot parse the jobs of " + wf + " (" + sc.unsup + ", " + label + " tree)"
		}
		if !sc.job {
			continue
		}
		carriers++
		switch {
		case sc.other != "":
			return "unknown " + wf + " has another PR-like trigger (" + sc.other + ", " + label + " tree)"
		case !sc.pr:
			return "unknown no pull_request trigger in " + wf + " (" + label + " tree)"
		case sc.ignore:
			return "unknown " + wf + " uses paths-ignore (" + label + " tree)"
		case sc.flow:
			return "unknown " + wf + " lists its paths inline (flow style, " + label + " tree)"
		}
		pats := cmdSub(strings.Join(sc.pats, "\n"))
		if pats == "" {
			anyRun = true
			continue
		}
		hit, bad := false, ""
		for _, pat := range lines(pats) {
			if pat == "" {
				continue
			}
			if !pfPatOK(pat) {
				if bad == "" {
					bad = pat
				}
				continue
			}
			if pfAnyLine(pfGlobRE(pat), files) {
				hit = true
				break
			}
		}
		switch {
		case hit:
			anyRun = true
		case bad != "":
			return "unknown " + wf + " has an unsupported path pattern (" + bad + ", " + label + " tree)"
		default:
			if skipped != "" {
				skipped += ","
			}
			skipped += wf
		}
	}
	if carriers == 0 {
		return "unknown no workflow job named " + chk + " in the " + label + " tree"
	}
	if anyRun {
		return "run"
	}
	return "skip " + skipped
}

// pfEval prints `skip <workflows> <n>` | `run` (the check should have run) | `unknown <why>`. The check is
// skipped only when it is skipped under BOTH the PR base tree and the head tree (a PR that narrows its own
// `paths` must not exempt itself), and never when the PR changes anything under .github/workflows. prBase is
// empty for a run without a PR number, where the bash reads an unset variable and answers nothing.
func pfEval(g pfGit, head, prBase string, havePRBase bool, chk, files string) string {
	for _, l := range lines(files) {
		if strings.HasPrefix(l, ".github/workflows/") {
			return "unknown the PR changes .github/workflows (its own filters cannot exempt it)"
		}
	}
	h := pfTree(g, head, "head", chk, files)
	if !strings.HasPrefix(h, "skip ") {
		return h
	}
	var b string
	if havePRBase {
		b = pfTree(g, prBase, "base", chk, files)
	}
	if !strings.HasPrefix(b, "skip ") {
		return b
	}
	n := 0
	for _, l := range lines(files) {
		if l != "" {
			n++
		}
	}
	return h + " " + strconv.Itoa(n)
}
