package verify

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// POSSIBILITY-FIRST lint (METHODOLOGY section 1 trait, kit issues #1263-#1266): pf_scan of the script and the
// --possibility-sweep mode. A bare defeatist feasibility verdict is one whose section (text up to the next markdown
// heading) carries no route ladder: >= 3 list items or table rows labelled `route` and a `cheapest` next step.

type pfHit struct {
	line int
	ph   string // the matched phrase, lower-cased
	tx   string // the raw line
}

var (
	pfHeading   = vbRe(`^#+[[:space:]]`)
	pfListRoute = vbRe(`^[[:space:]]*([-*+]|[0-9]+[.)]|\|)`)
	pfNotWith   = vbRe(`not with .*measured`)
	pfMeasure   = vbRe(`physically impossible|impossible (value|reading|record|timestamp|state|combination|result)s?`)
	pfVerdict   = vbRe(`not possible|no es posible|impossible|imposible|no way to|out of reach|not determinable|no se puede|cannot be (determined|done|achieved|measured|known|verified|reached|obtained|read|extracted|recovered|resolved|derived|reproduced|built|decided|established|confirmed)`)
)

// pfScan is pf_scan.
func pfScan(lines []string) []pfHit {
	var out, pend []pfHit
	routes, cheapest, fence := 0, false, false
	flush := func() {
		if len(pend) > 0 && !(routes >= 3 && cheapest) { // PF-LADDER-ACCEPT
			out = append(out, pend...)
		}
		pend, routes, cheapest = nil, 0, false
	}
	for i, raw := range lines {
		if strings.HasPrefix(raw, "```") {
			fence = !fence
			continue
		}
		if fence {
			continue
		}
		if pfHeading.MatchString(raw) {
			flush()
			continue
		}
		l := awkLower(raw)
		if pfListRoute.MatchString(l) && strings.Contains(l, "route") {
			routes++
		}
		if strings.Contains(l, "cheapest") {
			cheapest = true
		}
		if pfNotWith.MatchString(l) {
			continue
		}
		l = pfMeasure.ReplaceAllString(l, "") // PF-MEASURE-EXCLUDE
		if loc := pfVerdict.FindStringIndex(l); loc != nil {
			pend = append(pend, pfHit{i + 1, l[loc[0]:loc[1]], raw})
		}
	}
	flush()
	return out
}

// sectionPossibility is section 3b: the advisory WARN for each bare feasibility verdict of the block.
func (b *blockRun) sectionPossibility() {
	b.echo("-- possibility-first (§1: no bare feasibility verdict) --")
	hits := pfScan(b.lines)
	for _, h := range hits {
		b.echo("   WARN    possibility-first line %d: bare verdict '%s' — rewrite as a route ladder (>=3 routes of different classes, cost + needs each, ending with the cheapest next step; unexecuted routes are [INFER]/proposed).", h.line, h.ph)
	}
	if len(hits) == 0 {
		b.echo("   (none — no bare feasibility verdict)")
	}
}

// runPossibilitySweep is `verify-block.sh --possibility-sweep <corpus-dir>`.
func (b *blockRun) runPossibilitySweep(dir string) int {
	if !b.fs.IsDir(dir) {
		fmt.Fprintln(b.s.Err, "usage: verify-block.sh --possibility-sweep <corpus-dir>")
		return 2
	}
	total := 0
	for _, f := range b.findMarkdown(dir) {
		src, err := b.fs.Read(f)
		if err != nil {
			continue
		}
		for _, h := range pfScan(shellx.RecordLines(string(src))) {
			fmt.Fprintf(b.s.Out, "%s:%d: %s — %s\n", f, h.line, h.ph, cutBytes(trimTabs(h.tx), 120))
			total++
		}
	}
	fmt.Fprintf(b.s.Out, "== possibility-sweep: bare verdicts: %d ==\n", total)
	if total > 0 {
		fmt.Fprintln(b.s.Out, "   Reopen each as a child gap (B<n>-G<m>) with the cheapest route as NEXT, §14 back-pointer on the corrected block (METHODOLOGY §1 possibility-first self-correction). Read-only: nothing was edited.")
	}
	return 0
}

// findMarkdown is `find DIR -type f -name '*.md' | sort`: regular files only, symlinks not followed, sorted bytewise.
func (b *blockRun) findMarkdown(dir string) []string {
	var out []string
	var walk func(p string)
	walk = func(p string) {
		f, err := os.Open(b.fs.At(p))
		if err != nil {
			return
		}
		ents, _ := f.ReadDir(-1)
		f.Close()
		for _, e := range ents {
			q := joinFind(p, e.Name())
			switch {
			case e.IsDir():
				walk(q)
			case e.Type().IsRegular() && strings.HasSuffix(e.Name(), ".md"):
				out = append(out, q)
			}
		}
	}
	if st, err := os.Lstat(b.fs.At(dir)); err == nil && st.IsDir() {
		walk(dir)
	} else if err == nil && st.Mode()&os.ModeSymlink != 0 {
		// find without -H does not enter a start point that is a symlink, but `[ -d ]` followed it: nothing listed.
		return nil
	}
	sort.Strings(out)
	return out
}

// joinFind is how find prints a child: the start point, a slash unless it already ends in one, the name.
func joinFind(parent, name string) string {
	if strings.HasSuffix(parent, "/") {
		return parent + name
	}
	return parent + "/" + name
}
