package reconcile

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// The `regressed` class (kit issue #1709 slice 2): a `shipped` row whose exact title is proposed AGAIN as an open
// delta in a LATER retro of the same directory. Row ids are per-retro, so the cross-retro identity is the row
// TITLE (retrogrammar.RowTitles), compared exactly. Could-not-look is typed, never a silent no-match.

var (
	reDated    = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}`)
	reIssueNum = regexp.MustCompile(`^Closed-issue-number: *([0-9]+) *$`)
)

// laterRow is one open row of a strictly later retro.
type laterRow struct{ retro, id, title string }

// regState is the per-audited-retro state of the lookup (_reg_cur, _reg_later, ...).
type regState struct {
	cur         []retrogrammar.TitleRow
	curLoaded   bool
	later       []laterRow
	laterLoaded bool
	undatedNote bool
}

// regressed is _regressed_check: the `regressed:` line for a shipped row, or "" when nothing is reported.
func (a *audit) regressed(rid, rec string) string {
	r, g := a.rep, &a.reg
	if !reDated.MatchString(a.base) {
		if !g.undatedNote {
			g.undatedNote = true
			r.note("regressed-lookup: %s has no YYYY-MM-DD filename prefix — retros cannot be ordered, so re-proposals of its shipped rows are not checked", a.base)
		}
		return ""
	}
	if !g.curLoaded {
		g.curLoaded, g.cur = true, retrogrammar.RowTitles(a.doc)
	}
	title := ""
	for _, t := range g.cur {
		if t.ID == rid {
			title = t.Title
			break
		}
	}
	if title == "" || !retrogrammar.TitleHasIdentity(title) {
		r.note("regressed-lookup: row %s of %s has a title under 12 characters, empty or a bare priority/type token — no cross-retro identity, not checked", rid, a.base)
		return ""
	}
	if !g.laterLoaded {
		a.loadLater()
	}
	var hits []string
	for _, l := range g.later {
		if l.title == title {
			hits = append(hits, fmt.Sprintf("%s as row %s", l.retro, l.id))
		}
	}
	if len(hits) == 0 {
		return ""
	}
	where := "an issue whose number is not in the closed-issue data"
	if nums := issueNumbers(rec); nums != "" {
		where = nums
	}
	return fmt.Sprintf("regressed: row %s (closed by %s, re-proposed in %s) — shipped per the closure-evidence rule but proposed again as an open delta in a later retro; human review (not reopened, nothing edited)",
		rid, where, strings.Join(hits, ", "))
}

// issueNumbers is the `Closed-issue-number:` lines of the records as "#N, #M" (unique, bytewise sorted).
func issueNumbers(rec string) string {
	var nums []string
	for _, l := range strings.Split(rec, "\n") {
		if m := reIssueNum.FindStringSubmatch(l); m != nil {
			nums = append(nums, "#"+m[1])
		}
	}
	slices.Sort(nums)
	return strings.Join(slices.Compact(nums), ", ")
}

// loadLater is _reg_load_later: the open rows of every strictly-later dated retro of the same directory, once per
// audited retro.
func (a *audit) loadLater() {
	r, g := a.rep, &a.reg
	g.laterLoaded, g.later = true, nil
	dir, cb := filepath.Dir(a.path), a.base
	cdate := cb[:10]
	ents, err := os.ReadDir(dir) // RECONCILE-SIBLING-LIST-CHECK: an unlistable directory is could-not-look
	if err != nil {
		r.degrade("degraded: retros directory not listable: %s — regressed rows were not checked (%s)", dir, findError(dir, err))
		return
	}
	undated, sameDay := 0, 0
	for _, e := range ents { // ReadDir is sorted by name, the order `find | sort` gives in the C locale
		sb := e.Name()
		if !strings.HasSuffix(sb, ".md") || !e.Type().IsRegular() || sb == cb {
			continue
		}
		if !reDated.MatchString(sb) {
			undated++
			continue
		}
		sd := sb[:10]
		if sd < cdate { // earlier retros cannot regress a later one; checked first so the boundary is observable
			continue
		}
		if sd == cdate { // RECONCILE-SAMEDAY-COUNT
			sameDay++
			continue
		}
		sib := filepath.Join(dir, sb)
		rows, scoped, err := openRowTitles(sib)
		switch {
		case err != nil:
			r.degrade("degraded: later retro not readable: %s — regressed rows in it were not checked", sib)
			continue
		case !scoped:
			r.note("regressed-lookup: %s has a review-status marker outside the leading-block scope — cannot tell whether its rows are open, so it was not checked for re-proposals of %s rows", sb, cb)
			continue
		}
		for _, t := range rows {
			g.later = append(g.later, laterRow{sb, t.ID, t.Title})
		}
	}
	if sameDay > 0 {
		r.note("regressed-lookup: skipped %d same-day retro(s) next to %s — equal dates cannot be ordered against it, so their rows were not checked", sameDay, cb)
	}
	if undated > 0 {
		r.note("regressed-lookup: skipped %d retro(s) without a YYYY-MM-DD prefix next to %s — they cannot be ordered against it, so their rows were not checked", undated, cb)
	}
}

// openRowTitles is _retro_open_row_titles: the (id, title) rows still open in a retro, with the same open-row rule
// as the audit (dismissed / applied close it, PARTIAL keeps the rows its marker does not list). scoped is false
// when a marker exists outside the shared scope (open and closed cannot be told); err when the file cannot be read.
func openRowTitles(path string) (rows []retrogrammar.TitleRow, scoped bool, err error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, true, err
	}
	_ = f.Close()
	doc, err := retrogrammar.Read(path)
	if err != nil {
		return nil, true, err
	}
	ml := retrogrammar.MarkerScopeLine(doc)
	if ml == "" && retrogrammar.MarkerOutOfScope(doc) {
		return nil, false, nil
	}
	partial := retrogrammar.MarkerIsPartial(ml)
	var shipped []string
	if partial {
		if raw := retrogrammar.ShippedRaw(ml); raw != "" {
			shipped, _ = retrogrammar.ShippedIDs(raw)
		}
	}
	switch retrogrammar.StatusFromMarkerLine(ml) {
	case "dismissed":
		return nil, true, nil
	case "applied":
		if !partial {
			return nil, true, nil
		}
	}
	for _, t := range retrogrammar.RowTitles(doc) {
		if t.ID == "" {
			continue
		}
		if partial && (slices.Contains(shipped, t.ID) || retrogrammar.MarkerRowState(ml, t.ID) == retrogrammar.RowDismissed) {
			continue
		}
		rows = append(rows, t)
	}
	return rows, true, nil
}

// findError is the first stderr line GNU find prints for an unlistable directory (C locale quoting).
func findError(dir string, err error) string {
	msg := err.Error()
	var errno syscall.Errno
	if errors.As(err, &errno) {
		msg = errno.Error()
	} else if errors.Is(err, fs.ErrPermission) {
		msg = "permission denied"
	}
	if msg != "" {
		msg = strings.ToUpper(msg[:1]) + msg[1:]
	}
	return fmt.Sprintf("find: '%s': %s", dir, msg)
}
