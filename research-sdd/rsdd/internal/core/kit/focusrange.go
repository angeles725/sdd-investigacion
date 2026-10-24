package kit

import (
	"math"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// The cell grammar of _focus_range_awk (LC_ALL=C: [[:blank:]] is space and tab).
var (
	reStateCell    = regexp.MustCompile(`^RESEARCH-STATE.*\.md$`)
	reStrictRange  = regexp.MustCompile(`^[Bb][0-9]+(–|-)[Bb][0-9]+$`)
	reNearRange    = regexp.MustCompile(`^[Bb][0-9]+[ \t]*(–|—|‑|−|-)`)
	reSeparator    = regexp.MustCompile(`^:?-+:?$`)
	reRangeHeader  = regexp.MustCompile(`^(bloques?|blocks?|block range|rango)$`)
	rePrefixHeader = regexp.MustCompile(`^(block prefix|prefijo|prefix)$`)
)

// RangeState types what DeriveFocusRange read. Bash prints "" for four of these; they stay distinct here.
type RangeState int

const (
	RangeNotRoot   RangeState = iota // the state file is not RESEARCH-STATE.md (a suffixed one takes its prefix)
	RangeNoFocuses                   // no sibling FOCUSES.md
	RangeNoCell                      // no root row, or no range-shaped cell in it
	RangeOK                          // a readable B<a>–B<b>, a <= b
	RangeMalformed                   // range-SHAPED but not the exact grammar (typed, never a silent empty)
)

// FocusRange is the root row's block-scope cell.
type FocusRange struct {
	State  RangeState
	Lo, Hi float64 // RangeOK only; awk numbers (doubles), printed by awkNum
	Cell   string  // RangeMalformed only: the cell as read
}

// Value is what derive_focus_range prints (without the newline): "<a>-<b>", "!<cell>" or "".
func (r FocusRange) Value() string {
	switch r.State {
	case RangeOK:
		return awkNum(r.Lo) + "-" + awkNum(r.Hi)
	case RangeMalformed:
		return "!" + r.Cell
	}
	return ""
}

// DeriveFocusRange is derive_focus_range: the block range of the un-suffixed root's FOCUSES.md row. The cell is
// the one under a RANGE header (Bloques / Blocks / Block range / Rango) when the table has one inside the row,
// else the first range-shaped cell right of the state cell; a header cell that is not range-shaped yields to the
// first one that is. An unreadable FOCUSES.md is ErrUnreadable (finding F9).
func DeriveFocusRange(sf string) (FocusRange, error) {
	root, state, err := readRootCell(sf)
	if err != nil || state != RangeNoCell {
		return FocusRange{State: state}, err
	}
	return root.rng, nil
}

// rootCell is the root-mode output of _focus_range_awk: the V, M and F lines.
type rootCell struct {
	rng      FocusRange
	shaped   int    // M: range-shaped cells in the root row
	fallback string // F: the cell read instead of a non-range-shaped header cell
}

// readRootCell reads sf's FOCUSES.md. state is RangeNotRoot or RangeNoFocuses when there is nothing to read, else
// RangeNoCell and the root cell (whose own State may be any of the three cell states).
func readRootCell(sf string) (rootCell, RangeState, error) {
	if filepath.Base(sf) != "RESEARCH-STATE.md" {
		return rootCell{}, RangeNotRoot, nil
	}
	src, err := readRegular(bashDirname(sf) + "/FOCUSES.md")
	if err == ErrAbsentInput {
		return rootCell{}, RangeNoFocuses, nil
	} else if err != nil {
		return rootCell{}, 0, err
	}
	rc := rootCell{rng: FocusRange{State: RangeNoCell}}
	for _, r := range parseFocusRows(src) {
		if r.state == "RESEARCH-STATE.md" {
			rc.rng, rc.shaped = parseRange(r.chosen), r.shaped
			if r.fallback {
				rc.fallback = r.chosen
			}
			break
		}
	}
	return rc, RangeNoCell, nil
}

// focusRow is one FOCUSES.md row whose state cell names a RESEARCH-STATE*.md file, as _focus_range_awk sees it.
type focusRow struct {
	state     string
	f         []string
	endi      int // the last cell: NF-1 when the line ends with a pipe (and blanks), else NF
	hdr, hdrp int // RANGE and PREFIX header columns of the table in effect, 0 for none
	chosen    string
	shaped    int
	fallback  bool
}

// parseFocusRows walks every pipe-led line. A separator row (its first cell `:?-+:?`) takes the header columns
// from the previous pipe-led line; they stay in effect until the next separator, across tables.
func parseFocusRows(src string) []focusRow {
	var rows []focusRow
	prev := ""
	hdr, hdrp := 0, 0
	for _, line := range SplitLines(src) {
		if !strings.HasPrefix(line, "|") {
			continue
		}
		f := strings.Split(line, "|")
		if reSeparator.MatchString(cellTrim(awkField(f, 2))) {
			hdr, hdrp = headerColumns(prev)
			prev = ""
			continue
		}
		prev = line
		if st := stateCell(f); reStateCell.MatchString(st) {
			endi := len(f)
			if strings.HasSuffix(strings.TrimRight(line, " \t"), "|") {
				endi--
			}
			rows = append(rows, chooseCell(focusRow{state: st, f: f, endi: endi, hdr: hdr, hdrp: hdrp}))
		}
	}
	return rows
}

// headerColumns returns the first RANGE-vocabulary and the first PREFIX-vocabulary column of a header line.
func headerColumns(header string) (hdr, hdrp int) {
	pf := strings.Split(header, "|")
	for i := 2; i <= len(pf); i++ {
		h := asciiLower(cellTrim(pf[i-1]))
		if hdr == 0 && reRangeHeader.MatchString(h) {
			hdr = i
		}
		if hdrp == 0 && rePrefixHeader.MatchString(h) {
			hdrp = i
		}
	}
	return hdr, hdrp
}

// inRow reports whether header column i lies among the row's data cells ($5..endi).
func (r focusRow) inRow(i int) bool { return i >= 5 && i <= r.endi }

// chooseCell picks the block-scope cell (RANGE-HDR-FALLBACK in the bash).
func chooseCell(r focusRow) focusRow {
	first := ""
	for i := 5; i <= r.endi; i++ {
		if c := cellTrim(awkField(r.f, i)); reNearRange.MatchString(c) {
			r.shaped++
			if first == "" {
				first = c
			}
		}
	}
	r.chosen = first
	if r.inRow(r.hdr) {
		r.chosen = cellTrim(awkField(r.f, r.hdr))
		if !reNearRange.MatchString(r.chosen) && first != "" {
			r.chosen, r.fallback = first, true
		}
	}
	return r
}

// parseRange types a chosen cell: strict grammar with a <= b, range-shaped otherwise, or no cell.
func parseRange(c string) FocusRange {
	if !reStrictRange.MatchString(c) {
		if reNearRange.MatchString(c) {
			return FocusRange{State: RangeMalformed, Cell: c}
		}
		return FocusRange{State: RangeNoCell}
	}
	c2 := strings.NewReplacer("B", "", "b", "").Replace(strings.Replace(c, "–", "-", 1))
	a, b, _ := strings.Cut(c2, "-")
	lo, hi := awkStrtod(a), awkStrtod(b)
	if lo > hi {
		return FocusRange{State: RangeMalformed, Cell: c}
	}
	return FocusRange{State: RangeOK, Lo: lo, Hi: hi}
}

// awkStrtod is awk's `s+0` on a digit string (a double; past the range it is +inf).
func awkStrtod(s string) float64 {
	v, _ := strconv.ParseFloat(s, 64)
	return v
}

// awkNum prints a number the way gawk turns one into a string. Every number here comes from a digit string, so it
// is integral (printed with every digit) or +inf past the double range.
func awkNum(v float64) string {
	if math.IsInf(v, 1) {
		return "+inf"
	}
	return strconv.FormatFloat(v, 'f', 0, 64)
}

// cellTrim is the range awk's trim(): blanks, backticks and stars off both ends.
func cellTrim(s string) string { return strings.Trim(s, " \t`*") }

// asciiLower is tolower() under LC_ALL=C: ASCII letters only.
func asciiLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}
