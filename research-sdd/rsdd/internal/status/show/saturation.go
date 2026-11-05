package show

import (
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
)

// Port of saturation_line: the INFORMATIONAL gap-saturation signal of the default report (a soft REVIEW prompt,
// never an auto-STOP). Over the last 3 recognised iterations, ordered by the parsed index, a window that sums to
// exactly 0 new gaps is SATURATED; any positive sum is active. Three-state honesty (#420, §7): no section, no
// New-gaps column, and rows the parser could not read are each named, so a blind parse can never read as
// "insufficient history (0)".
//
// Declared difference: `sort -k1,1n` breaks ties on the whole line in the caller's locale; the port breaks them
// bytewise (the C locale, which the tests pin).

const satPad = "  saturation      : "

// saturationLine is the report line (no trailing newline).
func (c *ctx) saturationLine() string {
	b, err := os.ReadFile(c.abs(c.state))
	if err != nil { // `grep -qF ... "$state"` complains on stderr, then reads as "not found"
		fmt.Fprintf(c.s.Err, "grep: %s: %s\n", c.state, errnoText(err))
		return satPad + "(no iteration history)"
	}
	text := string(b)
	if !strings.Contains(text, "## Iteration history") {
		return satPad + "(no iteration history)"
	}
	recs, colhdr, noColumn := iterStream(sectionBody(text, "## Iteration history"))
	if noColumn {
		return satPad + "no New-gaps column (header: " + colhdr + ")"
	}
	var iter, all []iterRec
	nstruct := 0
	for _, r := range recs {
		if r.kind == "row" {
			iter = append(iter, r)
		} else {
			nstruct++
		}
	}
	iter = sortByKey(iter, false)
	all = sortByKey(recs, true)
	note := ""
	if nstruct > 0 {
		note = fmt.Sprintf("  [%d unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]", nstruct)
	}
	if n := len(recs); n > 0 && recs[n-1].kind == "struct" && recs[n-1].status == "ok" && atof(recs[n-1].val) > 0 {
		note += "  · latest unnumbered row seeded " + recs[n-1].val + " gaps — not yet an iteration"
	}
	if len(iter) < 1 {
		return satPad + "insufficient history (0 iterations)" + note
	}
	w := min(len(iter), 3)
	window := iter[len(iter)-w:]
	if bad := countBad(window); bad > 0 { // NG-WINDOW
		return fmt.Sprintf("%sunreadable window — %d of last %d rows unrecognised (forms: %s)%s", satPad, bad, w, firstForms(window), note)
	}
	if len(iter) < 3 {
		return fmt.Sprintf("%sinsufficient history (%d iterations)%s", satPad, len(iter), note)
	}
	warn := ""
	if nbad := countBad(all); nbad > 0 {
		warn = fmt.Sprintf("  [WARN: %d of %d rows unreadable (forms: %s)]", nbad, len(iter)+nstruct, firstForms(all))
	}
	sum := 0.0
	for _, r := range window {
		sum += atof(r.val)
	}
	if sum == 0 {
		return satPad + "SATURATED (review) — last 3 iterations netted 0 new gaps" + warn + note
	}
	return fmt.Sprintf("%sactive (%s new gaps in last 3 iter)%s%s", satPad, strconv.FormatFloat(sum, 'f', -1, 64), warn, note)
}

// sortByKey is `sort -t TAB -k1,1n` over the records' lines (stable: `-s`) or not (ties broken on the whole line).
func sortByKey(recs []iterRec, stable bool) []iterRec {
	out := append([]iterRec(nil), recs...)
	slices.SortStableFunc(out, func(a, b iterRec) int {
		if d := numCmp(a.sk, b.sk); d != 0 {
			return d
		}
		if stable {
			return 0
		}
		return strings.Compare(a.line(), b.line())
	})
	return out
}

// numCmp compares two digit strings as numbers of any size.
func numCmp(a, b string) int {
	a, b = strings.TrimLeft(a, "0"), strings.TrimLeft(b, "0")
	if len(a) != len(b) {
		return len(a) - len(b)
	}
	return strings.Compare(a, b)
}

func countBad(recs []iterRec) int {
	n := 0
	for _, r := range recs {
		if r.status == "bad" {
			n++
		}
	}
	return n
}

// firstForms is the first two distinct unreadable cells, comma-joined.
func firstForms(recs []iterRec) string {
	var forms []string
	seen := map[string]bool{}
	for _, r := range recs {
		if r.status != "bad" || seen[r.val] {
			continue
		}
		seen[r.val] = true
		if len(forms) < 2 {
			forms = append(forms, r.val)
		}
	}
	return strings.Join(forms, ",")
}

func atof(s string) float64 {
	f, _ := strconv.ParseFloat(s, 64)
	return f
}

// errnoText is the strerror text bash tools print for an open failure.
func errnoText(err error) string {
	switch {
	case os.IsPermission(err):
		return "Permission denied"
	case os.IsNotExist(err):
		return "No such file or directory"
	}
	return err.Error()
}
