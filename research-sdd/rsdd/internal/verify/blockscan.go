package verify

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Sections 3b to 10 of verify-block.sh: the possibility-first lint (and its --possibility-sweep), the OCR
// provenance flag, the empty-input digest detector and the ephemeral-path detector. The awk programs of the
// script are reproduced line by line; gawk positions are characters, so substrings are cut on characters.

// ---- possibility-first (pf_scan) ----

var (
	rePFHeading  = newVB(`^#+[` + spc + `]`)
	rePFList     = newVB(`^[` + spc + `]*([-*+]|[0-9]+[.)]|\|)`)
	rePFMeasured = newVB(`not with .*measured`)
	rePFMeasure  = newVB(`physically impossible|impossible (value|reading|record|timestamp|state|combination|result)s?`)
	rePFVerdict  = newVB(`not possible|no es posible|impossible|imposible|no way to|out of reach|not determinable|no se puede|cannot be (determined|done|achieved|measured|known|verified|reached|obtained|read|extracted|recovered|resolved|derived|reproduced|built|decided|established|confirmed)`)
	reOCRTag     = newVB(`(?i)reliability:[` + spc + `]*ocr-lossy|extracted via ocr`)
	reHexRun     = newVB(`[0-9a-f]+`)
	reEPTmp      = newVB(`(\$\{?TMPDIR\}?|/private/var/tmp|/private/tmp|/var/tmp|/tmp)/[A-Za-z0-9_./@+=:~-]*`)
	reEPScratch  = newVB(`[A-Za-z0-9_./@+=:~-]*scratchpad/[A-Za-z0-9_./@+=:~-]*`)
	reEPOwned    = newVB(`^(\$\{?TMPDIR\}?|/private/var/tmp|/private/tmp|/var/tmp|/tmp)/`)
	reTrailPunct = newVB(`[.,:;]+$`)
)

type pfHit struct {
	line         int
	phrase, text string
}

// pfScan is pf_scan: the bare feasibility verdicts of a block, a verdict being bare unless its section carries
// a route ladder (>= 3 route items and a `cheapest` step). Fenced code is skipped.
func pfScan(ls []string) []pfHit {
	var out, pending []pfHit
	routes, cheapest := 0, false
	flush := func() {
		if len(pending) > 0 && !(routes >= 3 && cheapest) {
			out = append(out, pending...)
		}
		pending, routes, cheapest = nil, 0, false
	}
	fence := false
	for i, raw := range ls {
		if strings.HasPrefix(raw, "```") {
			fence = !fence
			continue
		}
		if fence {
			continue
		}
		if rePFHeading.MatchString(raw) {
			flush()
			continue
		}
		l := strings.ToLower(raw)
		if rePFList.MatchString(l) && strings.Contains(l, "route") {
			routes++
		}
		if strings.Contains(l, "cheapest") {
			cheapest = true
		}
		if rePFMeasured.MatchString(l) {
			continue
		}
		l = rePFMeasure.get().ReplaceAllString(l, "")
		if loc := rePFVerdict.FindStringIndex(l); loc != nil {
			pending = append(pending, pfHit{i + 1, l[loc[0]:loc[1]], raw})
		}
	}
	flush()
	return out
}

func (v *vb) possibilityFirst() {
	v.say("-- possibility-first (§1: no bare feasibility verdict) --")
	n := 0
	for _, h := range pfScan(v.ls) {
		v.say("   WARN    possibility-first line %d: bare verdict '%s' — rewrite as a route ladder (>=3 routes of different classes, cost + needs each, ending with the cheapest next step; unexecuted routes are [INFER]/proposed).", h.line, h.phrase)
		n++
	}
	if n == 0 {
		v.say("   (none — no bare feasibility verdict)")
	}
}

const sweepUsage = "usage: verify-block.sh --possibility-sweep <corpus-dir>"

