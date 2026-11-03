package corrections

import (
	"strings"
)

// The correction-target extractor: a line-by-line port of the awk program `_vc_extract` of verify-corrections.sh
// (the clause-scoped binding of #1790, #1835, #1847, #1868, #1874). It reads one block file and yields typed
// records; the caller (run.go) owns the wording. See the legacy script under testdata/legacy for the rationale of
// every rule; the comments here only name what each function decides.

// Record kinds.
const (
	kindTarget    = 'T' // a plain declared target: n
	kindQualified = 'Q' // a target qualified by a focus slug: n, qual, qkind
	kindAmbiguous = 'A' // a typed ambiguous target: cls, n
	kindUnbound   = 'U' // a verb that binds to no bracketed ref in its clause
	kindSkipped   = 'S' // a non-assertive form (passive, conditional, past tense)
	kindNegated   = 'N' // a negated verb
)

type record struct {
	kind  byte
	cls   string // for 'A': object, locator, assumption, bare, list, mixed, possessive
	n     string // the block number as written (zero-padding kept; the caller normalises)
	qual  string
	qkind string // hard, soft or lead
}

const (
	prep   = "(al|a|to|of|for)" // the one preposition grammar of a corrigendum declaration
	tagMax = 24                 // the longest `[tag]` (bytes between the brackets) still read as a short tag
	refPat = `\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]`
	joiner = `^[ \t0-9.,-]*(and|y|e|&|/)[ \t0-9.,-]*$`
)

var (
	reRef          = posix(refPat)
	reRefHead      = posix(`^` + refPat)
	reRefHeadWs    = posix(`^[ \t]*` + refPat)
	reRefTail      = posix(refPat + `$`)
	reJoin         = posix(joiner)
	reQuoteStrip   = posix(`^[ \t]*(>[ \t]*)+`)
	reBlank        = posix(`^[ \t]*$`)
	reListHead     = posix(`^[ \t]*([-*+]|[0-9]+[.)])[ \t]`)
	reHeading      = posix(`^[ \t]*#`)
	reTableRow     = posix(`^[ \t]*\|`)
	reVerb         = posix(`(^|` + nonWord + `)(corrects|corrig[a-z]*)`)
	reSe           = posix(`(^|` + nonWord + `)se[ \t]+$`)
	reNegPre       = posix(`(^|` + nonWord + `)(no|nunca|never|tampoco)[ \t]+$`)
	reComma        = posix(`^,[ \t]+(and|but|while|y|pero)[ \t]`)
	reBare         = posix(`(^|` + nonWord + `)b[0-9]+`)
	reGapLabel     = posix(`^-[a-z][0-9]`)
	reMoreBare     = posix(`^[ \t0-9.,-]*(and|y|e|&|/)[ \t]*b[0-9]+`)
	reLeadTick     = posix("`[a-z0-9._-]+`[ \t]*$")
	reCorrigend    = posix(`^corrigend`)
	reNounDecl     = posix(`^[ \t]*(` + "`?" + `\[[^]\[]*\]` + "`?" + `)?[ \t]*` + prep + `[ \t]+(the[ \t]+)?`)
	reTag          = posix("`?" + `\[[^]\[]*\]` + "`?")
	reTagStrip     = posix("^`?" + `\[|\]` + "`?" + `[ \t]*$`)
	reTagBlockish  = posix(`(block|bloque)[ \t]*[0-9]`)
	reLeadOf       = posix(`(^|[^a-z0-9])of[ \t]+(the[ \t]+)?$`)
	reTagHead      = posix("^`?" + `\[[^]\[]*\]` + "`?" + `[ \t]*`)
	reAfterNoun    = posix(`^[ \t]*` + prep + `[ \t]+(the[ \t]+)?` + refPat)
	reExcPost      = posix(`^[ \t]+(nothing|none|nada|anything)[ \t]+(but|except|salvo|excepto|other|m[^ \t]*s[ \t]+que)`)
	reNegNothing   = posix(`^[ \t]+(nothing|none|nada)([ \t,.;]|$)`)
	reNegNo        = posix(`^[ \t]+(no|ninguna?)[ \t]+[^ \t]+[ \t]+(in|of|en|de|del|about|sobre)[ \t]`)
	reNegNoStrip   = posix(`^[ \t]+(no|ninguna?)[ \t]+`)
	reRestAfterWs  = posix(`[ \t].*$`)
	reNegWord      = posix(`^(longer|only|solo|fewer|less|menos|more|than|further|m[^ \t]*s|s[^ \t]*lo)$`)
	reTrailQ       = posix("^[ \t]*(of|del|de|in|en)[ \t]+(the[ \t]+|el[ \t]+)?(focus[ \t]+)?`[a-z0-9._-]+`([ \t]+focus)?")
	reTickToken    = posix("`[^`]*`")
	reHeadToTick   = posix("^[^`]*`")
	reTickToEnd    = posix("`.*$")
	reAssumption   = posix(`(assumption|expectation|suposici[^ ]*)[ \t]+(behind|underlying|detr[^ ]*|subyacente)[ \t]*(the[ \t]+|el[ \t]+|la[ \t]+)?$`)
	reLocator      = posix(`(junto[ \t]+a|together[ \t]+with|alongside|along[ \t]+with)[ \t]*(the[ \t]+|el[ \t]+|la[ \t]+)?$`)
	reObjectPoss   = posix(`^[ \t]*(this|that|the|our|my)[ \t]+(focus|caller|backlog|queue|session|run)('|’)s[ \t]`)
	reObjectGap    = posix(`(^|` + nonWord + `)b[0-9]+-[a-z][0-9]+`)
	reTrailWs      = posix(`[ \t]+$`)
	reSectionSign  = "\xc2\xa7"
	reEnDash       = "\xe2\x80\x93"
	middleDot      = "\xc2\xb7"
	abbreviations  = " cf e.g i.e vs fig p pp approx aprox pág pag núm num sec sect eq no "
	singleLetterRe = posix(`^[a-z]$`)
)

