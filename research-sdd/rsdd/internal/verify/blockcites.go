package verify

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Section 3 of verify-block: `file:line` citation resolution. Two passes with different teeth: block-evidence
// ARTIFACT cites (`B<N>-*` / `bloque<N>-*`, strict: MISSING! and RANGE! fail) and GENERIC backticked cites
// (ok / RANGE! / extern / nonpath). Short-form `:NNN`, probe-file, jar-entry and `[BNNN]` forms are recognised and
// listed. The P6 (zero citations) and P9 (resolved N of M) lines are graded by the declared Type: (blocktally.go).

const (
	artName = `(b[0-9]+|bloque[0-9]+)-[a-z0-9_.-]*[a-z][a-z0-9_.-]*`
	artTail = `:[0-9]+((-|‑|–)[0-9]+)?`
)

var (
	vbArtSpans  = vbRe("\\([^)]*\\)|`[^`]*`")
	vbArtCite   = vbRe(`(?i)` + artName + artTail)
	vbArtShape  = vbRe(`(?i)^` + artName + `$`)
	vbBtCite    = vbRe("`[A-Za-z0-9_./-]+\\.[A-Za-z0-9]+:[0-9]+(-[0-9]+)?`")
	vbTblRow    = vbRe(`^[[:space:]]*\|`)
	vbTblShort  = vbRe(`[[:space:]|,]:[0-9]+`)
	vbShortNum  = vbRe(`:[0-9]+`)
	vbCmtShort  = vbRe(`(//|#)[[:space:]]*:[0-9]+(,[[:space:]]*:[0-9]+)*`)
	vbProbeCite = vbRe(`sources/probes/[A-Za-z0-9_./-]+`)
	vbJarCite   = vbRe(`[A-Za-z0-9_.-]+\.jar![A-Za-z0-9_./-]+`)
	vbSynthRef  = vbRe(`\[B[0-9]+\]`)
)

func isWordRune(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) }

// grepOWordStart is `grep -o` of a pattern that begins with `\b` and a word character: a match is kept only when it
// does not follow a word character.
func grepOWordStart(re *regexp.Regexp, s string) []string {
	var out []string
	for pos := 0; pos < len(s); {
		loc := re.FindStringIndex(s[pos:])
		if loc == nil {
			break
		}
		st, en := pos+loc[0], pos+loc[1]
		if st > 0 {
			if prev, _ := utf8.DecodeLastRuneInString(s[:st]); isWordRune(prev) {
				_, w := utf8.DecodeRuneInString(s[st:])
				pos = st + w
				continue
			}
		}
		out = append(out, s[st:en])
		pos = en
	}
	return out
}

