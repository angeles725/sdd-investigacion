package kit

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// PrefixOrigin says where a derived block prefix came from, so "" is never ambiguous (section 7).
type PrefixOrigin int

const (
	PrefixNone         PrefixOrigin = iota // nothing to derive: no sibling FOCUSES.md, no root row, or an unrelated file name
	PrefixFromFilename                     // RESEARCH-STATE-<focus>.md
	PrefixFromFocuses                      // the FOCUSES.md "Block prefix" cell of the root row
	PrefixUnreadable                       // degraded: FOCUSES.md exists but cannot be read (bash: a quiet "")
)

var (
	reBlockMd    = regexp.MustCompile(`block[A-Za-z0-9]*\.md`)
	reNear       = regexp.MustCompile(`^[Bb][0-9]+[ \t]*(–|—|‑|−|-)`)
	reStrict     = regexp.MustCompile(`^[Bb][0-9]+(–|-)[Bb][0-9]+$`)
	reSepCell    = regexp.MustCompile(`^:?-+:?$`)
	reRangeHdr   = regexp.MustCompile(`^(bloques?|blocks?|block range|rango)$`)
	rePrefixHdr  = regexp.MustCompile(`^(block prefix|prefijo|prefix)$`)
	reStateCol   = regexp.MustCompile(`^RESEARCH-STATE.*\.md$`)
	rePfxShaped  = regexp.MustCompile(`^[A-Za-z].*-$`)
	reBlockNum   = regexp.MustCompile(`-(block|bloque)[0-9]+`)
	reBlockStart = regexp.MustCompile(`^(block|bloque)[0-9]`)
	reTrailPipe  = regexp.MustCompile(`\|[ \t]*$`)
)

func readFocuses(stateFile string) (body string, state int) { // 0 ok, 1 absent, 2 unreadable
	p := filepath.Join(filepath.Dir(stateFile), "FOCUSES.md")
	st, err := os.Stat(p)
	if err != nil || !st.Mode().IsRegular() {
		return "", 1
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return "", 2
	}
	return string(b), 0
}

// stateCell is the State-file column: trimmed of blanks and backticks, with a [text](link) form reduced to text.
func stateCell(c string) string {
	c = strings.Trim(c, " \t`")
	if s, ok := strings.CutPrefix(c, "["); ok {
		i := strings.Index(s, "]")
		if i < 0 {
			return ""
		}
		return s[:i]
	}
	return c
}

func cutBlockMd(s string) string {
	if loc := reBlockMd.FindStringIndex(s); loc != nil {
		return s[:loc[0]]
	}
	return s
}

// DerivePrefix is derive_focus_prefix: RESEARCH-STATE-<focus>.md gives "<focus>-"; the un-suffixed root reads the
// "Block prefix" cell of its FOCUSES.md row. The result carries no trailing newline (bash prints one only on the
// FOCUSES.md path, so compare through $(...)).
func DerivePrefix(stateFile string) (string, PrefixOrigin) {
	base := filepath.Base(stateFile)
	if f, ok := strings.CutPrefix(base, "RESEARCH-STATE-"); ok && strings.HasSuffix(f, ".md") {
		return strings.TrimSuffix(f, ".md") + "-", PrefixFromFilename
	}
	if base != "RESEARCH-STATE.md" {
		return "", PrefixNone
	}
	body, st := readFocuses(stateFile)
	switch st {
	case 1:
		return "", PrefixNone
	case 2:
		return "", PrefixUnreadable
	}
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, "|") {
			continue
		}
		f := strings.Split(line, "|")
		cell := func(i int) string {
			if i <= len(f) {
				return f[i-1]
			}
			return ""
		}
		if stateCell(cell(4)) != "RESEARCH-STATE.md" {
			continue
		}
		bp := cutBlockMd(strings.Trim(cell(5), " \t`"))
		if bp != "" && ((bp[0] >= 'A' && bp[0] <= 'Z') || (bp[0] >= 'a' && bp[0] <= 'z')) && strings.HasSuffix(bp, "-") {
			return bp, PrefixFromFocuses
		}
	}
	return "", PrefixNone
}

// RangeKind is the typed outcome of DeriveRange.
type RangeKind int

