package lint

// Port of lint_block.py's generic core (kit #1206): units, fences, waivers, R0, R3 and R6. The per-target packs
// (R1 R4 R5 R7 R8 R9) are ported too (U3.2, #2393); packs.go holds the loader and the pack files the rules.
//
// Python's `re` has lookarounds and Unicode classes that Go's regexp lacks. Every such construct is rewritten here
// as explicit code and pinned by a targeted test (rewrite_test.go):
//   - R6_CLAIM `\.(?=\S)`           -> claimFiller (the dot is a filler only when a non-space char follows)
//   - R6_CLAIM `\b` x2              -> boundary checks on the rune before the verdict and after its suffix
//   - CLAUSE_SPLIT lookbehind/ahead -> clauseSplit() scan (packs.go)
//   - WAIVER_BODY `(R\d+)\b`        -> waiverBody (maximal digit run must end at a non-word rune)
//   - R3_BLOCKFILE `\.md\b`         -> the match consumes one non-word rune or the end
//   - `\s \w \d` Unicode            -> wsClass / wordClass / \p{Nd}

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

type unit struct {
	text   string
	line   int
	kind   string // para | item | row | header | heading
	quoted bool
}

func re(p string) *regexp.Regexp { return regexp.MustCompile(p) }

var (
	ws = "[" + wsClass + "]"

	tableRowRE   = re(`^` + ws + `*\|(.+)\|` + ws + `*$`)
	tableSepRE   = re(`^` + ws + `*\|[` + wsClass + `:|-]+\|` + ws + `*$`)
	listItemRE   = re(`^` + ws + `*(?:\p{Nd}+\.|[-*])` + ws + `+`)
	headingRE    = re(`^` + ws + `*(#{1,6})(?:` + ws + `+(.*))?$`)
	blockquoteRE = re(`^` + ws + `*>` + ws + `?`)
	fenceOpenRE  = re("^" + ws + "*(`{3,}|~{3,})")
)

func dequote(line string) string {
	loc := blockquoteRE.FindStringIndex(line)
	if loc == nil {
		return line
	}
	return line[loc[1]:]
}

func headingTitle(line string) (string, bool) {
	m := headingRE.FindStringSubmatch(line)
	if m == nil {
		return "", false
	}
	return m[2], true
}

// scanFences returns the set of fenced 1-based lines (fence lines included) and the unclosed fences.
func scanFences(lines []string) (map[int]bool, [][2]int) {
	fenced := map[int]bool{}
	var unclosed [][2]int
	var openCh byte
	openLen, openLine := 0, 0
	for i, raw := range lines {
		n := i + 1
		content := dequote(raw)
		if openCh == 0 {
			if m := fenceOpenRE.FindStringSubmatch(content); m != nil {
				openCh, openLen, openLine = m[1][0], len(m[1]), n
				fenced[n] = true
			}
			continue
		}
		fenced[n] = true
		st := pyStrip(content)
		if st != "" && len(st) >= openLen && strings.Count(st, string(openCh)) == len(st) {
			openCh = 0
		}
	}
	if openCh != 0 {
		unclosed = append(unclosed, [2]int{openLine, len(lines) - openLine})
	}
	return fenced, unclosed
}

func splitRowCells(rowText string) []string {
	inner := pyStrip(rowText)
	inner = strings.TrimPrefix(inner, "|")
	inner = strings.TrimSuffix(inner, "|")
	cells := strings.Split(inner, "|")
	for i, c := range cells {
		cells[i] = pyStrip(c)
	}
	return cells
}

