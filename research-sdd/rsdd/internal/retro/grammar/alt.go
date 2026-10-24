package grammar

import (
	"regexp"
	"strings"
)

// The delta forms real fleet retros use that are neither a row table nor a `### D<N> —` entry (retro_grammar_alt_
// entry_rows, kit issues #1895 #1932-#1934 #1938 #1939). The consumers read them ONLY after the table and entry
// forms yielded nothing, so a canonical retro never changes reading. Three forms, nothing else:
//  1. numbered items (`1. **Title.** prose`, also `1)`) at column 0 under a canonical heading, before any `###`;
//  2. the same items under a `### Proposals …` H3 (inside a canonical section or not), up to the next heading;
//  3. `## Delta <ID> — [HIGH|MED|MEDIUM|LOW —] title` outside a canonical section (<ID> per DeltaID; MED is
//     normalised to MEDIUM).
// Any other `###` ends the item scope. An item's title is its leading bold span, else its first sentence, capped
// at 100 bytes on a UTF-8 boundary (the cut-off text moves to the evidence, itself capped at 300); its target is
// the text after a `PROPOSED ` marker on a later line, up to the first `:`. A blank line followed by a line at
// column 0 ends the item. Duplicate ids are not resolved here (DupIDs).

var (
	reNumberedItem = regexp.MustCompile(`^[0-9]+[.)][[:space:]]+`)
	reH2DeltaLead  = regexp.MustCompile(`^## [Dd]elta +`)
	reAbbrev       = regexp.MustCompile(`^(e\.g|i\.e|etc|vs|cf|approx|incl)$`)
)

// altItem is one alternative-form delta and the heading line of the group that produced it.
type altItem struct {
	row  Row
	head string
}

// AltEntryRows is retro_grammar_alt_entry_rows <f>: one Row per item, in file order.
func AltEntryRows(d *Doc) []Row {
	items := altItems(d)
	out := make([]Row, len(items))
	for i, it := range items {
		out[i] = it.row
	}
	return out
}

// AltHeads is retro_grammar_alt_entry_rows <f> heads: the heading line of every group that produced at least one
// item, once, in file order. Consumers use it to tell a proposal-like heading with items from one without.
func AltHeads(d *Doc) []string {
	var out []string
	seen := map[string]bool{}
	for _, it := range altItems(d) {
		if !seen[it.head] { // ALT_HEADS_UNIQ
			seen[it.head] = true
			out = append(out, it.head)
		}
	}
	return out
}

// altScope is the parser state: which group a line belongs to and the item being built.
type altScope struct {
	mode  string // "", "canon", "h3" or "h2d"
	head  string
	cur   Row
	have  bool
	blank bool
	out   []altItem
}

func (s *altScope) flush() {
	if s.have {
		s.out = append(s.out, altItem{s.cur, s.head})
	}
	s.have = false
}

func altItems(d *Doc) []altItem {
	s := &altScope{}
	for _, line := range d.Lines {
		low := lower(line)
		switch {
		case isCanonical(low):
			s.flush()
			s.mode, s.head = "canon", line
		case isH2(line):
			s.flush()
			s.mode = ""
			if strings.HasPrefix(low, "## delta ") { // ALT_H2_DELTA
				s.h2Delta(line)
			}
		case isH3(line):
			if s.mode == "h2d" {
				continue
			}
			s.flush()
			s.mode = "" // ALT_H3_RESET: any other ### ends the item scope
			if isProposalsH3(low) {
				s.mode, s.head = "h3", line
			}
		case trimLeftSpace(line) == "":
			s.blank = true
		case s.mode == "canon" || s.mode == "h3":
			s.itemLine(line)
		default:
			s.blank = false
		}
	}
	s.flush()
	return s.out
}

