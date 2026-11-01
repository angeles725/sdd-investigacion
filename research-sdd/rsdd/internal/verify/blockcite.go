package verify

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// Section 3 of verify-block.sh: the citation forms, their resolution against the target, the roots tried in
// order, the typed non-verdicts (nonpath, extern, DEGRADED) and the resolved-N-of-M summary.

const (
	artName = `(b[0-9]+|bloque[0-9]+)-[a-z0-9_.-]*[a-z][a-z0-9_.-]*`
	artTail = `:[0-9]+((-|‑|–)[0-9]+)?`
)

var (
	reSpans       = newVB("\\([^)]*\\)|`[^`]*`")
	reArtCite     = newVB(`(?i)` + artName + artTail)
	reArtNameFull = newVB(`(?i)^` + artName + `$`)
	reBtCite      = newVB("`[A-Za-z0-9_./-]+\\.[A-Za-z0-9]+:[0-9]+(-[0-9]+)?`")
	reNonPath     = newVB(`^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:|^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\.(com|io|net|org|dev|edu|gov|mx|local|lan|internal|cloud|app):|^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+\.[A-Z][A-Za-z0-9_]*:`)
	reVersioned   = newVB(`(^|\.)v[0-9]+(\.|$)`)
	reTableLine   = newVB(`^[` + spc + `]*\|`)
	reTableShort  = newVB(`[` + spc + `|,]:[0-9]+`)
	reCmtShort    = newVB(`(//|#)[` + spc + `]*:[0-9]+(,[` + spc + `]*:[0-9]+)*`)
	reColonNum    = newVB(`:[0-9]+`)
	reProbeCite   = newVB(`sources/probes/[A-Za-z0-9_./-]+`)
	reJarCite     = newVB(`[A-Za-z0-9_.-]+\.jar![A-Za-z0-9_./-]+`)
	reSynthRef    = newVB(`\[B[0-9]+\]`)
	reDashNorm    = strings.NewReplacer("‑", "-", "–", "-")
)

var (
	extsOnce sync.Once
	extsSet  map[string]bool
	tldsSet  map[string]bool
)

func initExts() {
	extsOnce.Do(func() {
		extsSet = map[string]bool{}
		for _, e := range vbFileExts {
			extsSet[e] = true
		}
		tldsSet = map[string]bool{}
		for _, e := range vbTLDs {
			tldsSet[e] = true
		}
	})
}

// citeCounters are the P9 counters of one run.
type citeCounters struct {
	ok, m, e, f, d, xa, xr, xrel, np int
}

// vbLines is _vb_lines: the line count of path (capped at end when end is a usable number); false when the
// counter fails.
func (v *vb) vbLines(path, end string) (int64, bool) {
	f, err := os.Open(v.abs(path))
	if err != nil {
		// the awk the script ran says why on its own stderr
		fmt.Fprintf(v.errw, "awk: fatal: cannot open file `%s' for reading: %s\n", path, strerror(err))
		return 0, false
	}
	defer f.Close()
	var e int64
	if n, ok := shellInt(end); ok {
		e = n
	}
	n, err := vbCountLines(f, e)
	if err != nil {
		return 0, false
	}
	return n, true
}