// extractor holds the awk program's globals: the focus qualifier of the clause, the bare-ref positions, the
// pending output and the dedupe set (never cleared within one file, as `seen` never was).
type extractor struct {
	cls, qcur, qkind string
	bp, be           int // BP/BE: start and end of the last bare B<N> found by barenum
	ndn              string
	seen             map[string]bool
	out              []record
	units            []string
	cur              string
}

// extract runs the program over the text of one block file.
func extract(text string) []record {
	x := &extractor{seen: map[string]bool{}}
	for _, line := range splitRecords(text) {
		if loc := reQuoteStrip.FindStringIndex(line); loc != nil {
			line = line[loc[1]:]
		}
		if reBlank.MatchString(line) {
			x.flush()
			continue
		}
		if reListHead.MatchString(line) || reHeading.MatchString(line) || reTableRow.MatchString(line) {
			x.flush()
		}
		if x.cur == "" {
			x.cur = line
		} else {
			x.cur = x.cur + " " + line
		}
	}
	x.flush()
	for _, u := range x.units {
		x.scan(u)
	}
	return x.out
}

// splitRecords splits like awk's default record separator: a trailing newline ends the last record; an empty text has none.
func splitRecords(text string) []string {
	if text == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(text, "\n"), "\n")
}

func (x *extractor) flush() {
	if x.cur != "" {
		x.units = append(x.units, x.cur)
		x.cur = ""
	}
}

// emit records a target once per (class, qualifier, number).
func (x *extractor) emit(n string) {
	k := x.cls + "|" + x.qcur + "|" + trimZeros(n) // `[Block 8]` and `[Block 008]` are one target
	if x.seen[k] {
		return
	}
	x.seen[k] = true
	switch {
	case x.cls != "":
		x.out = append(x.out, record{kind: kindAmbiguous, cls: x.cls, n: n})
	case x.qcur != "":
		x.out = append(x.out, record{kind: kindQualified, n: n, qual: x.qcur, qkind: x.qkind})
	default:
		x.out = append(x.out, record{kind: kindTarget, n: n})
	}
}

func (x *extractor) print(kind byte) { x.out = append(x.out, record{kind: kind}) }

// refnum is the number of the first [Block N] in t ("" when none).
func refnum(t string) string {
	if s, l := match(reRef, t); s > 0 {
		return digitsOf(substr(t, s, l))
	}
	return ""
}

// joinGap normalises the text between two refs of a list the way the program does before testing it.
func joinGap(g string) string {
	g = strings.ReplaceAll(g, reSectionSign, "")
	return strings.ReplaceAll(g, reEnDash, "-")
}