// findFiles is `find <start> -type f -name <glob-suffix>`: regular files (symlinks are not followed, and a
// symlink start is not entered unless it ends in a slash), named with find's spelling of the path.
// maxDepth 1 is -maxdepth 1 (the start directory only); 0 is unlimited.
func (v *vb) findFiles(start string, maxDepth int, match func(name string) bool) (files []string, ok bool) {
	st, err := os.Lstat(v.abs(start))
	if err != nil {
		return nil, false
	}
	if st.Mode()&os.ModeSymlink != 0 && !strings.HasSuffix(start, "/") {
		return nil, true
	}
	ok = true
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		ents, err := os.ReadDir(v.abs(dir))
		if err != nil {
			ok = false
			return
		}
		prefix := dir
		if !strings.HasSuffix(dir, "/") {
			prefix += "/"
		}
		for _, e := range ents {
			p := prefix + e.Name()
			switch {
			case e.IsDir():
				if maxDepth == 0 || depth < maxDepth {
					walk(p, depth+1)
				}
			case e.Type().IsRegular() && match(e.Name()):
				files = append(files, p)
			}
		}
	}
	walk(start, 1)
	return files, ok
}

func (v *vb) possibilitySweep(dir string) int {
	if !v.isDir(dir) {
		fmt.Fprintln(v.errw, sweepUsage)
		return 2
	}
	files, _ := v.findFiles(dir, 0, func(n string) bool { return strings.HasSuffix(n, ".md") })
	sort.Strings(files)
	total := 0
	for _, f := range files {
		raw, err := os.ReadFile(v.abs(f))
		if err != nil {
			continue
		}
		for _, h := range pfScan(fileLines(string(raw))) {
			// `read -r ln ph tx` with IFS=tab: tabs around the last field are stripped
			tx := strings.Trim(h.text, "\t")
			v.say("%s:%d: %s — %s", f, h.line, h.phrase, cutBytes(tx, 120))
			total++
		}
	}
	v.say("== possibility-sweep: bare verdicts: %d ==", total)
	if total > 0 {
		v.say("   Reopen each as a child gap (B<n>-G<m>) with the cheapest route as NEXT, §14 back-pointer on the corrected block (METHODOLOGY §1 possibility-first self-correction). Read-only: nothing was edited.")
	}
	fmt.Fprint(v.s.Out, v.out.String())
	return 0
}

// ---- OCR provenance ----

func (v *vb) ocr() {
	v.say("-- OCR-provenance flag (reliability: ocr-lossy) --")
	extDir := v.target + "/sources/extracted"
	lossy := 0
	if v.isDir(extDir) {
		// find does not enter a symlinked start directory
		var names []string
		if st, lerr := os.Lstat(v.abs(extDir)); lerr == nil && st.Mode()&os.ModeSymlink == 0 {
			if d, err := os.Open(v.abs(extDir)); err == nil {
				names, _ = d.Readdirnames(-1) // directory order, as find prints it
				d.Close()
			}
		}
		for _, name := range names {
			if !strings.HasSuffix(name, ".md") {
				continue
			}
			ext := extDir + "/" + name
			if !v.isFile(ext) {
				continue
			}
			body, err := os.ReadFile(v.abs(ext))
			if err != nil || !anyLine(fileLines(string(body)), reOCRTag) {
				continue
			}
			if v.ocrOne(ext, name, fileLines(string(body))) {
				lossy++
			}
		}
	}
	if lossy == 0 {
		v.say("   (none — no citation traces to an OCR-lossy extract)")
	}
}

func anyLine(ls []string, re *vbRE) bool {
	for _, l := range ls {
		if re.MatchString(l) {
			return true
		}
	}
	return false
}

