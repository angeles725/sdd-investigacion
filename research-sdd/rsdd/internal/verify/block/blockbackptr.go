package block

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// Section 12 of verify-block: the section-14 BACK-POINTER (kit #1962). A block that CORRECTS an earlier block must
// leave a back-pointer on the old one. When one sentence of the checked block carries a correction act and cites an
// EARLIER block within 60 characters of it, the cited block's file is resolved in the same corpus and the candidate
// is reported when that file holds no pointer to the checked block. ADVISORY: the exit code never changes.
// --backptr=high (default) prints a per-line `BACKPTR?` only for the high-confidence shape; every other candidate is
// counted in one line; --backptr=all lists them all; --backptr=off skips the section. Not-found, ambiguous and
// degraded candidates are typed lines in every mode. Two block-number series coexist (numeric and `R<n>`).
//
// The sentence scan (scanCorrections) is the port of the awk `_vb_bp_pairs`; the candidate resolution is the bash
// loop that followed it. Each narrowing of the scan (neg, self, passive, noun, corrector, far, list) is counted in
// the summary, never silent.

const bpVerb = `refut|corrig|correg|correcci|correct(s|ed|ing|ion)|supersed` // BP-VERBS

var (
	bpFileName  = vbRe(`^(.*-)?(block|bloque)([0-9]+)(-[\p{L}\p{N}_-]+)?\.md$`)
	bpVerbRe    = vbRe(bpVerb)
	bpSplit     = vbRe(`[.!?;]+[[:space:]]+`)
	bpCorrigend = vbRe(`corrigend[a-z]*`)
	bpNeg1      = vbRe(`[^a-z](no|not a|without|ninguna?)[[:space:]]+(§14[ -]?[a-z]*[[:space:]]+)?([^[:space:]]+[[:space:]]+)?([^[:space:]]+[[:space:]]+)?(correction|correcci.n|refut[a-z]*)`)
	bpNotOnly   = vbRe(`[^a-z]not (only|just|merely)`)
	bpNeg2      = vbRe(`[^a-z](nothing|without|never|rather than|instead of|not|no|nada)[[:space:]]+([a-z]+[[:space:]]+)?(here[[:space:]]+)?(correct|refut|supersed|corrig)[a-z]*`)
	bpNeg3      = vbRe(`(correct|refut|supersed|corrig)[a-z]*[[:space:]]+(nothing|nada|no[[:space:]]+(earlier|prior|previous))`)
	bpSelf      = vbRe(`self-correct[a-z]*|auto-?correc[a-z]*`)
	bpPassive   = vbRe(`[^a-z](was|were|been|already|got|is|are|be)[[:space:]]+(also[[:space:]]+)?(corrected|refuted|superseded)`)
	bpCite      = vbRe(`([Bb]lock|[Bb]loque) ?R?[0-9]+|B[0-9]+|R[0-9]+`)
	bpCorrector = vbRe(`(corrected|refuted|superseded|corregid[oa]s?|refutad[oa]s?|supersedid[oa]s?)[[:space:]]+(by|in|en|por)[[:space:]]*[\[(*]*$`)
	bpConnects  = vbRe(`connects|conecta|related|see also`)
	bpTail      = vbRe(`^(\]|\*|\)|[[:space:]]|:|-|—|–)*$`)
	bpWord      = vbRe(`^[A-Za-z0-9_]$`)
	bpAlphaUnd  = vbRe(`[A-Za-z_]`)
	bpTabQuote  = vbRe(`[\t"]+`)
	bpLeadSpace = vbRe(`^[[:space:]]+`)
	bpFenceLine = vbRe("^```")
	bpBlank     = vbRe(`^[[:space:]]*$`)
	bpHeading   = vbRe(`^#`)
	bpRHeading  = vbRe(`^#+[[:space:]]*(Block|Bloque)[[:space:]]+R[0-9]`)
	bpListItem  = vbRe(`^[[:space:]]*([-*+]|[0-9]+[.)]|\|)`)
	bpFileH1    = vbRe(`^#+[[:space:]]*(Block|Bloque)[[:space:]]+R[0-9]`)
	bpBlockFile = vbRe(`(^|/)[^/]+-(block|bloque)[0-9]+(-[\p{L}\p{N}_-]+)?\.md$`)
)

type bpCand struct {
	line int
	ser  string // "R" or "N"
	num  int
	conf string // "high" or "low"
	ex   string
}

type bpTrailer struct{ sentences, forward, list, neg, self, passive, noun, corrector, far int }