// startsWordByte is `s ~ /^[a-z_\200-\377]/`.
func startsWordByte(s string) bool {
	return s != "" && (s[0] >= 'a' && s[0] <= 'z' || s[0] == '_' || s[0] >= 0x80)
}

// barenum finds the first bare `B<N>` (not a gap label such as B50-G6, not part of a longer word) in t.
func (x *extractor) barenum(t string) string {
	rest, off := t, 0
	x.bp, x.be = 0, 0
	for {
		rs, rl := match(reBare, rest)
		if rs == 0 {
			return ""
		}
		m := substr(rest, rs, rl)
		nx := from(rest, rs+rl)
		if !startsWordByte(nx) && !reGapLabel.MatchString(nx) {
			x.bp = off + rs
			x.be = off + rs + rl - 1
			return digitsOf(m)
		}
		off += rs + rl - 1
		rest = nx
	}
}

// moreb emits every further bare B<N> joined to the previous one, then every bracketed [Block N] joined to that
// list as class `mixed`.
func (x *extractor) moreb(t string) {
	rest := from(t, x.be+1)
	for {
		rs, rl := match(reMoreBare, rest)
		if rs == 0 {
			break
		}
		tok := substr(rest, 1, rl)
		nx := from(rest, rl+1)
		if startsWordByte(nx) || reGapLabel.MatchString(nx) {
			break
		}
		x.emit(tok[strings.LastIndexByte(tok, 'b')+1:]) // the digits after the last `b` (no `b`: -1+1 keeps the token)
		rest = nx
	}
	for {
		rs, rl := match(reRef, rest)
		if rs == 0 {
			return
		}
		gm := substr(rest, rs, rl)
		gp := substr(rest, 1, rs-1)
		rest = from(rest, rs+rl)
		if !reJoin.MatchString(joinGap(gp)) {
			return
		}
		sv := x.cls
		x.cls = "mixed"
		x.emit(digitsOf(gm))
		x.cls = sv
	}
}

// classify decides the inferential classes from the text between the verb and the ref (or the clause object).
func classify(pre string) string {
	if reAssumption.MatchString(pre) {
		return "assumption"
	}
	if reLocator.MatchString(pre) {
		return "locator"
	}
	if reObjectPoss.MatchString(pre) || reObjectGap.MatchString(pre) {
		return "object"
	}
	return ""
}

// more emits the refs joined to the first [Block N] of the clause cl by and/y/e/&/ and "/".
func (x *extractor) more(cl string) {
	rs, rl := match(reRef, cl)
	if rs == 0 {
		return
	}
	rest := from(cl, rs+rl)
	for {
		st, ln := match(reRef, rest)
		if st == 0 {
			return
		}
		g := joinGap(substr(rest, 1, st-1))
		m := substr(rest, st, ln)
		if !reJoin.MatchString(g) {
			return
		}
		x.emit(digitsOf(m))
		rest = from(rest, st+ln)
	}
}

// listend is the index just past the last ref of the joined list that starts at the first ref of cl.
func listend(cl string) int {
	rs, rl := match(reRef, cl)
	pos := rs + rl - 1
	rest := from(cl, pos+1)
	for {
		st, ln := match(reRef, rest)
		if st == 0 {
			break
		}
		g := joinGap(substr(rest, 1, st-1))
		if !reJoin.MatchString(g) {
			break
		}
		pos += st + ln - 1
		rest = from(rest, st+ln)
	}
	return pos + 1
}

// postlist: the verb sat in a parenthetical that follows t (the text before its opening paren, ending in a ref).
// Only the first ref of the joined list is the declaration; every later one is a typed `list` ambiguity.
func (x *extractor) postlist(t string) {
	var lrs, lre []int
	var lrn []string
	rest, off := t, 0
	lrs, lre, lrn = append(lrs, 0), append(lre, 0), append(lrn, "") // 1-based
	for {
		rs, rl := match(reRef, rest)
		if rs == 0 {
			break
		}
		lrs = append(lrs, off+rs)
		lre = append(lre, off+rs+rl-1)
		lrn = append(lrn, digitsOf(substr(rest, rs, rl)))
		adv := rs + rl - 1
		off += adv
		rest = from(rest, adv+1)
	}
	nn := len(lrs) - 1
	first := nn
	for first > 1 {
		g := substr(t, lre[first-1]+1, lrs[first]-lre[first-1]-1)
		if strings.Contains(g, ". ") || strings.Contains(g, ".\t") || strings.Contains(g, ";") || strings.Contains(g, middleDot) {
			break
		}
		if reJoin.MatchString(joinGap(g)) {
			first--
		} else {
			break
		}
	}
	x.emit(lrn[first])
	for k := first + 1; k <= nn; k++ {
		sv := x.cls
		if x.cls == "" {
			x.cls = "list"
		}
		x.emit(lrn[k])
		x.cls = sv
	}
}