const (
	RangeNone       RangeKind = iota // no FOCUSES.md, no root row, or no range-shaped cell
	RangeOK                          // "<a>-<b>"
	RangeMalformed                   // range-shaped but not the exact grammar
	RangeUnreadable                  // degraded: FOCUSES.md exists but cannot be read (bash: a quiet "")
)

// FocusRange is the root row's range cell plus the side-channels focus_range_report reads.
type FocusRange struct {
	Kind     RangeKind
	Value    string // "a-b" for RangeOK, the raw cell for RangeMalformed
	Multi    int    // > 1: how many cells of the root row are range-shaped
	Fallback string // non-empty: the header-chosen cell was not range-shaped and this one was read instead
}

// Output is what derive_focus_range prints: "a-b", "!<cell>" or "".
func (r FocusRange) Output() string {
	switch r.Kind {
	case RangeOK:
		return r.Value
	case RangeMalformed:
		return "!" + r.Value
	}
	return ""
}

type focusRow struct {
	state, chosen string // state: the State-file cell
	nsh           int
	fallback      bool
	prefix        string // a claims-mode prefix claim, "" when none
	lo, hi        int
	isRange       bool
}

func asciiLower(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'A' && r <= 'Z' {
			return r + 32
		}
		return r
	}, s)
}

func trimC(c string) string { return strings.Trim(c, " \t`*") }

func norm(c string) (string, bool) {
	c2 := strings.Replace(c, "–", "-", 1)
	c2 = strings.NewReplacer("B", "", "b", "").Replace(c2)
	a, b, _ := strings.Cut(c2, "-")
	x, e1 := strconv.ParseInt(a, 10, 64)
	y, e2 := strconv.ParseInt(b, 10, 64)
	if e1 != nil || e2 != nil || x > y {
		return "!" + c, false
	}
	return fmt.Sprintf("%d-%d", x, y), true
}

// focusRows is _focus_range_awk: one record per RESEARCH-STATE*.md row of the FOCUSES.md tables.
func focusRows(body string) []focusRow {
	var out []focusRow
	var prev string
	hdr, hdrp := 0, 0
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, "|") {
			continue
		}
		f := strings.Split(line, "|")
		field := func(i int) string {
			if i <= len(f) {
				return f[i-1]
			}
			return ""
		}
		endi := len(f)
		if reTrailPipe.MatchString(line) {
			endi--
		}
		if reSepCell.MatchString(trimC(field(2))) {
			hdr, hdrp = 0, 0
			pf := strings.Split(prev, "|")
			if prev == "" {
				pf = nil
			}
			for i := 2; i <= len(pf); i++ {
				h := asciiLower(trimC(pf[i-1]))
				if hdr == 0 && reRangeHdr.MatchString(h) {
					hdr = i
				}
				if hdrp == 0 && rePrefixHdr.MatchString(h) {
					hdrp = i
				}
			}
			prev = ""
			continue
		}
		prev = line
		sf := stateCell(field(4))
		if !reStateCol.MatchString(sf) {
			continue
		}
		r := focusRow{state: sf}
		first := ""
		for i := 5; i <= endi; i++ {
			if c := trimC(field(i)); reNear.MatchString(c) {
				r.nsh++
				if first == "" {
					first = c
				}
			}
		}
		r.chosen = first
		if hdr >= 5 && hdr <= endi {
			r.chosen = trimC(field(hdr))
			if !reNear.MatchString(r.chosen) && first != "" {
				r.chosen, r.fallback = first, true
			}
		}
		if sf != "RESEARCH-STATE.md" { // claims mode
			if reStrict.MatchString(r.chosen) {
				if v, ok := norm(r.chosen); ok {
					a, b, _ := strings.Cut(v, "-")
					r.lo, _ = strconv.Atoi(a)
					r.hi, _ = strconv.Atoi(b)
					r.isRange = true
				}
			} else {
				pc := field(5)
				if hdrp >= 5 && hdrp <= endi {
					pc = field(hdrp)
				}
				bp := cutBlockMd(trimC(pc))
				if !rePfxShaped.MatchString(bp) && hdr >= 5 && hdr <= endi {
					bp = cutBlockMd(trimC(field(hdr)))
				}
				if rePfxShaped.MatchString(bp) {
					r.prefix = bp
				}
			}
		}
		out = append(out, r)
	}
	return out
}