// h2Delta opens a `## Delta <ID> — [LEVEL —] title` item; any other `## delta` heading opens nothing.
func (s *altScope) h2Delta(line string) {
	t := reH2DeltaLead.ReplaceAllString(line, "")
	tok, rest, ok := strings.Cut(t, "—")
	tok = trimSpace(tok)
	if !ok || !DeltaID(tok) {
		return
	}
	title, prio := trimSpace(rest), ""
	if lv, after, ok := strings.Cut(title, " — "); ok {
		switch lv = upper(trimSpace(lv)); lv {
		case "HIGH", "MEDIUM", "MED", "LOW":
			prio, title = lv, trimSpace(after)
			if prio == "MED" {
				prio = "MEDIUM" // ALT_PRIORITY_MED
			}
		}
	}
	s.cur, s.have, s.head, s.mode = Row{ID: tok, Change: title, Priority: prio}, title != "", line, "h2d"
}

// itemLine handles a non-blank, non-heading line inside a numbered-item group.
func (s *altScope) itemLine(line string) {
	if m := reNumberedItem.FindString(line); m != "" { // ALT_NUMBERED_ITEM
		s.flush()
		s.cur, s.have = startItem(strings.TrimRight(m, ".)"+spaceSet), line[len(m):])
		s.blank = false
		return
	}
	if s.have && s.blank && !isSpace(line[0]) { // ALT_BLANK_FLUSH
		s.flush()
	}
	if s.have && s.cur.Target == "" { // ALT_PROPOSED_TARGET
		if _, t, ok := strings.Cut(line, "PROPOSED "); ok {
			if head, _, ok := strings.Cut(t, ":"); ok && len(head) < 120 {
				s.cur.Target = trimSpace(head)
			}
		}
	}
	s.blank = false
}

// startItem builds the row of a numbered item from the text after its number; ok is false for an empty title.
func startItem(id, text string) (Row, bool) {
	t, rest := trimSpace(text), ""
	if strings.HasPrefix(t, "**") {
		if title, after, closed := strings.Cut(t[2:], "**"); closed {
			t, rest = title, after
		} else {
			t = t[2:] // an unclosed bold is plain text
		}
	}
	if rest == "" {
		if e := sentenceEnd(t); e >= 0 {
			t, rest = t[:e], t[e+2:]
		}
	}
	k := cutAt(t, 100) // ALT_TITLE_CAP: len(t) when the title fits
	if tail := t[k:]; tail != "" {
		rest = tail + " " + rest
	}
	t = t[:k]
	title := trimSpace(strings.TrimRight(t, ".:"+spaceSet)) // ALT_TITLE_STRIP
	ev := trimSpace(rest)
	if len(ev) > 300 {
		ev = ev[:cutAt(ev, 297)] + "..."
	}
	return Row{ID: id, Change: title, Evidence: ev}, title != ""
}

// sentenceEnd is the index of the "." ending the first sentence of t, -1 when there is none. A sentence ends at
// ". " unless a lower-case letter follows the blank (ALT_SENT_LOWER) or the word before the dot is an
// abbreviation or a single letter (ALT_SENT_ABBREV).
func sentenceEnd(t string) int {
	for off := 0; ; {
		p := strings.Index(t[off:], ". ")
		if p < 0 {
			return -1
		}
		pos := off + p
		w := t[:pos]
		if i := strings.LastIndexAny(w, spaceSet); i >= 0 {
			w = w[i+1:]
		}
		lowerNext := pos+2 < len(t) && 'a' <= t[pos+2] && t[pos+2] <= 'z'
		abbrev := reAbbrev.MatchString(lower(w)) || (len(w) == 1 && isASCIIAlpha(w[0]))
		if !lowerNext && !abbrev {
			return pos
		}
		off = pos + 1
	}
}

// cutAt is the largest k <= n that does not split a UTF-8 sequence of s (len(s) when it fits); when every byte
// before n is a continuation byte it gives up and returns n (ALT_CUT_BACKOFF).
func cutAt(s string, n int) int {
	if len(s) <= n {
		return len(s)
	}
	k := n
	for k > 0 && s[k]&0xC0 == 0x80 {
		k--
	}
	if k == 0 {
		return n
	}
	return k
}

// upper is awk toupper under LC_ALL=C.
func upper(s string) string {
	b := []byte(s)
	for i, c := range b {
		if 'a' <= c && c <= 'z' {
			b[i] = c - 'a' + 'A'
		}
	}
	return string(b)
}