// excpost: the text after the verb is `nothing/anything but …`, an exception, so the verb still declares.
func excpost(post string) bool { return reExcPost.MatchString(post) }

// negpost: the text right after the verb negates it.
func negpost(post string) bool {
	if reNegNothing.MatchString(post) {
		return !excpost(post)
	}
	if rs, rl := match(reNegNo, post); rs > 0 {
		w := substr(post, rs, rl)
		if loc := reNegNoStrip.FindStringIndex(w); loc != nil {
			w = w[loc[1]:]
		}
		if loc := reRestAfterWs.FindStringIndex(w); loc != nil {
			w = w[:loc[0]]
		}
		return !reNegWord.MatchString(w)
	}
	return false
}

// trailq: post starts with a focus qualifier; it sets qcur/qkind when so.
func (x *extractor) trailq(post string) bool {
	rs, rl := match(reTrailQ, post)
	if rs == 0 {
		return false
	}
	qm := substr(post, rs, rl)
	qt := qm
	if loc := reTickToken.FindStringIndex(qt); loc != nil {
		qt = qt[:loc[0]] + qt[loc[1]:]
	}
	if strings.Contains(qt, "focus") {
		x.qkind = "hard"
	} else {
		x.qkind = "soft"
	}
	if loc := reHeadToTick.FindStringIndex(qm); loc != nil {
		qm = qm[loc[1]:]
	}
	if loc := reTickToEnd.FindStringIndex(qm); loc != nil {
		qm = qm[:loc[0]]
	}
	x.qcur = qm
	return true
}

// tagok: t is a bracket tag incl. brackets/backticks; true when it is short and not a block ref.
func tagok(t string) bool {
	inner := reTagStrip.ReplaceAllString(t, "")
	return len(inner) <= tagMax && !reTagBlockish.MatchString(inner)
}

// noundecl classifies the text after a corrigendum noun: 1 = `[tag] <preposition> [the] [tag] [Block N]`,
// 2 = a bare possessive `of [Block N]` (number in ndn), 0 = anything else.
func (x *extractor) noundecl(rest string) int {
	rs, rl := match(reNounDecl, rest)
	if rs == 0 {
		return 0
	}
	lead := substr(rest, 1, rl)
	tail := from(rest, rl+1)
	ts, tl := match(reTag, lead)
	hasl := ts > 0
	if hasl && !tagok(substr(lead, ts, tl)) {
		return 0
	}
	if reRefHead.MatchString(tail) {
		if !hasl && reLeadOf.MatchString(lead) {
			x.ndn = refnum(tail)
			return 2
		}
		return 1
	}
	if hs, hl := match(reTagHead, tail); hs != 0 { // match gives hs >= 0 (0: no match), so != 0 is "matched"
		tg := substr(tail, 1, hl)
		tail = from(tail, hl+1)
		if tagok(tg) && reRefHead.MatchString(tail) {
			return 1
		}
	}
	return 0
}

// abbrev: the `.` at index i of l follows a known abbreviation or a single-letter initial.
func abbrev(l string, i int) bool {
	k := i - 1
	for k >= 1 && !strings.ContainsRune(" \t([;,:", rune(substr(l, k, 1)[0])) {
		k--
	}
	tok := substr(l, k+1, i-1-k)
	if tok == "" {
		return false
	}
	return singleLetterRe.MatchString(tok) || strings.Contains(abbreviations, " "+tok+" ")
}