func (b *blockRun) sectionCites() {
	b.echo("-- [CERT] file:line citation resolution --")
	var art []string
	for _, span := range grepOLines(vbArtSpans, b.lines) {
		art = append(art, grepOWordStart(vbArtCite, span)...)
	}
	art = sortU(art)

	var bt []string
	for _, c := range grepOLines(vbBtCite, b.lines) {
		bt = append(bt, strings.ReplaceAll(c, "`", ""))
	}
	bt = sortU(bt)
	nonpath, bt := b.splitNonpath(bt)

	var shorts []string
	for _, l := range b.lines {
		if vbTblRow.MatchString(l) {
			for _, m := range grepO(vbTblShort, l) {
				shorts = append(shorts, grepO(vbShortNum, m)...)
			}
		}
	}
	for _, m := range grepOLines(vbCmtShort, b.lines) {
		shorts = append(shorts, grepO(vbShortNum, m)...)
	}
	shorts = sortU(nonEmpty(shorts))

	probeFound := false
	if probes := sortU(grepOLines(vbProbeCite, b.lines)); len(probes) > 0 {
		m := 0
		for _, p := range probes {
			m++
			if b.fs.isFile(b.target + "/" + p) {
				b.probeOK++
				b.echo("   probe   %s", p)
				probeFound = true // P6-PROBE-FILE-CITE
			} else {
				b.echo("   extern  %s  (probe path not in target — not script-verifiable)", p)
			}
		}
		b.echo("   probe-file cites resolved %d of %d", b.probeOK, m)
	}
	jarFound, synthFound := false, false
	for _, jc := range sortU(grepOLines(vbJarCite, b.lines)) {
		b.echo("   jar-entry  %s  (jar archive path — not file-verifiable)", jc)
		jarFound = true
	}
	for _, sr := range sortU(grepOLines(vbSynthRef, b.lines)) {
		b.echo("   synth-ref  %s  (block back-reference — not file-verifiable)", sr)
		synthFound = true
	}

	noCites := len(art) == 0 && len(bt) == 0 && len(shorts) == 0 && !probeFound
	if noCites {
		b.p6NoCitations(jarFound, synthFound)
	}
	if probeFound && len(art) == 0 && len(bt) == 0 && len(shorts) == 0 && b.codeCertTotal > b.probeOK { // P6-PROBE-COVERAGE
		b.echo("   INFO    %d [CERT] code marker(s) but only %d resolved probe-file cite(s) — a probe cite verifies its file, not each marker; token-verify the rest inline.", b.codeCertTotal, b.probeOK)
	}

	for _, c := range nonpath {
		b.echo("   nonpath  %s  (not a file path: ip:port / host:port / qualified class — excluded from M)", c)
		b.npN++ // P973-NONPATH-LIST
	}
	for _, c := range art {
		b.resolveArtifact(c)
	}
	for _, c := range bt {
		b.resolveBacktick(c)
	}
	for _, c := range shorts {
		b.echo("   short   %s  (short form — file implied by context; not script-verifiable)", c)
	}
	if b.externCheck {
		b.echo("   extern-check: verified %d of %d absolute backticked name.ext:N cite(s); %d relative cite(s) cannot be resolved", b.xr, b.xa, b.xrel)
	}
	b.p9Summary()
}

// p6NoCitations is the P6 verdict: no citation form at all was found.
func (b *blockRun) p6NoCitations(jarFound, synthFound bool) {
	if jarFound || synthFound { // P6-NONRESOLVABLE-GUARD
		if b.certTotal > 0 {
			what := ""
			if jarFound {
				what += "archive-entry paths "
			}
			if synthFound {
				what += "[BNNN] back-references "
			}
			b.echo("   (only non-file-verifiable citations recognized: %s— see entries above; token-verify inline against cited artifacts)", what)
		}
		return
	}
	if b.certTotal == 0 {
		b.echo("   (no file:line citations found)")
		return
	}
	if b.codeCertTotal == 0 { // P6-DOC-AWARE-SUPPRESS
		b.echo("   (doc-grade citations only ([CERT-doc]/[CERT-web]/[CERT-a]) — file:line not expected; validate tokens via verify-sources.sh + §5 token-check)")
		return
	}
	const zero = "but ZERO file:line citations resolved — the citation gate checked nothing and exits 0 silently. Expected for synthesis / REMITTANCE / [CERT-live]-only or [CERT-doc]-only blocks (check your block-type declaration); otherwise add file:line citations or re-check the citation format."
	switch b.typeClass {
	case "nocite":
		b.echo("   INFO    [CERT] markers present (%d) but ZERO file:line citations resolved — expected for declared type %s.", b.certTotal, b.typeToken)
	case "cite":
		b.echo("   WARN    [CERT] markers present (%d) %s", b.certTotal, zero)
	default:
		if b.typeRaw != "" { // P6-TYPE-UNRECOGNISED
			b.echo("   WARN    [CERT] markers present (%d) but ZERO file:line citations resolved — unrecognised Type: token '%s'; accepted: %s.", b.certTotal, b.typeWarnName, vbTypesPipe)
		} else {
			b.echo("   WARN    [CERT] markers present (%d) %s", b.certTotal, zero)
			b.echo("   HINT    Declare a Type: token in the header blockquote to grade this WARN: %s.", vbTypesPipe)
		}
	}
}

// splitRange is the `case "$rng" in *-*)` split: start and end around the last dash, else both are the number.
func splitRange(rng string) (start, end string) {
	if i := strings.LastIndex(rng, "-"); i >= 0 {
		return rng[:i], rng[i+1:]
	}
	return rng, rng
}

func (b *blockRun) degraded(label, c string) {
	b.echo("   %s DEGRADED  %s (line count failed)", label, c)
	b.rc = 1
	b.dN++
}