// ocrOne checks one OCR-lossy extract against the block; it reports whether a hit was printed.
func (v *vb) ocrOne(ext, name string, body []string) bool {
	stem := strings.TrimSuffix(name, ".md")
	if name == ".md" {
		stem = name
	}
	parts := strings.SplitN(stem, "-", 3)
	if len(parts) > 2 {
		parts = parts[:2]
	}
	loose := strings.Join(parts, "-")
	src := ""
	for _, l := range body {
		if strings.Contains(l, "source_pdf:") {
			if f := strings.Split(l, ": "); len(f) > 1 {
				src = f[1]
			}
			break
		}
	}
	pdfBase := ""
	if src != "" {
		pdfBase = basenameSh(src)
		if i := strings.LastIndex(pdfBase, "."); i >= 0 {
			pdfBase = pdfBase[:i]
		}
	}
	hits := map[int]string{}
	grepErr := 0
	for _, tok := range []string{pdfBase, stem, loose} {
		if tok == "" {
			continue
		}
		if strings.HasPrefix(tok, "-") { // grep would read the token as an option
			grepErr = 2
			continue
		}
		for i, l := range v.ls {
			if strings.Contains(l, tok) {
				hits[i+1] = strconv.Itoa(i+1) + ":" + l
			}
		}
	}
	if grepErr >= 2 {
		v.say("   WARN: citation resolution FAILED (grep exit %d) — unresolved (grep exit R)", grepErr)
		return false
	}
	if len(hits) == 0 {
		return false
	}
	nums := make([]int, 0, len(hits))
	for n := range hits {
		nums = append(nums, n)
	}
	sort.Ints(nums)
	v.say("   OCR!    lines citing OCR-lossy '%s' — re-verify numbers/quotes/serials vs page image:", stem)
	for _, n := range nums {
		v.say("           %s", hits[n])
	}
	return true
}

// ---- empty-input digests (#1487) ----