// scanCorrections is `_vb_bp_pairs`: the correction candidates of the checked block (first-seen order) and the
// counts of the sentences and cites each filter suppressed. self is the checked block's own number.
func scanCorrections(lines []string, self int) (cands []bpCand, tr bpTrailer, rmode bool) {
	var para string
	firstline := 0
	fence := false
	hseen := false
	seen := map[string]int{}

	scan := func(sent string) {
		if !bpVerbRe.MatchString(awkLower(sent)) {
			return
		}
		low := " " + awkLower(sent)
		low = blankRe(low, bpCorrigend) // BP-CORRIGEND
		if !bpVerbRe.MatchString(low) {
			tr.noun++
			return
		}
		low = blankRe(low, bpNeg1)                      // BP-NEG
		low = blankRe(neuterRe(low, bpNotOnly), bpNeg2) // BP-NEG2
		low = blankRe(low, bpNeg3)                      // BP-NEG3
		if !bpVerbRe.MatchString(low) {
			tr.neg++
			return
		}
		low = blankRe(low, bpSelf) // BP-SELF
		if !bpVerbRe.MatchString(low) {
			tr.self++
			return
		}
		low = blankRe(low, bpPassive) // BP-PASSIVE
		if !bpVerbRe.MatchString(low) {
			tr.passive++
			return
		}
		low = awkTail(low, 2)
		tr.sentences++
		selfser := "N"
		if rmode {
			selfser = "R"
		}
		type dcite struct {
			ser  string
			num  int
			conf string
		}
		var ds []dcite
		idx := map[string]int{}
		rest := sent
		off := 0
		for {
			rs, rl, ok := awkMatch(bpCite, rest)
			if !ok {
				break
			}
			tokS := awkSubstr(rest, rs, rl)
			cs := off + rs
			pre := awkSubstr(sent, cs-1, 1) // "" for a cite at the start of the sentence
			post := awkSubstr(rest, rs+rl, 1)
			off += rs + rl - 1
			rest = awkTail(rest, rs+rl)
			keep := true
			if pre != "" && bpWord.MatchString(pre) { // BP-PRETOK
				keep = false
			}
			if (tokS[0] == 'B' || tokS[0] == 'R') && tokS[1] >= '0' && tokS[1] <= '9' && post != "" && bpAlphaUnd.MatchString(post) { // BP-POSTTOK
				keep = false
			}
			if tokS[0] == 'R' && tokS[1] >= '0' && tokS[1] <= '9' && !rmode { // BP-RMODE
				keep = false
			}
			if !keep {
				continue
			}
			kw := strings.HasPrefix(tokS, "Blo") || strings.HasPrefix(tokS, "blo")
			ser := "N"
			if regexp.MustCompile(`R[0-9]+$`).MatchString(tokS) {
				ser = "R"
			}
			ctx := awkSubstr(low, cs-40, 40)  // the 40 characters before the cite (fewer near the sentence start)
			if bpCorrector.MatchString(ctx) { // BP-CORRECTOR
				tr.corrector++
				continue
			}
			mg, bvs := 99999, 0
			n := low
			for {
				ms, ml, ok := awkMatch(bpVerbRe, n)
				if !ok {
					break
				}
				vs := utf8.RuneCountInString(low) - utf8.RuneCountInString(n) + ms
				// A verb never overlaps the cite, so the distance is positive on one side only.
				gap := max(cs-(vs+ml), vs-(cs+rl))
				if gap < mg {
					mg, bvs = gap, vs
				}
				n = awkTail(n, ms+ml)
			}
			if mg > 60 { // BP-PROXIMITY
				tr.far++
				continue
			}
			// Text between the cite and an act after it; empty (and so a match) for an act before the cite.
			tail := awkSubstr(low, cs+rl, bvs-(cs+rl))
			conf := "low"
			if kw && mg <= 25 && bpTail.MatchString(tail) { // BP-CONF
				conf = "high"
			}
			num, _ := strconv.Atoi(strings.Map(func(r rune) rune {
				if r >= '0' && r <= '9' {
					return r
				}
				return -1
			}, tokS))
			key := ser + "\x1c" + strconv.Itoa(num)
			if i, ok := idx[key]; !ok {
				idx[key] = len(ds)
				ds = append(ds, dcite{ser, num, conf})
			} else if conf == "high" {
				ds[i].conf = "high"
			}
		}
		if len(ds) == 0 {
			return
		}
		if len(ds) >= 3 || (len(ds) >= 2 && (bpConnects.MatchString(low) || strings.Count(sent, " · ") >= 2)) { // BP-LIST
			tr.list++
			return
		}
		for _, d := range ds {
			if d.ser == selfser && d.num >= self { // BP-FORWARD
				tr.forward++
				continue
			}
			key := d.ser + "\x1c" + strconv.Itoa(d.num)
			ex := bpTabQuote.ReplaceAllString(sent, " ")
			ex = bpLeadSpace.ReplaceAllString(ex, "")
			ex = awkSubstr(ex, 1, 110)
			if i, ok := seen[key]; !ok {
				seen[key] = len(cands)
				cands = append(cands, bpCand{firstline, d.ser, d.num, d.conf, ex})
			} else if d.conf == "high" && cands[i].conf != "high" { // BP-MAXCONF
				cands[i].conf, cands[i].line, cands[i].ex = "high", firstline, ex
			}
		}
	}
	flush := func() {
		if para == "" {
			return
		}
		rest := para
		for rest != "" {
			var sent string
			if loc := bpSplit.FindStringIndex(rest); loc != nil {
				sent, rest = rest[:loc[0]], rest[loc[1]:]
			} else {
				sent, rest = rest, ""
			}
			scan(sent)
		}
		para = ""
	}
	for i, l := range lines {
		nr := i + 1
		switch {
		case bpFenceLine.MatchString(l):
			fence = !fence
			flush()
		case fence:
		case bpBlank.MatchString(l):
			flush()
		case bpHeading.MatchString(l):
			flush()
			if !hseen {
				hseen = true
				if bpRHeading.MatchString(l) {
					rmode = true
				}
			}
			para, firstline = l, nr
			flush()
		case bpListItem.MatchString(l):
			flush()
			para, firstline = l, nr
		default:
			if para == "" {
				firstline = nr
				para = l
			} else {
				para = para + " " + l
			}
		}
	}
	flush()
	return cands, tr, rmode
}