// DeriveRange is derive_focus_range: only the un-suffixed root reads a range.
func DeriveRange(stateFile string) FocusRange {
	if filepath.Base(stateFile) != "RESEARCH-STATE.md" {
		return FocusRange{}
	}
	body, st := readFocuses(stateFile)
	switch st {
	case 1:
		return FocusRange{}
	case 2:
		return FocusRange{Kind: RangeUnreadable}
	}
	for _, r := range focusRows(body) {
		if r.state != "RESEARCH-STATE.md" {
			continue
		}
		fr := FocusRange{}
		if r.nsh > 1 {
			fr.Multi = r.nsh
		}
		if r.fallback {
			fr.Fallback = r.chosen
		}
		switch {
		case reStrict.MatchString(r.chosen):
			v, ok := norm(r.chosen)
			if ok {
				fr.Kind, fr.Value = RangeOK, v
			} else {
				fr.Kind, fr.Value = RangeMalformed, r.chosen
			}
		case reNear.MatchString(r.chosen):
			fr.Kind, fr.Value = RangeMalformed, r.chosen
		}
		return fr // the first root row only (awk `done`)
	}
	return FocusRange{}
}

func blockNum(path string) (n string, start int, num float64, ok bool) {
	n = path[strings.LastIndex(path, "/")+1:]
	loc := reBlockNum.FindStringIndex(n)
	if loc == nil {
		return n, 0, 0, false
	}
	digits := strings.TrimLeft(n[loc[0]:loc[1]], "-blockque")
	num, _ = strconv.ParseFloat(digits, 64)
	return n, loc[0], num, true
}

// BlockRangeFilter is block_range_filter [-n] lo hi over candidate paths: those whose block number is in [lo, hi].
func BlockRangeFilter(paths []string, lo, hi int, numbers bool) []string {
	var out []string
	for _, p := range paths {
		_, _, v, ok := blockNum(p)
		if !ok || v < float64(lo) || v > float64(hi) {
			continue
		}
		if numbers {
			out = append(out, strconv.FormatFloat(v, 'f', -1, 64))
		} else {
			out = append(out, p)
		}
	}
	return out
}

// RangeScan is the _focus_range_scan record.
type RangeScan struct {
	Count, Files, Span, Outside int
	Families                    map[string]int
	MissingCount                int
	MissingFirst                []int // at most 10
}

// ScanRange is focus_range_stat's source: the canonical block files directly under dir whose number is in
// [lo, hi] and that no OTHER FOCUSES.md row claims (an other row's prefix, or a number inside its own range).
// A missing dir is ErrAbsentInput and an unreadable one ErrUnreadable (bash reports counts of 0 for both).
func ScanRange(dir string, lo, hi int, stateFile string) (RangeScan, error) {
	if _, err := os.Lstat(dir); err != nil {
		return RangeScan{}, ErrAbsentInput
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return RangeScan{}, ErrUnreadable
	}
	var claims []focusRow
	if stateFile != "" {
		if body, st := readFocuses(stateFile); st == 0 {
			for _, r := range focusRows(body) {
				if r.state != "RESEARCH-STATE.md" && (r.prefix != "" || r.isRange) {
					claims = append(claims, r)
				}
			}
		}
	}
	var names []string
	for _, e := range ents {
		if e.Type().IsRegular() && strings.HasSuffix(e.Name(), ".md") {
			names = append(names, dir+"/"+e.Name())
		}
	}
	kept := BlockFileFilter(strings.Join(names, "\n"), false, "").Lines
	res := RangeScan{Span: hi - lo + 1, Families: map[string]int{}}
	ids := map[int]bool{}
	for _, p := range kept {
		n, start, fv, _ := blockNum(p)
		v := int(fv)
		if v < lo || v > hi {
			res.Outside++
			continue
		}
		claimed := false
		for _, c := range claims {
			if c.prefix != "" && strings.HasPrefix(n, c.prefix) && reBlockStart.MatchString(n[len(c.prefix):]) {
				claimed = true
			}
			if c.isRange && v >= c.lo && v <= c.hi {
				claimed = true
			}
		}
		if claimed {
			continue
		}
		res.Files++
		ids[v] = true
		res.Families[n[:start]]++
	}
	res.Count = len(ids)
	// Every id is inside [lo, hi], so the missing count is arithmetic; only the first 10 are enumerated, which costs
	// O(files + 10) whatever the span (bash loops over the whole span and gets the same numbers).
	if res.MissingCount = res.Span - res.Count; res.MissingCount < 0 {
		res.MissingCount = 0
	}
	for v := lo; v <= hi && len(res.MissingFirst) < res.MissingCount; v++ {
		if !ids[v] {
			res.MissingFirst = append(res.MissingFirst, v)
		}
	}
	return res, nil
}

