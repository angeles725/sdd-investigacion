package archtest

import "fmt"

// Message formats. Each carries the exact line to add, change or delete.
const (
	msgUnlistedSoft = "%s: %d lines, over %d and not listed. Split it, or add this line to %s:\n%s %d accepted <reason>"
	msgUnlistedHard = "%s: %d lines, over %d. A new file over %d lines cannot be listed: split it."
	msgGrew         = "%s: grew from %d to %d lines. Split it, or change its line in %s to:\n%s %d %s %s"
	msgGrewHard     = "%s: grew from %d to %d lines and is over %d. A file over %d lines may not grow: split it first."
	msgNotOver      = "%s: %d lines, no longer over %d. Delete this line from %s:\n%s"
	msgNotProd      = "%s: listed but not a production Go file in this tree. Delete this line from %s:\n%s"
	msgAcceptedHigh = "%s:%d: an accepted entry may not be above %d lines (%s %d): split the file."
	msgMalformed    = "%s:%d: %s; expected \"<path> <lines> <legacy|accepted> <reason of at least %d characters>\", entries sorted by path"
)

// judge compares measured sizes with the debt entries (S5, S6). It fills
// r.Over and r.Lowerable and returns the violation messages.
func judge(files map[string]int, entries []debtEntry, r *SizeResult) []string {
	var out []string
	listed := map[string]bool{}
	for _, e := range entries {
		listed[e.Path] = true
		n, isProd := files[e.Path]
		switch {
		case e.Kind == "accepted" && e.Lines > HardLimit:
			out = append(out, fmt.Sprintf(msgAcceptedHigh, DebtFileName, e.LineNo, HardLimit, e.Path, e.Lines))
		case !isProd:
			out = append(out, fmt.Sprintf(msgNotProd, e.Path, DebtFileName, e.Raw))
		case n <= SoftLimit:
			out = append(out, fmt.Sprintf(msgNotOver, e.Path, n, SoftLimit, DebtFileName, e.Raw))
		case n > e.Lines && n > HardLimit:
			out = append(out, fmt.Sprintf(msgGrewHard, e.Path, e.Lines, n, HardLimit, HardLimit))
		case n > e.Lines:
			out = append(out, fmt.Sprintf(msgGrew, e.Path, e.Lines, n, DebtFileName, e.Path, n, e.Kind, e.Reason))
		case n < e.Lines:
			r.Lowerable++
		}
	}
	for path, n := range files {
		if n <= SoftLimit {
			continue
		}
		r.Over++
		if listed[path] {
			continue
		}
		if n > HardLimit {
			out = append(out, fmt.Sprintf(msgUnlistedHard, path, n, HardLimit, HardLimit))
		} else {
			out = append(out, fmt.Sprintf(msgUnlistedSoft, path, n, SoftLimit, DebtFileName, path, n))
		}
	}
	return out
}