func (b *blockRun) sectionBackptr() {
	w, inf, amb, deg, okN, low := 0, 0, 0, 0, 0, 0
	b.echo("-- §14 back-pointer (kit #1962: a block that corrects an earlier block must be pointed back to from it; advisory, exit unchanged) --")
	base := shellx.BaseName(b.block)
	m := bpFileName.FindStringSubmatch(base)
	switch {
	case b.backptr == "off":
		b.echo("   (back-pointer check off — --backptr=off)")
		return
	case m == nil:
		b.echo("   (back-pointer check skipped — '%s' is not a canonical block file name: <prefix>-(block|bloque)<N>[-slug].md)", base)
		return
	}
	pfx := m[1]
	self, _ := strconv.Atoi(strings.TrimLeft(m[3], "0"))
	var dirs []string
	for _, x := range []string{shellx.DirName(b.block), b.target} {
		p, ok := b.physical(x)
		if !ok {
			continue
		}
		if len(dirs) > 0 && dirs[0] == p {
			continue
		}
		dirs = append(dirs, p)
	}
	cands, tr, rmode := scanCorrections(b.lines, self)
	if b.unreadable || len(dirs) == 0 { // VB-UNREADABLE: the script's sentence scan exited 2 on an unreadable block
		awkRC := 0
		if b.unreadable {
			awkRC = 2
		}
		b.echo("   DEGRADED backptr: the sentence scan or the candidate directory failed (awk exit %d, %d directories) — back-pointers NOT checked", awkRC, len(dirs))
		deg++
		cands, tr, rmode = nil, bpTrailer{}, false
	}
	type bfile struct {
		path, prefix string
		dir, num     int
	}
	var files []bfile
	dbad := map[int]bool{}
	for di, d := range dirs {
		names, ok := bpListMarkdown(d)
		if !ok {
			dbad[di] = true
			continue
		}
		for _, n := range names {
			p := joinFind(d, n)
			if !bpBlockFile.MatchString(p) {
				continue
			}
			fm := bpFileName.FindStringSubmatch(n)
			if fm == nil {
				continue
			}
			num, _ := strconv.Atoi(strings.TrimLeft(fm[3], "0"))
			files = append(files, bfile{p, fm[1], di, num})
		}
	}
	slab := "B" + strconv.Itoa(self)
	var ptr *regexp.Regexp
	if rmode {
		slab = "R" + strconv.Itoa(self)
		ptr = regexp.MustCompile(`(^|[^A-Za-z0-9_])((([Bb]lock|[Bb]loque) ?)?R)0*` + strconv.Itoa(self) + `([^0-9A-Za-z_]|$)`) // BP-BOUNDARY
	} else {
		ptr = regexp.MustCompile(`(^|[^A-Za-z0-9_])(([Bb]lock|[Bb]loque) ?|B)0*` + strconv.Itoa(self) + `([^0-9A-Za-z_]|$)`)
	}
	for _, c := range cands {
		cl := strconv.Itoa(c.num)
		if c.ser == "R" {
			cl = "R" + cl
		}
		var cand []string
		scanbad := false
	passes:
		for _, pass := range []string{"same", "any"} {
			for di := range dirs {
				if dbad[di] {
					scanbad = true
					continue
				}
				for _, f := range files {
					if f.dir != di || f.num != c.num {
						continue
					}
					if pass == "same" && f.prefix != pfx { // BP-PREFIX
						continue
					}
					if fs, rc := fileSeries(b, f.path); rc == 0 && fs != c.ser { // BP-SERIES
						continue
					}
					cand = append(cand, f.path)
				}
				if len(cand) > 0 {
					break
				}
			}
			if len(cand) > 0 {
				break passes
			}
		}
		state, msg := "", ""
		switch {
		case len(cand) == 0:
			if scanbad { // BP-SCANBAD
				state, msg = "degraded", fmt.Sprintf("   DEGRADED backptr: line %d: block %s — the candidate scan under %s failed; back-pointer NOT checked", c.line, cl, strings.Join(dirs, " "))
			} else {
				state, msg = "notfound", fmt.Sprintf("   INFO    backptr: line %d cites block %s but its block file is not found under %s — back-pointer NOT checked", c.line, cl, strings.Join(dirs, " "))
			}
		case len(cand) > 1: // BP-AMBIG
			var names []string
			for _, f := range cand {
				names = append(names, shellx.BaseName(f))
			}
			state, msg = "ambig", fmt.Sprintf("   BACKPTR-AMBIGUOUS  line %d: block %s matches %d files (%s) — back-pointer NOT checked; disambiguate by hand", c.line, cl, len(cand), strings.Join(names, ", "))
		default:
			old := cand[0]
			src, err := b.fs.Read(old)
			switch {
			case err != nil || !b.fs.Readable(old): // BP-UNREADABLE
				state, msg = "degraded", fmt.Sprintf("   DEGRADED backptr: line %d: block %s (%s) is unreadable — back-pointer NOT checked", c.line, cl, shellx.BaseName(old))
			case bpPointer(ptr, string(src)): // BP-POINTER
				state, msg = "ok", fmt.Sprintf("   backptr-ok  line %d: block %s (%s) points back to %s", c.line, cl, shellx.BaseName(old), slab)
			default:
				state, msg = "missing", fmt.Sprintf("   BACKPTR?  line %d: possible correction of block %s (%s); verify by hand, then consider a back-pointer to %s in %s (§14; advisory, exit unchanged) — sentence: \"%s\"", c.line, cl, shellx.BaseName(old), slab, shellx.BaseName(old), c.ex)
			}
		}
		switch state {
		case "missing":
			w++
		case "ok":
			okN++
		case "ambig":
			amb++
		case "notfound":
			inf++
		case "degraded":
			deg++
		}
		if b.backptr == "all" || c.conf == "high" || (state != "missing" && state != "ok") { // BP-TYPED
			b.echo("%s", msg)
		} else if state == "missing" {
			low++
		}
	}
	skipped := fmt.Sprintf("forward=%d neg=%d self=%d passive=%d noun=%d corrector=%d far=%d list=%d", tr.forward, tr.neg, tr.self, tr.passive, tr.noun, tr.corrector, tr.far, tr.list)
	if w+inf+amb+deg+okN == 0 {
		b.echo("   (none — no correction sentence cites an earlier block; correction sentences scanned: %d; skipped: %s)", tr.sentences, skipped)
		return
	}
	b.echo("-- back-pointer: %d possibly missing · %d present · %d ambiguous · %d not found · %d degraded (correction sentences: %d; skipped: %s) — advisory, exit unchanged", w, okN, amb, inf, deg, tr.sentences, skipped)
	if low > 0 {
		b.echo("-- back-pointer: %d low-confidence candidate(s) (--backptr=all to list)", low)
	}
}