func extractUnits(lines []string, fenced map[int]bool) []unit {
	var units []unit
	var buf []string
	allQuoted := true
	bufStart := 0
	bufKind := "para"
	flush := func() {
		if len(buf) > 0 {
			units = append(units, unit{pyStrip(strings.Join(buf, " ")), bufStart, bufKind, allQuoted})
		}
		buf, allQuoted, bufStart, bufKind = nil, true, 0, "para"
	}
	for idx, raw := range lines {
		i := idx + 1
		if fenced[i] {
			flush()
			continue
		}
		content := dequote(raw)
		stripped := pyStrip(content)
		if stripped == "" {
			flush()
			continue
		}
		if tableSepRE.MatchString(content) {
			flush()
			if n := len(units); n > 0 && units[n-1].kind == "row" && units[n-1].line == i-1 {
				units[n-1].kind = "header"
			}
			continue
		}
		if tableRowRE.MatchString(content) {
			flush()
			units = append(units, unit{stripped, i, "row", blockquoteRE.MatchString(raw)})
			continue
		}
		if headingRE.MatchString(content) {
			flush()
			units = append(units, unit{stripped, i, "heading", blockquoteRE.MatchString(raw)})
			continue
		}
		if listItemRE.MatchString(content) && len(buf) > 0 {
			flush()
		}
		if bufStart == 0 {
			bufStart = i
			bufKind = "para"
			if listItemRE.MatchString(content) {
				bufKind = "item"
			}
		}
		buf = append(buf, stripped)
		allQuoted = allQuoted && blockquoteRE.MatchString(raw)
	}
	flush()
	return units
}

type section struct {
	start, end int
	title      string
}

func headingSections(lines []string, fenced map[int]bool) []section {
	type st struct {
		line  int
		title string
	}
	var starts []st
	for idx, raw := range lines {
		if fenced[idx+1] {
			continue
		}
		if t, ok := headingTitle(dequote(raw)); ok {
			starts = append(starts, st{idx + 1, t})
		}
	}
	out := make([]section, 0, len(starts))
	for k, s := range starts {
		end := len(lines) + 1
		if k+1 < len(starts) {
			end = starts[k+1].line
		}
		out = append(out, section{s.line, end, s.title})
	}
	return out
}

func linesInSections(secs []section, pat *regexp.Regexp) (map[int]bool, int) {
	out := map[int]bool{}
	n := 0
	for _, s := range secs {
		if pat.MatchString(s.title) {
			n++
			for l := s.start; l < s.end; l++ {
				out[l] = true
			}
		}
	}
	return out, n
}

// ---- waivers ------------------------------------------------------------------------------------------------

var (
	waiverTokenRE = re(`(?is)<!--` + ws + `*lint-(waive|ok):(.*?)-->`)
	waiverHeadRE  = re(`(?is)^` + ws + `*(R\p{Nd}+)`)
	waiverReason  = "reason="
)

var reservedPackRuleIDs = []string{"R1", "R2", "R4", "R5", "R7", "R8", "R9"}

