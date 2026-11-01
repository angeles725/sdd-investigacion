package verify

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Section 12 of verify-block.sh, the section 14 BACK-POINTER check (kit #1962): a sentence of the checked block
// that corrects an earlier block must find a pointer back to the checked block in that earlier block. The awk
// sentence scanner (_vb_bp_pairs) is reproduced over characters (gawk positions count characters); the
// resolution of the cited block file follows the script step by step. Advisory: the exit code never changes.

const bpVerb = `refut|corrig|correg|correcci|correct(s|ed|ing|ion)|supersed`

var (
	reBPVerb      = newVB(bpVerb)
	reBPSplit     = newVB(`[.!?;]+[` + spc + `]+`)
	reBPCorrigend = newVB(`corrigend[a-z]*`)
	reBPNeg1      = newVB(`[^a-z](no|not a|without|ninguna?)[` + spc + `]+(§14[ -]?[a-z]*[` + spc + `]+)?([^` + spc + `]+[` + spc + `]+)?([^` + spc + `]+[` + spc + `]+)?(correction|correcci.n|refut[a-z]*)`)
	reBPNotOnly   = newVB(`[^a-z]not (only|just|merely)`)
	reBPNeg2      = newVB(`[^a-z](nothing|without|never|rather than|instead of|not|no|nada)[` + spc + `]+([a-z]+[` + spc + `]+)?(here[` + spc + `]+)?(correct|refut|supersed|corrig)[a-z]*`)
	reBPNeg3      = newVB(`(correct|refut|supersed|corrig)[a-z]*[` + spc + `]+(nothing|nada|no[` + spc + `]+(earlier|prior|previous))`)
	reBPSelf      = newVB(`self-correct[a-z]*|auto-?correc[a-z]*`)
	reBPPassive   = newVB(`[^a-z](was|were|been|already|got|is|are|be)[` + spc + `]+(also[` + spc + `]+)?(corrected|refuted|superseded)`)
	reBPCite      = newVB(`([Bb]lock|[Bb]loque) ?R?[0-9]+|B[0-9]+|R[0-9]+`)
	reBPCorrector = newVB(`(corrected|refuted|superseded|corregid[oa]s?|refutad[oa]s?|supersedid[oa]s?)[` + spc + `]+(by|in|en|por)[` + spc + `]*[\[(*]*$`)
	reBPTail      = newVB(`^(\]|\*|\)|[` + spc + `]|:|-|—|–)*$`)
	reBPRList     = newVB(`connects|conecta|related|see also`)
	reBPEx        = newVB(`[\t"]+`)
	reBPRHeading  = newVB(`^#+[` + spc + `]*(Block|Bloque)[` + spc + `]+R[0-9]`)
	reBPTokR      = newVB(`R[0-9]+$`)
	reBPBlockName = newVB(`^(block|bloque)([0-9]+)(-[\p{L}\p{N}_-]+)?\.md$`)
	reBPFileName  = newVB(`(^|/)[^/]+-(block|bloque)[0-9]+(-[\p{L}\p{N}_-]+)?\.md$`)
)

// bpCand is one `C` record of the scanner: a distinct earlier-block cite sitting in a correction sentence.
type bpCand struct {
	line     int
	ser      string
	num      int64
	conf, ex string
}

// bpStats is the `S` trailer: sentences seen, then the cites and sentences each filter dropped.
type bpStats struct {
	nsent, fwd, list, neg, self, passive, noun, corr, far int
	rmode                                                 bool
}

// blank overwrites every match of re with spaces of the same number of characters.
func blank(s string, re *vbRE) string {
	locs := re.FindAllStringIndex(s)
	if len(locs) == 0 {
		return s
	}
	var b strings.Builder
	last := 0
	for _, l := range locs {
		b.WriteString(s[last:l[0]])
		b.WriteString(strings.Repeat(" ", utf8.RuneCountInString(s[l[0]:l[1]])))
		last = l[1]
	}
	b.WriteString(s[last:])
	return b.String()
}

// neuter turns the first 3 characters of every match of re into "xxx" (same length), so a later pattern
// cannot see them.
func neuter(s string, re *vbRE) string {
	locs := re.FindAllStringIndex(s)
	if len(locs) == 0 {
		return s
	}
	var b strings.Builder
	last := 0
	for _, l := range locs {
		b.WriteString(s[last:l[0]])
		m := []rune(s[l[0]:l[1]])
		b.WriteString("xxx")
		b.WriteString(string(m[3:]))
		last = l[1]
	}
	b.WriteString(s[last:])
	return b.String()
}

// substrR is awk's substr(s, start, n) over characters (1-based start).
func substrR(r []rune, start, n int) string {
	if n <= 0 {
		return ""
	}
	lo := start - 1
	if lo < 0 {
		n += lo
		lo = 0
	}
	if lo >= len(r) || n <= 0 {
		return ""
	}
	hi := min(lo+n, len(r))
	return string(r[lo:hi])
}

func isWordASCII(r rune) bool {
	return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_'
}

type bpScanner struct {
	self      int64
	rmode     bool
	st        bpStats
	firstline int
	cands     []bpCand
	seen      map[string]int
}

// bpPairs is _vb_bp_pairs.
func bpPairs(ls []string, self int64) ([]bpCand, bpStats) {
	sc := &bpScanner{self: self, seen: map[string]int{}}
	para := ""
	fence, hseen := false, false
	flush := func() {
		if para == "" {
			return
		}
		rest := para
		for rest != "" {
			var sent string
			if loc := reBPSplit.FindStringIndex(rest); loc != nil {
				sent, rest = rest[:loc[0]], rest[loc[1]:]
			} else {
				sent, rest = rest, ""
			}
			sc.scan(sent)
		}
		para = ""
	}
	for i, l := range ls {
		nr := i + 1
		switch {
		case strings.HasPrefix(l, "```"):
			fence = !fence
			flush()
		case fence:
		case trimSpace(l) == "":
			flush()
		case strings.HasPrefix(l, "#"):
			flush()
			if !hseen {
				hseen = true
				if reBPRHeading.MatchString(l) {
					sc.rmode = true
				}
			}
			para, sc.firstline = l, nr
			flush()
		case rePFList.MatchString(l):
			flush()
			para, sc.firstline = l, nr
		default:
			if para == "" {
				sc.firstline = nr
				para = l
			} else {
				para += " " + l
			}
		}
	}
	flush()
	sc.st.rmode = sc.rmode
	return sc.cands, sc.st
}

func (sc *bpScanner) scan(sent string) {
	if !reBPVerb.MatchString(strings.ToLower(sent)) {
		return
	}
	low := " " + strings.ToLower(sent)
	low = blank(low, reBPCorrigend)
	if !reBPVerb.MatchString(low) {
		sc.st.noun++
		return
	}
	low = blank(low, reBPNeg1)
	low = blank(neuter(low, reBPNotOnly), reBPNeg2)
	low = blank(low, reBPNeg3)
	if !reBPVerb.MatchString(low) {
		sc.st.neg++
		return
	}
	low = blank(low, reBPSelf)
	if !reBPVerb.MatchString(low) {
		sc.st.self++
		return
	}
	low = blank(low, reBPPassive)
	if !reBPVerb.MatchString(low) {
		sc.st.passive++
		return
	}
	_, w := utf8.DecodeRuneInString(low)
	low = low[w:]
	lowR := []rune(low)
	sc.st.nsent++
	selfser := "N"
	if sc.rmode {
		selfser = "R"
	}
	sentR := []rune(sent)
	// the correction acts of the sentence, as 1-based character positions and lengths
	type verbAt struct{ vs, vl int }
	var verbs []verbAt
	for _, l := range reBPVerb.FindAllStringIndex(low) {
		verbs = append(verbs, verbAt{utf8.RuneCountInString(low[:l[0]]) + 1, utf8.RuneCountInString(low[l[0]:l[1]])})
	}
	type dist struct {
		ser  string
		num  int64
		conf string
	}
	var ds []dist
	idx := map[string]int{}
	rest := sent
	off := 0
	for {
		loc := reBPCite.FindStringIndex(rest)
		if loc == nil {
			break
		}
		tok := rest[loc[0]:loc[1]]
		startRunes := utf8.RuneCountInString(rest[:loc[0]])
		tokLen := utf8.RuneCountInString(tok)
		cs := off + startRunes + 1
		var pre rune = -1
		if cs > 1 {
			pre = sentR[cs-2]
		}
		var post rune = -1
		if after := rest[loc[1]:]; after != "" {
			post, _ = utf8.DecodeRuneInString(after)
		}
		off += startRunes + tokLen
		rest = rest[loc[1]:]
		keep := true
		if pre >= 0 && isWordASCII(pre) {
			keep = false
		}
		isBR := tok[0] == 'B' || tok[0] == 'R'
		if isBR && tok[1] >= '0' && tok[1] <= '9' && post >= 0 && (post >= 'A' && post <= 'Z' || post >= 'a' && post <= 'z' || post == '_') {
			keep = false
		}
		if tok[0] == 'R' && tok[1] >= '0' && tok[1] <= '9' && !sc.rmode {
			keep = false
		}
		if !keep {
			continue
		}
		kw := strings.HasPrefix(tok, "Blo") || strings.HasPrefix(tok, "blo")
		ser := "N"
		if reBPTokR.MatchString(tok) {
			ser = "R"
		}
		// the CORRECTOR, not the corrected: "corrected by B96" names the block that fixed it
		var ctx string
		if cs > 40 {
			ctx = substrR(lowR, cs-40, 40)
		} else {
			ctx = substrR(lowR, 1, cs-1)
		}
		if reBPCorrector.MatchString(ctx) {
			sc.st.corr++
			continue
		}
		mg, bvs, bvl := 99999, 0, 0
		for _, vb := range verbs {
			var gap int
			if cs > vb.vs {
				gap = cs - (vb.vs + vb.vl)
			} else {
				gap = vb.vs - (cs + tokLen)
			}
			if gap < mg {
				mg, bvs, bvl = gap, vb.vs, vb.vl
			}
		}
		if mg > 60 {
			sc.st.far++
			continue
		}
		before := bvs+bvl <= cs
		tail := ""
		if !before {
			tail = substrR(lowR, cs+tokLen, bvs-(cs+tokLen))
		}
		conf := "low"
		if kw && mg <= 25 && (before || reBPTail.MatchString(tail)) {
			conf = "high"
		}
		digits := strings.Map(func(r rune) rune {
			if r >= '0' && r <= '9' {
				return r
			}
			return -1
		}, tok)
		num, _ := strconv.ParseInt(digits, 10, 64)
		key := ser + "\x1c" + strconv.FormatInt(num, 10)
		if i, ok := idx[key]; !ok {
			ds = append(ds, dist{ser, num, conf})
			idx[key] = len(ds) - 1
		} else if conf == "high" {
			ds[i].conf = "high"
		}
	}
	nd := len(ds)
	if nd == 0 {
		return
	}
	if nd >= 3 || (nd >= 2 && (reBPRList.MatchString(low) || strings.Count(sent, " · ") >= 2)) {
		sc.st.list++
		return
	}
	for _, d := range ds {
		if d.ser == selfser && d.num >= sc.self {
			sc.st.fwd++
			continue
		}
		key := d.ser + "\x1c" + strconv.FormatInt(d.num, 10)
		ex := reBPEx.get().ReplaceAllString(sent, " ")
		ex = trimLeftSpace(ex)
		if r := []rune(ex); len(r) > 110 {
			ex = string(r[:110])
		}
		if i, ok := sc.seen[key]; !ok {
			sc.cands = append(sc.cands, bpCand{line: sc.firstline, ser: d.ser, num: d.num, conf: d.conf, ex: ex})
			sc.seen[key] = len(sc.cands) - 1
		} else if d.conf == "high" && sc.cands[i].conf != "high" {
			sc.cands[i].conf, sc.cands[i].line, sc.cands[i].ex = "high", sc.firstline, ex
		}
	}
}

// parseBlockName is `^(.*-)?(block|bloque)([0-9]+)(-[[:alnum:]_-]+)?\.md$` with POSIX submatch rules: the
// prefix group takes the longest span that lets the rest match.
func parseBlockName(base string) (prefix string, num int64, ok bool) {
	for i := len(base); i >= 0; i-- {
		if i != 0 && base[i-1] != '-' {
			continue
		}
		m := reBPBlockName.FindStringSubmatch(base[i:])
		if m == nil {
			continue
		}
		n, err := strconv.ParseInt(m[2], 10, 64)
		if err != nil {
			continue
		}
		return base[:i], n, true
	}
	return "", 0, false
}

// fileSeries is _vb_bp_fser: R when the first `#` line is `# Block R<n>`, else N; rc 2 when unreadable.
func (v *vb) fileSeries(path string) (series string, rc int) {
	body, err := os.ReadFile(v.abs(path))
	if err != nil {
		return "", 2
	}
	for _, l := range fileLines(string(body)) {
		if strings.HasPrefix(l, "#") {
			if reBPRHeading.MatchString(l) {
				return "R", 0
			}
			return "N", 0
		}
	}
	return "N", 0
}

type bpFile struct {
	path   string
	dir    int
	num    int64
	prefix string
}

func (v *vb) backPointers() {
	var w, info, amb, deg, okc, low int
	v.say("-- §14 back-pointer (kit #1962: a block that corrects an earlier block must be pointed back to from it; advisory, exit unchanged) --")
	base := basenameSh(v.block)
	pfx, self, named := parseBlockName(base)
	switch {
	case v.bpMode == "off":
		v.say("   (back-pointer check off — --backptr=off)")
		return
	case !named:
		v.say("   (back-pointer check skipped — '%s' is not a canonical block file name: <prefix>-(block|bloque)<N>[-slug].md)", base)
		return
	}
	var dirs []string
	for _, x := range []string{dirnameSh(v.block), v.target} {
		p, ok := v.physDir(x)
		if !ok {
			continue
		}
		if len(dirs) > 0 && dirs[0] == p {
			continue
		}
		dirs = append(dirs, p)
	}
	cands, st := bpPairs(v.ls, self)
	pairsOK := true
	if len(dirs) == 0 {
		v.say("   DEGRADED backptr: the sentence scan or the candidate directory failed (awk exit 0, 0 directories) — back-pointers NOT checked")
		deg++
		cands, st, pairsOK = nil, bpStats{}, false
	}
	var files []bpFile
	dbad := map[int]bool{}
	if pairsOK {
		for di, d := range dirs {
			names, ok := v.findFiles(d, 1, func(n string) bool { return strings.HasSuffix(n, ".md") })
			if !ok {
				dbad[di] = true
				continue
			}
			sort.Strings(names)
			for _, f := range names {
				if !reBPFileName.MatchString(f) {
					continue
				}
				p, n, ok := parseBlockName(basenameSh(f))
				if !ok {
					continue
				}
				files = append(files, bpFile{f, di, n, p})
			}
		}
	}
	slab := "B" + strconv.FormatInt(self, 10)
	ptr := fmt.Sprintf(`(^|[^A-Za-z0-9_])(([Bb]lock|[Bb]loque) ?|B)0*%d([^0-9A-Za-z_]|$)`, self)
	if st.rmode {
		slab = "R" + strconv.FormatInt(self, 10)
		ptr = fmt.Sprintf(`(^|[^A-Za-z0-9_])((([Bb]lock|[Bb]loque) ?)?R)0*%d([^0-9A-Za-z_]|$)`, self)
	}
	ptrRE := regexp.MustCompile(ptr)
	for _, c := range cands {
		cl := strconv.FormatInt(c.num, 10)
		if c.ser == "R" {
			cl = "R" + cl
		}
		var cand []string
		scanbad := false
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
					if pass == "same" && f.prefix != pfx {
						continue
					}
					fs, rc := v.fileSeries(f.path)
					if rc == 0 && fs != c.ser {
						continue
					}
					cand = append(cand, f.path)
				}
				if len(cand) > 0 {
					break
				}
			}
			if len(cand) > 0 {
				break
			}
		}
		state, msg := "", ""
		switch {
		case len(cand) == 0 && scanbad:
			state = "degraded"
			msg = fmt.Sprintf("   DEGRADED backptr: line %d: block %s — the candidate scan under %s failed; back-pointer NOT checked", c.line, cl, strings.Join(dirs, " "))
		case len(cand) == 0:
			state = "notfound"
			msg = fmt.Sprintf("   INFO    backptr: line %d cites block %s but its block file is not found under %s — back-pointer NOT checked", c.line, cl, strings.Join(dirs, " "))
		case len(cand) > 1:
			var names []string
			for _, f := range cand {
				names = append(names, f[strings.LastIndex(f, "/")+1:])
			}
			state = "ambig"
			msg = fmt.Sprintf("   BACKPTR-AMBIGUOUS  line %d: block %s matches %d files (%s) — back-pointer NOT checked; disambiguate by hand", c.line, cl, len(cand), strings.Join(names, ", "))
		default:
			old := cand[0]
			oldBase := old[strings.LastIndex(old, "/")+1:]
			body, err := os.ReadFile(v.abs(old))
			switch {
			case err != nil:
				state = "degraded"
				msg = fmt.Sprintf("   DEGRADED backptr: line %d: block %s (%s) is unreadable — back-pointer NOT checked", c.line, cl, oldBase)
			case anyLineRE(fileLines(string(body)), ptrRE):
				state = "ok"
				msg = fmt.Sprintf("   backptr-ok  line %d: block %s (%s) points back to %s", c.line, cl, oldBase, slab)
			default:
				state = "missing"
				msg = fmt.Sprintf("   BACKPTR?  line %d: possible correction of block %s (%s); verify by hand, then consider a back-pointer to %s in %s (§14; advisory, exit unchanged) — sentence: \"%s\"", c.line, cl, oldBase, slab, oldBase, c.ex)
			}
		}
		switch state {
		case "missing":
			w++
		case "ok":
			okc++
		case "ambig":
			amb++
		case "notfound":
			info++
		case "degraded":
			deg++
		}
		if v.bpMode == "all" || c.conf == "high" || (state != "missing" && state != "ok") {
			v.say("%s", msg)
		} else if state == "missing" {
			low++
		}
	}
	skipped := fmt.Sprintf("forward=%d neg=%d self=%d passive=%d noun=%d corrector=%d far=%d list=%d", st.fwd, st.neg, st.self, st.passive, st.noun, st.corr, st.far, st.list)
	if w+info+amb+deg+okc == 0 {
		v.say("   (none — no correction sentence cites an earlier block; correction sentences scanned: %d; skipped: %s)", st.nsent, skipped)
		return
	}
	v.say("-- back-pointer: %d possibly missing · %d present · %d ambiguous · %d not found · %d degraded (correction sentences: %d; skipped: %s) — advisory, exit unchanged", w, okc, amb, info, deg, st.nsent, skipped)
	if low > 0 {
		v.say("-- back-pointer: %d low-confidence candidate(s) (--backptr=all to list)", low)
	}
}

func anyLineRE(ls []string, re *regexp.Regexp) bool {
	for _, l := range ls {
		if re.MatchString(l) {
			return true
		}
	}
	return false
}