// strerror is the C library's text of an open failure ("Permission denied").
func strerror(err error) string {
	var pe *os.PathError
	if errors.As(err, &pe) {
		err = pe.Err
	}
	s := err.Error()
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

func (v *vb) readable(path string) bool {
	f, err := os.Open(v.abs(path))
	if err != nil {
		return false
	}
	f.Close()
	return true
}

// splitRange is the start/end of a `NNN` or `NNN-MMM` tail.
func splitRange(rng string) (start, end string) {
	if i := strings.LastIndex(rng, "-"); i >= 0 {
		return rng[:i], rng[i+1:]
	}
	return rng, rng
}

// lastColon splits `file:tail` at the last colon.
func lastColon(c string) (string, string) {
	i := strings.LastIndex(c, ":")
	return c[:i], c[i+1:]
}

func (v *vb) spanCites() []string {
	var cites []string
	for _, l := range v.ls {
		for _, span := range reSpans.FindAllString(l) {
			cites = append(cites, findAllFiltered(reArtCite, span, wordBoundaryBefore)...)
		}
	}
	return sortedUnique(cites)
}

func (v *vb) backtickCites() []string {
	var cites []string
	for _, l := range v.ls {
		for _, c := range reBtCite.FindAllString(l) {
			cites = append(cites, strings.ReplaceAll(c, "`", ""))
		}
	}
	return sortedUnique(cites)
}

func (v *vb) shortCites() []string {
	var shorts []string
	for _, l := range v.ls {
		if reTableLine.MatchString(l) {
			for _, m := range reTableShort.FindAllString(l) {
				shorts = append(shorts, m[strings.Index(m, ":"):])
			}
		}
		for _, m := range reCmtShort.FindAllString(l) {
			shorts = append(shorts, reColonNum.FindAllString(m)...)
		}
	}
	return sortedUnique(shorts)
}

func (v *vb) findAllLines(re *vbRE) []string {
	var out []string
	for _, l := range v.ls {
		out = append(out, re.FindAllString(l)...)
	}
	return sortedUnique(out)
}

// sourceRoot is $SOURCE_ROOT ("" when unset or empty).
func (v *vb) sourceRoot() string { return v.s.Env("SOURCE_ROOT") }

// splitNonPath is P973: it returns the cites to list as nonpath and the cites that stay file citations.
// A shape match is only a candidate; a token whose file exists under any root, or whose last label reads as a
// file extension (with the TLD and R-package guards), is a real cite.
func (v *vb) splitNonPath(bt []string) (nonpath, keep []string) {
	initExts()
	if len(bt) == 0 {
		return nil, bt
	}
	var cand []string
	for _, c := range bt {
		if reNonPath.MatchString(c) {
			cand = append(cand, c)
		}
	}
	if len(cand) == 0 {
		return nil, bt
	}
	roots := []string{v.target, v.gitRoot, v.targetRoot, v.sourceRoot()}
	for _, c := range cand {
		stem, _ := lastColon(c)
		hit := false
		for _, r := range roots {
			if r != "" && v.isFile(r+"/"+stem) {
				hit = true
				break
			}
		}
		last := stem[strings.LastIndex(stem, ".")+1:]
		labels := stem
		if i := strings.LastIndex(stem, "."); i >= 0 {
			labels = stem[:i]
		}
		first := stem
		if i := strings.Index(stem, "."); i >= 0 {
			first = stem[:i]
		}
		if !hit {
			if extsSet[last] {
				hit = true
				if tldsSet[last] && !reVersioned.MatchString(labels) {
					hit = false
				}
			} else if last == "R" {
				pkg := false
				switch first {
				case "com", "org", "net", "io", "java", "javax", "jakarta", "android", "androidx", "edu", "gov", "kotlin", "scala", "sun", "jdk":
					pkg = true
				default:
					pkg = len(first) == 2 && first[0] >= 'a' && first[0] <= 'z' && first[1] >= 'a' && first[1] <= 'z'
				}
				if reVersioned.MatchString(labels) {
					pkg = false
				}
				if !pkg {
					hit = true
				}
			}
		}
		if !hit {
			nonpath = append(nonpath, c)
		}
	}
	if len(nonpath) == 0 {
		return nil, bt
	}
	drop := map[string]bool{}
	for _, c := range nonpath {
		drop[c] = true
	}
	for _, c := range bt {
		if !drop[c] {
			keep = append(keep, c)
		}
	}
	return nonpath, keep
}

func (v *vb) citations() {
	v.say("-- [CERT] file:line citation resolution --")
	art := v.spanCites()
	bt := v.backtickCites()
	nonpath, bt := v.splitNonPath(bt)
	short := v.shortCites()

	// (d) probe-file cites
	probes := v.findAllLines(reProbeCite)
	probeFound, pfOK := false, 0
	if len(probes) > 0 {
		for _, p := range probes {
			if v.isFile(v.target + "/" + p) {
				pfOK++
				v.say("   probe   %s", p)
				probeFound = true
			} else {
				v.say("   extern  %s  (probe path not in target — not script-verifiable)", p)
			}
		}
		v.say("   probe-file cites resolved %d of %d", pfOK, len(probes))
	}
	// (e) jar entries, (f) [BNNN] back-references
	jars := v.findAllLines(reJarCite)
	for _, jc := range jars {
		v.say("   jar-entry  %s  (jar archive path — not file-verifiable)", jc)
	}
	synth := v.findAllLines(reSynthRef)
	for _, sr := range synth {
		v.say("   synth-ref  %s  (block back-reference — not file-verifiable)", sr)
	}
	jarFound, synthFound := len(jars) > 0, len(synth) > 0

	if len(art) == 0 && len(bt) == 0 && len(short) == 0 && !probeFound {
		v.noCitationNote(jarFound, synthFound)
	}
	if probeFound && len(art) == 0 && len(bt) == 0 && len(short) == 0 && v.codeCert > pfOK {
		v.say("   INFO    %d [CERT] code marker(s) but only %d resolved probe-file cite(s) — a probe cite verifies its file, not each marker; token-verify the rest inline.", v.codeCert, pfOK)
	}
	var cc citeCounters
	for _, c := range nonpath {
		v.say("   nonpath  %s  (not a file path: ip:port / host:port / qualified class — excluded from M)", c)
		cc.np++
	}
	v.artifactCites(art, &cc)
	v.backtickResolve(bt, &cc)
	for _, c := range short {
		v.say("   short   %s  (short form — file implied by context; not script-verifiable)", c)
	}
	if v.extern {
		v.say("   extern-check: verified %d of %d absolute backticked name.ext:N cite(s); %d relative cite(s) cannot be resolved", cc.xr, cc.xa, cc.xrel)
	}
	v.resolvedSummary(&cc)
}

// noCitationNote is the P6 block: no citation of any resolvable kind was found.
func (v *vb) noCitationNote(jarFound, synthFound bool) {
	if jarFound || synthFound {
		if v.certTotal > 0 {
			what := ""
			if jarFound {
				what += "archive-entry paths "
			}
			if synthFound {
				what += "[BNNN] back-references "
			}
			v.say("   (only non-file-verifiable citations recognized: %s— see entries above; token-verify inline against cited artifacts)", what)
		}
		return
	}
	if v.certTotal == 0 {
		v.say("   (no file:line citations found)")
		return
	}
	if v.codeCert == 0 {
		v.say("   (doc-grade citations only ([CERT-doc]/[CERT-web]/[CERT-a]) — file:line not expected; validate tokens via verify-sources.sh + §5 token-check)")
		return
	}
	const zero = "but ZERO file:line citations resolved — the citation gate checked nothing and exits 0 silently. Expected for synthesis / REMITTANCE / [CERT-live]-only or [CERT-doc]-only blocks (check your block-type declaration); otherwise add file:line citations or re-check the citation format."
	switch v.typ.class {
	case "nocite":
		v.say("   INFO    [CERT] markers present (%d) but ZERO file:line citations resolved — expected for declared type %s.", v.certTotal, v.typ.token)
	case "cite":
		v.say("   WARN    [CERT] markers present (%d) %s", v.certTotal, zero)
	default:
		if v.typ.raw != "" {
			v.say("   WARN    [CERT] markers present (%d) but ZERO file:line citations resolved — unrecognised Type: token '%s'; accepted: %s.", v.certTotal, v.typ.warnName, typesPipe)
		} else {
			v.say("   WARN    [CERT] markers present (%d) %s", v.certTotal, zero)
			v.say("   HINT    Declare a Type: token in the header blockquote to grade this WARN: %s.", typesPipe)
		}
	}
}

// artifactCites is pass (a): B<N>-* / bloque<N>-* artifacts a [CERT] seals to by name; unpreserved or out of
// range both FAIL.
func (v *vb) artifactCites(art []string, cc *citeCounters) {
	for _, c := range art {
		cc.m++
		n := reDashNorm.Replace(c)
		f, rng := lastColon(n)
		start, end := splitRange(rng)
		if !v.isFile(v.target + "/" + f) {
			if full := v.fullPathOf(f); full != "" && v.isFile(v.target+"/"+full) {
				f = full
			}
		}
		if !v.isFile(v.target + "/" + f) {
			v.say("   MISSING! %s  (evidence artifact not preserved)", c)
			v.rc = 1
			cc.f++
			continue
		}
		total, ok := v.vbLines(v.target+"/"+f, "")
		if !ok {
			v.say("   linecount DEGRADED  %s (line count failed)", c)
			v.rc = 1
			cc.d++
			continue
		}
		ts := strconv.FormatInt(total, 10)
		if numLE(start, ts) && numLE(end, ts) && numLE(start, end) {
			v.say("   ok      %s", c)
			cc.ok++
		} else {
			v.say("   RANGE!  %s  (file has %d lines) — cited line out of range", c, total)
			v.rc = 1
			cc.f++
		}
	}
}

// fullPathOf is D6: the first `<path>/<f>` spelling in the block (case-insensitive), "" when there is none.
func (v *vb) fullPathOf(f string) string {
	re := regexp.MustCompile(`(?i)[a-zA-Z0-9_./-]+/` + strings.ReplaceAll(f, ".", `\.`))
	re.Longest()
	for _, l := range v.ls {
		if loc := re.FindStringIndex(l); loc != nil {
			return l[loc[0]:loc[1]]
		}
	}
	return ""
}

// backtickResolve is pass (b): generic backticked `file.ext:N[-M]` cites, roots tried in order.
func (v *vb) backtickResolve(bt []string, cc *citeCounters) {
	initExts()
	for _, c := range bt {
		f, rng := lastColon(c)
		start, end := splitRange(rng)
		if reArtNameFull.MatchString(f) {
			continue
		}
		cc.m++
		if numEQ(start, "0") {
			v.say("   RANGE!  %s  (start 0 is invalid — lines are 1-indexed)", c)
			v.rc = 1
			cc.f++
			continue
		}
		if numGT(start, end) {
			v.say("   RANGE!  %s  (reversed range: start %s > end %s — defect in block)", c, start, end)
			v.rc = 1
			cc.f++
			continue
		}
		type root struct{ dir, label string }
		roots := []root{{v.target, ""}}
		if v.gitRoot != "" && v.gitRoot != v.target {
			roots = append(roots, root{v.gitRoot, ""})
		}
		if v.targetRoot != "" {
			roots = append(roots, root{v.targetRoot, "(target-root) "})
		}
		if sr := v.sourceRoot(); sr != "" {
			roots = append(roots, root{sr, ""})
		}
		resolve, first, tag, firstTag := "", "", "", ""
		cdeg := false
		for _, r := range roots {
			p := r.dir + "/" + f
			if !v.isFile(p) {
				continue
			}
			if first == "" {
				first, firstTag = p, r.label
			}
			if fit, ok := v.vbLines(p, end); ok {
				if numLE(end, strconv.FormatInt(fit, 10)) {
					resolve, tag = p, r.label
					break
				}
			} else {
				cdeg = true
			}
		}
		if resolve == "" && cdeg {
			v.say("   linecount DEGRADED  %s (line count failed)", c)
			v.rc = 1
			cc.d++
			continue
		}
		if resolve == "" && first != "" {
			resolve, tag = first, firstTag
		}
		okp := "ok      "
		if tag != "" {
			okp = "ok " + tag
		}
		if resolve != "" && v.isFile(resolve) {
			total, ok := v.vbLines(resolve, "")
			if !ok {
				v.say("   linecount DEGRADED  %s (line count failed)", c)
				v.rc = 1
				cc.d++
				continue
			}
			if numLE(end, strconv.FormatInt(total, 10)) {
				if start == end {
					v.say("   %s%s", okp, c)
				} else {
					v.say("   %s%s  (range end verified; file has %d lines)", okp, c, total)
				}
				cc.ok++
			} else {
				v.say("   RANGE!  %s  (file has %d lines) — cited line out of range", c, total)
				v.rc = 1
				cc.f++
			}
			continue
		}
		if v.externCheck(c, f, start, end, cc) {
			continue
		}
		ext := f[strings.LastIndex(f, ".")+1:]
		extLow := strings.ToLower(ext)
		method := false
		if !strings.Contains(f, "/") && ext != "" && ext[0] >= 'a' && ext[0] <= 'z' {
			name := f[:strings.LastIndex(f, ".")]
			method = strings.ContainsAny(name, "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
		}
		if method && !extsSet[extLow] {
			v.say("   nonpath  %s  (not a file path: unknown extension '%s', no such file — likely Class.method:NNN; excluded from M)", c, extLow)
			cc.m--
			cc.np++
			continue
		}
		if v.extern {
			cc.xrel++
		}
		v.say("   extern  %s  (not in target: beautified-temp / decompiled / snapshot — not script-verifiable)", c)
		cc.e++
	}
}

// externCheck is --extern-check (kit #1906): the END line of an absolute extern cite is checked against the
// file's line count, never printing the file. It reports whether it handled the cite.
func (v *vb) externCheck(c, f, start, end string, cc *citeCounters) bool {
	if !v.extern || !strings.HasPrefix(f, "/") {
		return false
	}
	cc.xa++
	if !v.isFile(f) || !v.readable(f) {
		v.say("   extern  %s  (absolute path not found or unreadable — not script-verifiable)", c)
		cc.e++
		return true
	}
	total, ok := v.vbLines(f, end)
	if !ok {
		v.say("   extern-check DEGRADED  %s (line count failed)", c)
		v.rc = 1
		cc.d++
		return true
	}
	cc.xr++
	if numGT(end, strconv.FormatInt(total, 10)) {
		v.say("   RANGE!  %s  (file has %d lines) — cited line out of range", c, total)
		v.rc = 1
		cc.f++
		return true
	}
	if start == end {
		v.say("   ok extern %s", c)
	} else {
		v.say("   ok extern %s  (range end verified)", c)
	}
	cc.ok++
	return true
}

// resolvedSummary is P9: `resolved N of M` and the WARN graded by the declared Type when N is 0.
func (v *vb) resolvedSummary(cc *citeCounters) {
	if cc.m <= 0 {
		if cc.np > 0 {
			v.say("   INFO    0 file citations counted — %d non-path token(s) excluded from M (listed above as nonpath).", cc.np)
		}
		return
	}
	deg := ""
	if cc.d > 0 {
		deg = ", " + strconv.Itoa(cc.d) + " degraded"
	}
	v.say("   resolved %d of %d (%d extern, %d failed%s)", cc.ok, cc.m, cc.e, cc.f, deg)
	why := "no file paths resolved."
	switch {
	case cc.d > 0:
		why = "line count failed — instrument, not the cite (see the DEGRADED lines above); those cites were not judged."
	case cc.e > 0:
		why = "no file paths resolved. Set SOURCE_ROOT if source files live in a separate tree."
	case cc.f > 0:
		why = "every cite failed (RANGE!/MISSING!, listed above) — fix those cites; SOURCE_ROOT would not help."
	}
	if cc.ok != 0 {
		return
	}
	if v.certTotal > 0 && v.codeCert == 0 {
		v.say("   INFO    resolved 0 of %d — doc-grade markers only; file:line citations not expected.", cc.m)
		return
	}
	switch v.typ.class {
	case "nocite":
		v.say("   INFO    resolved 0 of %d — expected for declared type %s.", cc.m, v.typ.token)
	case "cite":
		v.say("   WARN    resolved 0 of %d — %s", cc.m, why)
	default:
		if v.typ.raw != "" {
			v.say("   WARN    resolved 0 of %d — unrecognised Type: '%s'; %s", cc.m, v.typ.warnName, why)
		} else {
			v.say("   WARN    resolved 0 of %d — %s", cc.m, why)
			v.say("   HINT    Declare a Type: token to grade this WARN: %s.", typesPipe)
		}
	}
}