// bpPointer is `grep -Eq PTR FILE`: some line of the file matches.
func bpPointer(re *regexp.Regexp, src string) bool {
	for _, l := range shellx.RecordLines(src) {
		if re.MatchString(l) {
			return true
		}
	}
	return false
}

// fileSeries is _vb_bp_fser: R when the file's first `#` line is `# Block R<n>`, else N; rc 2 where it is unreadable.
func fileSeries(b *blockRun, path string) (string, int) {
	src, err := b.fs.Read(path)
	if err != nil {
		return "", 2
	}
	for _, l := range shellx.RecordLines(string(src)) {
		if strings.HasPrefix(l, "#") {
			if bpFileH1.MatchString(l) {
				return "R", 0
			}
			return "N", 0
		}
	}
	return "N", 0
}

// listMarkdown is `find DIR -maxdepth 1 -type f -name '*.md' | sort`: regular files only, bytewise order.
func bpListMarkdown(dir string) ([]string, bool) {
	f, err := os.Open(dir)
	if err != nil {
		return nil, false
	}
	ents, err := f.ReadDir(-1)
	f.Close()
	if err != nil {
		return nil, false
	}
	var out []string
	for _, e := range ents {
		if e.Type().IsRegular() && strings.HasSuffix(e.Name(), ".md") {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out, true
}