// resolveArtifact is pass (a): MISSING (unpreserved evidence) and out-of-range both FAIL.
func (b *blockRun) resolveArtifact(c string) {
	b.m++ // P9-VB-M-ART
	n := strings.NewReplacer("‑", "-", "–", "-").Replace(c)
	i := strings.LastIndex(n, ":")
	f, rng := n[:i], n[i+1:]
	start, end := splitRange(rng)
	if !b.fs.isFile(b.target + "/" + f) { // D6-PATH-FALLBACK: the cite may carry a path prefix elsewhere in the block
		pat := vbRe(`(?i)[a-zA-Z0-9_./-]+/` + regexp.QuoteMeta(f))
		for _, l := range b.lines {
			if m := grepO(pat, l); len(m) > 0 {
				if b.fs.isFile(b.target + "/" + m[0]) {
					f = m[0]
				}
				break
			}
		}
	}
	if !b.fs.isFile(b.target + "/" + f) {
		b.echo("   MISSING! %s  (evidence artifact not preserved)", c)
		b.rc = 1
		b.f++
		return
	}
	total, ok := b.fs.vbLines(b.target+"/"+f, 0)
	if !ok {
		b.degraded("linecount", c)
		return
	}
	sv, okS := shellInt(start)
	ev, okE := shellInt(end)
	if okS && okE && sv <= total && ev <= total && sv <= ev {
		b.echo("   ok      %s", c)
		b.ok++
	} else {
		b.echo("   RANGE!  %s  (file has %d lines) — cited line out of range", c, total)
		b.rc = 1
		b.f++
	}
}

// resolveBacktick is pass (b): ok / RANGE! / extern / nonpath for a backticked `name.ext:N[-M]` cite.
func (b *blockRun) resolveBacktick(c string) {
	f := citeFile(c)
	rng := c[len(f)+1:]
	start, end := splitRange(rng)
	if vbArtShape.MatchString(f) {
		return // handled strictly by the artifact pass
	}
	b.m++ // P9-VB-M-BT
	sv, okS := shellInt(start)
	ev, okE := shellInt(end)
	if okS && sv == 0 {
		b.echo("   RANGE!  %s  (start 0 is invalid — lines are 1-indexed)", c)
		b.rc = 1
		b.f++
		return
	}
	if okS && okE && sv > ev {
		b.echo("   RANGE!  %s  (reversed range: start %s > end %s — defect in block)", c, start, end)
		b.rc = 1
		b.f++
		return
	}
	var endN int64
	if okE {
		endN = ev
	}
	// Roots are tried in order; the first where the file exists AND the cited range fits wins (F2). If none fits,
	// RANGE! is reported against the FIRST existing file.
	type root struct{ dir, label string }
	roots := []root{{b.target, ""}}
	if b.gitRoot != "" && b.gitRoot != b.target {
		roots = append(roots, root{b.gitRoot, ""})
	}
	if b.targetRoot != "" {
		roots = append(roots, root{b.targetRoot, "(target-root) "})
	}
	if b.sourceRoot != "" {
		roots = append(roots, root{b.sourceRoot, ""})
	}
	resolve, first, tag, firstTag, cdeg := "", "", "", "", false
	for _, r := range roots {
		p := r.dir + "/" + f
		if !b.fs.isFile(p) {
			continue
		}
		if first == "" {
			first, firstTag = p, r.label
		}
		if fit, ok := b.fs.vbLines(p, endN); ok {
			if okE && ev <= fit { // BT-RANGE-FIT
				resolve, tag = p, r.label
				break
			}
		} else {
			cdeg = true // BT-FIT-DEGRADED
		}
	}
	if resolve == "" && cdeg {
		b.degraded("linecount", c)
		return
	}
	if resolve == "" && first != "" {
		resolve, tag = first, firstTag
	}
	if resolve != "" && b.fs.isFile(resolve) {
		okp := "ok      "
		if tag != "" {
			okp = "ok " + tag
		}
		total, ok := b.fs.vbLines(resolve, 0)
		if !ok {
			b.degraded("linecount", c)
			return
		}
		if okE && ev <= total {
			if start == end {
				b.echo("   %s%s", okp, c)
			} else {
				b.echo("   %s%s  (range end verified; file has %d lines)", okp, c, total)
			}
			b.ok++
		} else {
			b.echo("   RANGE!  %s  (file has %d lines) — cited line out of range", c, total)
			b.rc = 1
			b.f++
		}
		return
	}
	// Unresolved cite.
	if b.externCheck && strings.HasPrefix(f, "/") { // VB-EXTERN-CHECK
		b.xa++
		if !b.fs.isFile(f) || !b.fs.readableFile(f) {
			b.echo("   extern  %s  (absolute path not found or unreadable — not script-verifiable)", c)
			b.e++
			return
		}
		total, ok := b.fs.vbLines(f, endN)
		if !ok {
			b.degraded("extern-check", c)
			return
		}
		b.xr++
		if okE && ev > total {
			b.echo("   RANGE!  %s  (file has %d lines) — cited line out of range", c, total)
			b.rc = 1
			b.f++
			return
		}
		if start == end {
			b.echo("   ok extern %s", c)
		} else {
			b.echo("   ok extern %s  (range end verified)", c)
		}
		b.ok++
		return
	}
	ext := f[strings.LastIndex(f, ".")+1:]
	lext := strings.ToLower(ext)
	methodLike := false
	if !strings.Contains(f, "/") && ext != "" && ext[0] >= 'a' && ext[0] <= 'z' {
		stem := f
		if i := strings.LastIndex(f, "."); i >= 0 {
			stem = f[:i]
		}
		methodLike = strings.ContainsFunc(stem, func(r rune) bool { return r >= 'A' && r <= 'Z' })
	}
	if methodLike && !vbExtSet[lext] { // P973-NONPATH-METHOD
		b.echo("   nonpath  %s  (not a file path: unknown extension '%s', no such file — likely Class.method:NNN; excluded from M)", c, lext)
		b.m--
		b.npN++
		return
	}
	if b.externCheck {
		b.xrel++
	}
	b.echo("   extern  %s  (not in target: beautified-temp / decompiled / snapshot — not script-verifiable)", c) // P9-VB-E-EXTERN
	b.e++
}

