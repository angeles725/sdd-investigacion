package block

import (
	"fmt"
	"strings"
)

// Sections 1-2 of verify-block: the marker tally (raw vs adjusted), the [INFER]/[CERT*] ratio and the closed
// `Type:` grammar every later verdict line is graded by.

var vbMarkers = []string{"CERT-hw", "CERT-live", "CERT", "CERT-doc", "CERT-web", "CERT-a", "INFER"}

const (
	vbTypesNoCite = "synthesis capture document absence-centred decision design-applied" // VB-TYPE-LIST-NOCITE
	vbTypesCite   = "standard evidence mixed collaborative audit"                        // VB-TYPE-LIST-CITE
)

// vbTypesPipe is _VB_TYPES_PIPE.
var vbTypesPipe = strings.ReplaceAll(vbTypesCite, " ", " | ") + " | " + strings.ReplaceAll(vbTypesNoCite, " ", " | ")

var (
	vbTypeLine   = vbRe(`(?i)^[[:space:]]*>[[:space:]]*(\*\*)?[[:space:]]*type:`)
	vbTypeBQ     = vbRe(`^[[:space:]]*>[[:space:]]*`)
	vbTypeAfter  = vbRe(`(?i).*type:`)
	vbTypeLead   = vbRe("^[[:space:]*`]*")
	vbTypeToken  = vbRe(`^[a-z][a-z0-9-]*`)
	vbWarnStar   = vbRe(`[[:space:]]*\*.*`)
	vbWarnPeriod = vbRe(`[[:space:]]*\.[[:space:]]*$`)
	vbWarnTrail  = vbRe(`[[:space:]]*$`)
	vbLegendOpen = vbRe(`^[[:space:]]*>`)
	vbLegendH2   = vbRe(`^##[[:space:]]`)
	vbLegendFnc  = vbRe(`^---[[:space:]]*$`)
)

// legendFence is the awk that finds the closing `---` of the leading blockquote legend (0 when none).
func (b *blockRun) legendFence() int {
	q := false
	for i, l := range b.lines {
		if vbLegendH2.MatchString(l) {
			return 0
		}
		if q && vbLegendFnc.MatchString(l) {
			return i + 1
		}
		if vbLegendOpen.MatchString(l) {
			q = true
		}
	}
	return 0
}

func (b *blockRun) sectionTally() {
	fence := b.legendFence()
	body := b.lines[fence:]
	raw, adj := map[string]int{}, map[string]int{}
	for _, m := range vbMarkers {
		tok := "[" + m + "]"
		for _, l := range b.lines {
			raw[m] += strings.Count(l, tok)
		}
		for _, l := range body {
			adj[m] += strings.Count(l, tok)
		}
	}
	b.echo("-- marker tally (raw = whole block · adj = claims, header legend stripped) --")
	for _, m := range vbMarkers {
		if raw[m] != adj[m] {
			b.echo("   [%s] %d  (adj %d)", m, raw[m], adj[m])
		} else {
			b.echo("   [%s] %d", m, raw[m])
		}
	}
	if fence == 0 {
		b.echo("   (no leading-blockquote '---' fence — adjusted = raw; the legend could not be isolated)")
	}
	b.certTotal = adj["CERT-hw"] + adj["CERT-live"] + adj["CERT"] + adj["CERT-doc"] + adj["CERT-web"] + adj["CERT-a"]
	b.codeCertTotal = adj["CERT-hw"] + adj["CERT-live"] + adj["CERT"]
	b.infer = adj["INFER"]
}

func (b *blockRun) sectionRatio() {
	ratio := "n/a (no CERT markers)"
	if b.certTotal > 0 {
		ratio = fmt.Sprintf("%.2f", float64(b.infer)/float64(b.certTotal))
	}
	b.echo("-- ratio -- [INFER]/[CERT*] = %d/%d = %s", b.infer, b.certTotal, ratio)
	b.parseType()
	var typeLine, tail string
	if b.typeClass != "unknown" { // VB-RATIO-CLASS
		typeLine, tail = "   declared Type: "+b.typeToken, "; read it against the declared Type, §11)"
	} else {
		switch {
		case b.typeRaw == "": // VB-RATIO-ABSENT
			typeLine = "   no blockquote Type: line found"
		case b.typeWarnName == "": // VB-RATIO-EMPTY
			typeLine = "   empty Type: line"
		default:
			typeLine = "   unrecognised Type '" + b.typeWarnName + "'"
		}
		tail = " — DECLARE the block TYPE so the ratio is read right, §11)"
	}
	b.echo("%s", typeLine)
	b.echo("   (>~0.5 in an EVIDENCE block signals investigable evidence nearly exhausted; EXPECTED and healthy in a")
	b.echo("    DESIGN/synthesis block%s", tail)
}

// parseType reads the first blockquote `Type:` line once (P9-TYPE-PARSE-EARLY), shared by the ratio line, P6 and P9.
func (b *blockRun) parseType() {
	for _, l := range b.lines {
		if vbTypeLine.MatchString(l) {
			b.typeRaw = l
			break
		}
	}
	b.typeClass = "unknown"
	if b.typeRaw != "" {
		noBQ := vbTypeBQ.ReplaceAllString(b.typeRaw, "") // P6-BQ-STRIP
		after := noBQ
		if loc := vbTypeAfter.FindStringIndex(noBQ); loc != nil { // P6-BQ-TYPECASE: up to the LAST `type:`
			after = noBQ[loc[1]:]
		}
		b.typeStripped = vbTypeLead.ReplaceAllString(after, "") // P6-TYPE-STRIP
		b.typeToken = vbTypeToken.FindString(b.typeStripped)    // P1418-TYPE-DIGITS
	}
	if b.typeToken != "" {
		if strings.Contains(" "+vbTypesNoCite+" ", " "+b.typeToken+" ") {
			b.typeClass = "nocite"
		}
		if strings.Contains(" "+vbTypesCite+" ", " "+b.typeToken+" ") {
			b.typeClass = "cite"
		}
	}
	b.typeWarnName = b.typeToken // TYPE-DISPLAY
	if b.typeWarnName == "" {
		n := vbWarnStar.ReplaceAllString(b.typeStripped, "")
		n = vbWarnPeriod.ReplaceAllString(n, "")
		b.typeWarnName = vbWarnTrail.ReplaceAllString(n, "")
	}
}