var emptyDigests = []struct{ name, digest string }{
	{"sha256", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
	{"sha1", "da39a3ee5e6b4b0d3255bfef95601890afd80709"},
	{"md5", "d41d8cd98f00b204e9800998ecf8427e"},
}

func isIdentASCII(r rune) bool {
	return r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_'
}

func (v *vb) emptyDigests() {
	n, waived := 0, 0
	for i, line := range v.ls {
		nr := i + 1
		rest := strings.ToLower(line)
		for {
			loc := reHexRun.FindStringIndex(rest)
			if loc == nil {
				break
			}
			tok := rest[loc[0]:loc[1]]
			var before rune = -1
			if loc[0] > 0 {
				before, _ = utf8.DecodeLastRuneInString(rest[:loc[0]])
			}
			after := rest[loc[1]:]
			elided := strings.HasPrefix(after, "…") || strings.HasPrefix(after, "...")
			if before < 0 || !isIdentASCII(before) {
				for _, d := range emptyDigests {
					if tok == d.digest || (elided && len(tok) >= 8 && len(tok) < len(d.digest) && strings.HasPrefix(d.digest, tok)) {
						if strings.Contains(line, "<!-- empty-digest: quoted -->") {
							v.say("   INFO    empty-digest waived on line %d (%s digest quoted on purpose, marker present)", nr, d.name)
							waived++
						} else {
							dots := ""
							if len(tok) > 16 {
								dots = "…"
							}
							v.say("   EMPTYHASH! line %d: %s digest of EMPTY input (%s%s) — proves nothing (file missing/empty when hashed); re-hash the real file", nr, d.name, tok[:min(16, len(tok))], dots)
							n++
							v.rc = 1
						}
					}
				}
			}
			rest = after
		}
	}
	if n == 0 {
		v.say("   (none — no unwaived cited hash equals the digest of empty input; waived: %d)", waived)
	} else {
		v.say("-- empty-input digests cited: %d (FAIL)", n)
	}
}

// ---- ephemeral-path cites (kit #1207/#1660) ----

// hasDigest is a real sha256 anchor: the word sha256 and a maximal 64-hex run on the line.
func hasDigest(line string) bool {
	l := strings.ToLower(line)
	if !strings.Contains(l, "sha256") {
		return false
	}
	for {
		loc := reHexRun.FindStringIndex(l)
		if loc == nil {
			return false
		}
		if loc[1]-loc[0] == 64 {
			return true
		}
		l = l[loc[1]:]
	}
}

func isTmpGlue(r rune) bool {
	return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || strings.ContainsRune("_./~$-", r)
}

func isScratchGlue(r rune) bool {
	return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || strings.ContainsRune("$}_@+=:~-", r)
}

type epCounts struct{ n, anchored, ok, invalid int }

func (v *vb) ephemeral() {
	var c epCounts
	flagged := map[int]bool{}
	for i, line := range v.ls {
		nr := i + 1
		v.ephemeralScan(line, nr, reEPTmp, isTmpGlue, false, flagged, &c)
		v.ephemeralScan(line, nr, reEPScratch, isScratchGlue, true, flagged, &c)
	}
	v.say("-- ephemeral-path cites (kit #1207/#1660: /tmp, /var/tmp, scratchpad — FAIL by default, WARN under --ephemeral=warn or RSDD_STRICT_EPHEMERAL=0; exempt: sha256 anchor, <!-- ephemeral-ok: <reason> --> marker) --")
	for _, l := range v.epLines {
		v.say("%s", l)
	}
	v.epLines = nil
	switch {
	case c.n == 0:
		v.say("   (none — no unanchored ephemeral path cited; sha256-anchored: %d, ephemeral-ok: %d, invalid markers: %d)", c.anchored, c.ok, c.invalid)
	case v.strict:
		v.say("-- ephemeral-path cites: %d (FAIL — preserve under sources/probes/b<N>/, waive a non-evidence line with <!-- ephemeral-ok: <reason> -->, or opt out with --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 while the corpus is cleaned, kit #1660)", c.n)
	default:
		v.say("-- ephemeral-path cites: %d (WARN — exit unchanged; opt-out --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 in force, the default is FAIL, kit #1660)", c.n)
	}
}

func skipScratchpad(tok string) bool {
	i := strings.Index(tok, "scratchpad/")
	if !(i == 0 || tok[i-1] == '/') {
		return true
	}
	return reEPOwned.MatchString(tok)
}

func (v *vb) ephemeralScan(line string, nr int, re *vbRE, glue func(rune) bool, spad bool, flagged map[int]bool, c *epCounts) {
	rest := line
	anchored := hasDigest(line)
	ok := false
	reason := ""
	mk := strings.Index(line, "<!-- ephemeral-ok:")
	if mk >= 0 {
		reason = line[mk+18:]
		if j := strings.Index(reason, "-->"); j >= 0 {
			reason = reason[:j]
		}
		reason = trimSpace(reason)
		if reason != "" {
			ok = true
		}
	}
	for {
		loc := re.FindStringIndex(rest)
		if loc == nil {
			return
		}
		tok := rest[loc[0]:loc[1]]
		after := rest[loc[1]:]
		glued := false
		if loc[0] > 0 {
			r, _ := utf8.DecodeLastRuneInString(rest[:loc[0]])
			glued = glue(r)
		}
		if !glued && !(spad && skipScratchpad(tok)) {
			tok = reTrailPunct.get().ReplaceAllString(tok, "")
			switch {
			case anchored:
				v.epLines = append(v.epLines, fmt.Sprintf("   INFO    ephemeral-anchored line %d: %s (sha256-anchored beautified-temp view, METHODOLOGY §5)", nr, tok))
				c.anchored++
			case ok:
				v.epLines = append(v.epLines, fmt.Sprintf("   INFO    ephemeral-ok line %d: %s (waived on purpose: %s)", nr, tok, reason))
				c.ok++
			default:
				if mk >= 0 && !flagged[nr] {
					flagged[nr] = true
					v.epLines = append(v.epLines, fmt.Sprintf("   WARN    invalid marker line %d: `<!-- ephemeral-ok: <reason> -->` needs a non-empty reason — marker ignored", nr))
					c.invalid++
				}
				if v.strict {
					v.epLines = append(v.epLines, fmt.Sprintf("   EPHEMERAL!  %s  (line %d; session/temp path — preserve under sources/probes/b<N>/)", tok, nr))
					v.rc = 1
				} else {
					v.epLines = append(v.epLines, fmt.Sprintf("   EPHEMERAL?  %s  (line %d; session/temp path — preserve under sources/probes/b<N>/; opt-out --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 is active, the default is FAIL)", tok, nr))
				}
				c.n++
			}
		}
		rest = after
	}
}
