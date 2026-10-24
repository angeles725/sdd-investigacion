package kit

import (
	"errors"
	"io/fs"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Ports of focus_range_stat (_focus_range_scan) and focus_range_report from toolbelt/lib/focus-prefix.sh.

// Diagnostic is one typed line of focus_range_report: Kind is WARN or NOTE, Text the message the bash passes to
// the caller's printf format.
type Diagnostic struct{ Kind, Text string }

// RangeScan is the _focus_range_scan record of a block range over one corpus directory.
type RangeScan struct {
	Count    int            // COUNT: distinct block numbers in the range no other FOCUSES.md row claims
	Files    int            // FILES: the files that carried them
	Span     float64        // SPAN: hi - lo + 1
	Outside  int            // OUTSIDE: canonical block files numbered outside the range
	Families map[string]int // FAM: file count per family (the name before -block<N>/-bloque<N>)
	Missing  float64        // MISSING: range numbers no counted file carries
	First    []float64      // the first 10 of them, ascending
}

// claims is what the other FOCUSES.md rows own: their prefixes and their ranges (_focus_range_awk claims).
type claims struct {
	prefixes []string
	ranges   [][2]float64
}

var reBlockNumber = regexp.MustCompile(`-(block|bloque)[0-9]+`)

// ScanFocusRange is _focus_range_scan dir lo-hi sf: the canonical block files directly under dir (regular *.md
// files, block_file_filter) classified against [lo, hi] and the claims of sf's FOCUSES.md (none when sf is "" or
// has no FOCUSES.md). A missing dir is ErrAbsentInput and an unlistable one ErrUnreadable, where bash counts 0
// (finding F10). A symlinked dir is not followed (find -P) unless it ends with a slash.
func ScanFocusRange(dir string, lo, hi float64, sf string) (RangeScan, error) {
	cl, err := readClaims(sf)
	if err != nil {
		return RangeScan{}, err
	}
	names, err := blockNamesIn(dir)
	if err != nil {
		return RangeScan{}, err
	}
	s := RangeScan{Span: hi - lo + 1, Families: map[string]int{}}
	ids := map[float64]bool{}
	for _, n := range names {
		loc := reBlockNumber.FindStringIndex(n)
		if loc == nil {
			continue
		}
		v := awkStrtod(strings.TrimLeft(n[loc[0]:loc[1]], "-blockque"))
		switch {
		case v < lo || v > hi:
			s.Outside++
		case !cl.claim(n, v):
			s.Files++
			ids[v] = true
			s.Families[n[:loc[0]]]++
		}
	}
	s.Count = len(ids)
	for v := lo; v <= hi && len(s.First) < 10 && v+1 != v; v++ {
		if !ids[v] {
			s.First = append(s.First, v)
		}
	}
	s.Missing = s.Span - float64(s.Count)
	return s, nil
}

// claim reports whether another row owns block file n numbered v: its prefix starts n right before
// block/bloque<digit>, or v lies in its range.
func (c claims) claim(n string, v float64) bool {
	for _, p := range c.prefixes {
		if rest, ok := strings.CutPrefix(n, p); ok && reClaimTail.MatchString(rest) {
			return true
		}
	}
	for _, r := range c.ranges {
		if v >= r[0] && v <= r[1] {
			return true
		}
	}
	return false
}

var reClaimTail = regexp.MustCompile(`^(block|bloque)[0-9]`)

// readClaims runs the claims mode over sf's FOCUSES.md: every non-root RESEARCH-STATE*.md row claims its strict
// range, else the prefix under the PREFIX header ($5 without one), else a prefix written under the RANGE header.
// The claims travel to awk as "P<TAB>prefix" lines, so a prefix is cut at its first tab (kept).
func readClaims(sf string) (claims, error) {
	var cl claims
	if sf == "" {
		return cl, nil
	}
	src, err := readRegular(bashDirname(sf) + "/FOCUSES.md")
	if err == ErrAbsentInput {
		return cl, nil
	} else if err != nil {
		return cl, err
	}
	for _, r := range parseFocusRows(src) {
		if r.state == "RESEARCH-STATE.md" {
			continue
		}
		if reStrictRange.MatchString(r.chosen) {
			if rg := parseRange(r.chosen); rg.State == RangeOK {
				cl.ranges = append(cl.ranges, [2]float64{rg.Lo, rg.Hi})
			}
			continue
		}
		col := 5
		if r.inRow(r.hdrp) {
			col = r.hdrp
		}
		bp := cutBlockPattern(cellTrim(awkField(r.f, col)))
		if !isPrefixShaped(bp) && r.inRow(r.hdr) {
			bp = cutBlockPattern(cellTrim(awkField(r.f, r.hdr)))
		}
		if isPrefixShaped(bp) {
			cl.prefixes = append(cl.prefixes, strings.SplitN(bp, "\t", 2)[0])
		}
	}
	return cl, nil
}

// blockNamesIn lists the canonical block files directly under dir: `find dir -maxdepth 1 -type f -name '*.md' |
// block_file_filter`, by name.
func blockNamesIn(dir string) ([]string, error) {
	st, err := os.Lstat(dir)            // a trailing slash makes lstat(2) resolve a symlink, as it makes find follow it
	if errors.Is(err, fs.ErrNotExist) { // ENOENT only; EACCES, ENOTDIR and ELOOP cannot be judged absent
		return nil, ErrAbsentInput
	} else if err != nil {
		return nil, ErrUnreadable
	}
	if !st.IsDir() {
		return nil, nil
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, ErrUnreadable
	}
	var md []string
	for _, e := range ents {
		if e.Type().IsRegular() && strings.HasSuffix(e.Name(), ".md") {
			md = append(md, e.Name())
		}
	}
	names, _ := FilterBlockFiles(md, false, "")
	return names, nil
}

// FocusRangeReport is focus_range_report: the typed diagnostics of the root's range cell, in the bash order (the
// fallback WARN, the several-cells WARN, then a malformed WARN or the scan's families WARN, missing NOTE and
// cannot-see WARN). Nil when sf is not RESEARCH-STATE.md, has no FOCUSES.md, or the cell is absent or clean.
func FocusRangeReport(sf string) ([]Diagnostic, error) {
	root, state, err := readRootCell(sf)
	if err != nil || state != RangeNoCell {
		return nil, err
	}
	var out []Diagnostic
	warn := func(text string) { out = append(out, Diagnostic{"WARN", text}) }
	if root.fallback != "" {
		warn("FOCUSES.md range column cell is not range-shaped; read the range-shaped cell [" + root.fallback + "] found elsewhere in the root row — put the range under the Blocks/Bloques header")
	}
	if root.shaped > 1 {
		warn("FOCUSES.md root row holds " + strconv.Itoa(root.shaped) + " range-shaped cells — only the header-named (else first) one is read; keep exactly one B<a>–B<b> cell")
	}
	switch r := root.rng; r.State {
	case RangeMalformed:
		warn("FOCUSES.md block-scope cell [" + r.Cell + "] is range-shaped but not the exact grammar B<a>–B<b> (en dash or hyphen, a <= b) — it scopes nothing (METHODOLOGY §16 Block-scope cell grammar)")
	case RangeOK:
		s, err := ScanFocusRange(bashDirname(sf), r.Lo, r.Hi, sf)
		if err != nil {
			return out, err
		}
		out = append(out, scanDiagnostics("B"+awkNum(r.Lo)+"–B"+awkNum(r.Hi), s)...)
	}
	return out, nil
}

// scanDiagnostics renders the scan half of focus_range_report for the range named rng.
func scanDiagnostics(rng string, s RangeScan) []Diagnostic {
	var out []Diagnostic
	if len(s.Families) > 1 {
		fams := make([]string, 0, len(s.Families))
		for f, n := range s.Families {
			fams = append(fams, f+"="+strconv.Itoa(n))
		}
		sort.Strings(fams) // `sort` of "family=count" lines, bytewise under LC_ALL=C (finding F3)
		out = append(out, Diagnostic{"WARN", rng + " mixes " + strconv.Itoa(len(fams)) + " block families that no other FOCUSES.md row claims (file counts: " +
			strings.Join(fams, " ") + ") — all are counted as distinct block numbers; give a foreign family its own row (prefix or range) to exclude it"})
	}
	if s.Missing > 0 && s.Count > 0 {
		first := make([]string, len(s.First))
		for i, v := range s.First {
			first[i] = awkNum(v)
		}
		text := rng + " spans " + awkNum(s.Span) + " block ids, " + strconv.Itoa(s.Count) + " present, " + awkNum(s.Missing) +
			" missing (span - distinct): " + strings.Join(first, ",")
		if s.Missing > 10 {
			text += ", … (first 10 of " + awkNum(s.Missing) + ")"
		}
		out = append(out, Diagnostic{"NOTE", text})
	}
	if s.Count == 0 && s.Outside > 0 {
		out = append(out, Diagnostic{"WARN", "no block file is numbered within " + rng + " while " + strconv.Itoa(s.Outside) +
			" block file(s) exist outside it — the range may be wrong (cannot-see: the count is 0, not a measured zero)"})
	}
	return out
}