// scan processes one logical unit (a paragraph / blockquote run).
func (x *extractor) scan(un string) {
	l := asciiLower(un)
	n := len(un)
	p := 1
	for {
		// Past the end `rest` is empty and reVerb (which needs a verb) cannot match it, so the loop ends by the break
		// below with no bound test of its own.
		rest := from(l, p)
		rs, rl := match(reVerb, rest)
		if rs == 0 {
			break
		}
		ms := p + rs - 1
		vs := ms + 1
		if substr(l, ms, 1) == "c" { // every verb starts with `c`; the optional boundary char before it is never a letter
			vs = ms
		}
		ve := ms + rl
		if substr(l, vs, 8) == "corrects" && wordAt(l, ve) {
			p = ve
			continue
		}
		tok := substr(l, vs, ve-vs)
		x.cls, x.qcur, x.qkind = "", "", ""
		isnoun := false
		if reCorrigend.MatchString(tok) {
			isnoun = true
			rest = from(l, ve)
			if s, rl := match(reRefHeadWs, rest); s > 0 {
				if reAfterNoun.MatchString(from(rest, rl+1)) {
					ve += rl
				} else {
					p = ve
					continue
				}
			} else if nd := x.noundecl(rest); nd == 2 {
				x.out = append(x.out, record{kind: kindAmbiguous, cls: "possessive", n: x.ndn})
				p = ve
				continue
			} else if nd == 0 {
				x.print(kindUnbound)
				p = ve
				continue
			}
		}
		nb := substr(l, ve, 1)
		past := false
		if tok == "corrigi" && (substr(l, ve, 2) == "\xc3\xb3" || substr(l, ve, 2) == "\xc3\x93") {
			if wordAt(l, ve+2) {
				x.print(kindUnbound)
				p = ve + 2
				continue
			}
			past = true
		} else if nb != "" && (nb[0] >= '0' && nb[0] <= '9' || nb[0] == '_' || nb[0] >= 0x80) {
			x.print(kindUnbound)
			p = ve
			continue
		}
		pre := substr(l, 1, vs-1)
		if reSe.MatchString(pre) || tok == "corrigieron" || tok == "corrigio" || past {
			x.print(kindSkipped)
			p = ve
			continue
		}
		if !isnoun && ((reNegPre.MatchString(pre) && !excpost(from(l, ve))) || negpost(from(l, ve))) {
			x.print(kindNegated)
			p = ve
			continue
		}
		d := 0
		bd := ""
		i := ve
	clause:
		for ; i <= n; i++ {
			c := un[i-1]
			switch {
			case c == '(':
				d++
			case c == ')':
				if d == 0 {
					bd = "close"
					break clause
				}
				d--
			case c == ';':
				break clause
			case c == ',' && reComma.MatchString(substr(l, i, 12)):
				break clause
			case substr(un, i, 2) == middleDot:
				break clause
			case c == '.' && (i == n || un[i] == ' ' || un[i] == '\t') && !abbrev(l, i):
				break clause
			}
		}
		cl := substr(l, ve, i-ve)
		r := refnum(cl)
		done := false
		bn := x.barenum(cl)
		rstart := 0
		if r != "" {
			rstart, _ = match(reRef, cl)
		}
		switch {
		case bn != "" && (r == "" || x.bp < rstart):
			x.cls = "bare"
			x.emit(bn)
			x.moreb(cl)
			done = true
		case r != "":
			pre = substr(cl, 1, rstart-1)
			x.cls = classify(pre)
			x.qcur, x.qkind = "", ""
			if x.cls == "" {
				if s, l2 := match(reLeadTick, pre); s > 0 {
					qm := strings.NewReplacer("`", "", " ", "", "\t", "").Replace(substr(pre, s, l2))
					x.qcur, x.qkind = qm, "lead"
				} else {
					// A qualifier right after the first ref and one after the whole joined list are the same text when the
					// qualifier follows the first ref (its words are not a join gap, so the list ends at that ref):
					// the one lookup after the list end covers both.
					x.trailq(from(cl, listend(cl)))
				}
			}
			x.emit(r)
			x.more(cl)
			done = true
			x.qcur, x.qkind = "", ""
		case !isnoun && bd == "close":
			d = 0
			j := ms // the scan back from the verb may start anywhere inside the verb word (no parenthesis there)
			for ; j > 0; j-- {
				c := un[j-1]
				if c == ')' {
					d++
				} else if c == '(' {
					if d == 0 {
						break
					}
					d--
				}
			}
			if j > 0 {
				pre = substr(l, 1, j-1)
				pre = reTrailWs.ReplaceAllString(pre, "")
				if reRefTail.MatchString(pre) {
					x.cls = classify(cl)
					x.postlist(pre)
					done = true
				}
			}
		}
		if !done {
			x.print(kindUnbound)
		}
		p = ve
	}
}