// p9Summary is P9-RESOLVED-SUMMARY: "resolved N of M", graded by the declared Type: when none resolved.
func (b *blockRun) p9Summary() {
	if b.m > 0 {
		deg := ""
		if b.dN > 0 {
			deg = ", " + strconv.Itoa(b.dN) + " degraded"
		}
		b.echo("   resolved %d of %d (%d extern, %d failed%s)", b.ok, b.m, b.e, b.f, deg)
		why := "no file paths resolved."
		switch {
		case b.dN > 0:
			why = "line count failed — instrument, not the cite (see the DEGRADED lines above); those cites were not judged."
		case b.e > 0:
			why = "no file paths resolved. Set SOURCE_ROOT if source files live in a separate tree."
		case b.f > 0:
			why = "every cite failed (RANGE!/MISSING!, listed above) — fix those cites; SOURCE_ROOT would not help."
		}
		if b.ok == 0 {
			if b.certTotal > 0 && b.codeCertTotal == 0 { // P9-DOC-GRADE-GUARD
				b.echo("   INFO    resolved 0 of %d — doc-grade markers only; file:line citations not expected.", b.m)
				return
			}
			switch b.typeClass {
			case "nocite":
				b.echo("   INFO    resolved 0 of %d — expected for declared type %s.", b.m, b.typeToken)
			case "cite":
				b.echo("   WARN    resolved 0 of %d — %s", b.m, why)
			default:
				if b.typeRaw != "" {
					b.echo("   WARN    resolved 0 of %d — unrecognised Type: '%s'; %s", b.m, b.typeWarnName, why)
				} else {
					b.echo("   WARN    resolved 0 of %d — %s", b.m, why)
					b.echo("   HINT    Declare a Type: token to grade this WARN: %s.", vbTypesPipe)
				}
			}
		}
	} else if b.npN > 0 { // P973-NONPATH-INFO
		b.echo("   INFO    0 file citations counted — %d non-path token(s) excluded from M (listed above as nonpath).", b.npN)
	}
}