// Diag is one focus_range_report line. Kind is WARN or NOTE; DEGRADED is Go-only (FOCUSES.md unreadable).
type Diag struct{ Kind, Text string }

// RangeReport is focus_range_report: typed diagnostics for the root's range cell; nothing when it is absent or clean.
func RangeReport(stateFile string) []Diag {
	r := DeriveRange(stateFile)
	if r.Kind == RangeUnreadable {
		return []Diag{{"DEGRADED", "FOCUSES.md exists but cannot be read"}}
	}
	if filepath.Base(stateFile) != "RESEARCH-STATE.md" {
		return nil
	}
	var out []Diag
	if r.Fallback != "" {
		out = append(out, Diag{"WARN", "FOCUSES.md range column cell is not range-shaped; read the range-shaped cell [" + r.Fallback + "] found elsewhere in the root row — put the range under the Blocks/Bloques header"})
	}
	if r.Multi > 0 {
		out = append(out, Diag{"WARN", fmt.Sprintf("FOCUSES.md root row holds %d range-shaped cells — only the header-named (else first) one is read; keep exactly one B<a>–B<b> cell", r.Multi)})
	}
	switch r.Kind {
	case RangeMalformed:
		return append(out, Diag{"WARN", "FOCUSES.md block-scope cell [" + r.Value + "] is range-shaped but not the exact grammar B<a>–B<b> (en dash or hyphen, a <= b) — it scopes nothing (METHODOLOGY §16 Block-scope cell grammar)"})
	case RangeOK:
	default:
		return out
	}
	a, b, _ := strings.Cut(r.Value, "-")
	lo, _ := strconv.Atoi(a)
	hi, _ := strconv.Atoi(b)
	rng := "B" + a + "–B" + b
	sc, err := ScanRange(filepath.Dir(stateFile), lo, hi, stateFile)
	if err != nil {
		return append(out, Diag{"DEGRADED", "block scan failed: " + err.Error()})
	}
	if len(sc.Families) > 1 {
		var fams []string
		for f, n := range sc.Families {
			fams = append(fams, fmt.Sprintf("%s=%d", f, n))
		}
		sort.Strings(fams)
		out = append(out, Diag{"WARN", fmt.Sprintf("%s mixes %d block families that no other FOCUSES.md row claims (file counts: %s) — all are counted as distinct block numbers; give a foreign family its own row (prefix or range) to exclude it", rng, len(fams), strings.Join(fams, " "))})
	}
	if sc.MissingCount > 0 && sc.Count > 0 {
		var l []string
		for _, v := range sc.MissingFirst {
			l = append(l, strconv.Itoa(v))
		}
		extra := ""
		if sc.MissingCount > 10 {
			extra = fmt.Sprintf(", … (first 10 of %d)", sc.MissingCount)
		}
		out = append(out, Diag{"NOTE", fmt.Sprintf("%s spans %d block ids, %d present, %d missing (span - distinct): %s%s", rng, sc.Span, sc.Count, sc.MissingCount, strings.Join(l, ","), extra)})
	}
	if sc.Count == 0 && sc.Outside > 0 {
		out = append(out, Diag{"WARN", fmt.Sprintf("no block file is numbered within %s while %d block file(s) exist outside it — the range may be wrong (cannot-see: the count is 0, not a measured zero)", rng, sc.Outside)})
	}
	return out
}