func inList(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

type finding struct {
	line int
	rule string
	msg  string
}

type info struct {
	line int
	msg  string
}

// coverage holds the counters a run proves it looked with. The core ones are fixed; pack rules add `r<N>_triggers`,
// `r<N>_quoted_skipped` and `r4_unscoped` on demand: a key is present once a rule has run on a document, even at 0.
type coverage struct {
	selfverifySections, certHwLive, r6Triggers, certInline int
	pack                                                   map[string]int
}

type doc struct {
	lt      *linter
	lines   []string
	fenced  map[int]bool
	units   []unit
	secs    []section
	cov     coverage
	waivers []finding // (line, rule) pairs; msg unused
	r0      []finding
	infos   []info
	warns   []info
}

// waiverBody is WAIVER_BODY_RE `^\s*(R\d+)\b\s*(.*)$` (DOTALL, IGNORECASE) with the \b written as code: the digit run
// is maximal, so a shorter run can never end on a boundary; it must be followed by a non-word rune or the end.
func waiverBody(s string) (id, rest string, ok bool) {
	loc := waiverHeadRE.FindStringSubmatchIndex(s)
	if loc == nil {
		return "", "", false
	}
	end := loc[3]
	if r, _ := utf8.DecodeRuneInString(s[end:]); end < len(s) && isPyWord(r) {
		return "", "", false
	}
	return s[loc[2]:loc[3]], strings.TrimLeftFunc(s[end:], isPySpace), true
}

func newDoc(text string, lt *linter) *doc {
	d := &doc{lt: lt}
	d.cov.pack = map[string]int{}
	d.lines = pySplitLines(strings.ReplaceAll(text, "**", ""))
	var unclosed [][2]int
	d.fenced, unclosed = scanFences(d.lines)
	d.units = extractUnits(d.lines, d.fenced)
	d.secs = headingSections(d.lines, d.fenced)
	for _, u := range unclosed {
		d.warns = append(d.warns, info{u[0], "unclosed code fence: " + strconv.Itoa(u[1]) + " following line(s) were NOT linted"})
	}
	d.parseWaivers()
	return d
}

func (d *doc) parseWaivers() {
	for idx, raw := range d.lines {
		i := idx + 1
		if d.fenced[i] {
			continue
		}
		for _, m := range waiverTokenRE.FindAllStringSubmatch(raw, -1) {
			alias := strings.ToLower(m[1]) == "ok"
			rawID, rest, ok := waiverBody(m[2])
			if !ok {
				d.r0 = append(d.r0, finding{i, "R0", "waiver names no rule id (expected `R<n> reason=...`): " + pyExcerpt(m[0], 100)})
				continue
			}
			rest = pyStrip(rest)
			rule := strings.ToUpper(rawID)
			if rawID != rule {
				d.r0 = append(d.r0, finding{i, "R0", "waiver rule id must be upper-case (" + rule + ", not " + rawID + "); it does NOT waive"})
				continue
			}
			inactive := inList(reservedPackRuleIDs, rule) && !inList(d.lt.ids, rule)
			if !inList(d.lt.ids, rule) && !inactive {
				d.r0 = append(d.r0, finding{i, "R0", "waiver names unknown rule " + rule + " (active: " + strings.Join(d.lt.ids, ", ") + "); it does NOT waive"})
				continue
			}
			reason := ""
			if strings.HasPrefix(rest, waiverReason) {
				reason = pyStrip(rest[len(waiverReason):])
			} else if alias {
				reason = rest
			}
			if reason == "" {
				d.r0 = append(d.r0, finding{i, "R0", "waiver for " + rule + " has no reason text; it does NOT waive"})
				continue
			}
			if inactive {
				d.infos = append(d.infos, info{i, "waiver for inactive pack rule " + rule + " (not enforced by the generic core)"})
				continue
			}
			d.waivers = append(d.waivers, finding{line: i, rule: rule})
		}
	}
}

func (d *doc) waived(rule string, u unit) bool {
	last := d.unitEnd(u)
	for _, w := range d.waivers {
		if w.rule == rule && u.line <= w.line && w.line <= last {
			return true
		}
	}
	return false
}

func (d *doc) unitEnd(u unit) int {
	if u.kind == "row" || u.kind == "header" || u.kind == "heading" {
		return u.line
	}
	end := u.line
	for ln := u.line + 1; ln <= len(d.lines); ln++ {
		raw := dequote(d.lines[ln-1])
		if d.fenced[ln] || pyStrip(raw) == "" || tableRowRE.MatchString(raw) || headingRE.MatchString(raw) || listItemRE.MatchString(raw) {
			break
		}
		end = ln
	}
	return end
}

type lintResult struct {
	findings     []finding
	warns, infos []info
	cov          coverage
}

// lint runs R0, the core rules and the loaded packs over one document: sorted findings, warnings, infos and the
// coverage counters. A rule that panics is an operational failure, not a finding: crash is its message (lint_block.py
// reported RULE-CRASH for any exception a rule raised) and the result must not be used.
func (lt *linter) lint(text string) (res lintResult, crash string) {
	defer func() {
		if r := recover(); r != nil {
			res, crash = lintResult{}, fmt.Sprint(r)
		}
	}()
	d := newDoc(text, lt)
	fs := append([]finding(nil), d.r0...)
	for _, r := range lt.rules {
		fs = append(fs, r.fn(d)...)
	}
	sort.SliceStable(fs, func(a, b int) bool {
		if fs[a].line != fs[b].line {
			return fs[a].line < fs[b].line
		}
		return fs[a].rule < fs[b].rule
	})
	return lintResult{fs, d.warns, d.infos, d.cov}, ""
}
