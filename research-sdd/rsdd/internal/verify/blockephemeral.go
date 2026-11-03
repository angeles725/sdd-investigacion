package verify

import (
	"fmt"
	"regexp"
	"strings"
)

// Section 10 of verify-block: EPHEMERAL-PATH CITES (kit #1207/#1660). A cited path under /tmp, /var/tmp (also
// /private/tmp, /private/var/tmp, $TMPDIR/, ${TMPDIR}/) or a session `scratchpad/` directory will not exist in the
// next session: FAIL by default (EPHEMERAL!), a WARN (EPHEMERAL?) under --ephemeral=warn or RSDD_STRICT_EPHEMERAL=0.
// Exempt: a line with a REAL sha256 anchor (the word and a 64-hex digest on the same line) is an INFO, and a
// `<!-- ephemeral-ok: <reason> -->` marker with a non-empty reason waives the line (an empty reason leaves the
// finding standing plus a typed `invalid marker` line). The scan reads every path-shaped token of every line.

var (
	vbEPTmp       = vbRe(`(\$\{?TMPDIR\}?|/private/var/tmp|/private/tmp|/var/tmp|/tmp)/[A-Za-z0-9_./@+=:~-]*`)
	vbEPScratch   = vbRe(`[A-Za-z0-9_./@+=:~-]*scratchpad/[A-Za-z0-9_./@+=:~-]*`)
	vbEPGlueTmp   = regexp.MustCompile(`^[A-Za-z0-9_./~$-]$`)
	vbEPGlueSpad  = regexp.MustCompile(`^[$}A-Za-z0-9_@+=:~-]$`)
	vbEPOwned     = regexp.MustCompile(`^(\$\{?TMPDIR\}?|/private/var/tmp|/private/tmp|/var/tmp|/tmp)/`)
	vbEPTrailPunc = regexp.MustCompile(`[.,:;]+$`)
	vbEPTrim      = regexp.MustCompile(`^[[:space:]]+|[[:space:]]+$`)
	vbHex64Run    = vbRe(`[0-9a-f]+`)
)

// hasDigest is hasdigest(): the word sha256 AND a maximal 64-hex run on the line.
func hasDigest(line string) bool {
	l := awkLower(line)
	if !strings.Contains(l, "sha256") {
		return false
	}
	for {
		loc := vbHex64Run.FindStringIndex(l)
		if loc == nil {
			return false
		}
		if loc[1]-loc[0] == 64 { // VB-EP-DIGEST64
			return true
		}
		l = l[loc[1]:]
	}
}

type epCounts struct{ n, a, k, i int }

func (b *blockRun) sectionEphemeral() {
	var c epCounts
	var buf []string
	emit := func(format string, a ...any) { buf = append(buf, fmt.Sprintf(format, a...)) }
	for ln, line := range b.lines {
		flagged := false
		scan := func(re *regexp.Regexp, glue *regexp.Regexp, spad bool) {
			rest := line
			anchored := hasDigest(line) // VB-EP-ANCHOR
			ok, reason := false, ""
			mk := strings.Index(line, "<!-- ephemeral-ok:") // VB-EP-MARKER
			if mk >= 0 {
				reason = line[mk+len("<!-- ephemeral-ok:"):]
				if j := strings.Index(reason, "-->"); j >= 0 {
					reason = reason[:j]
				}
				reason = vbEPTrim.ReplaceAllString(reason, "")
				ok = reason != "" // VB-EP-REASON
			}
			for {
				loc := re.FindStringIndex(rest)
				if loc == nil {
					return
				}
				tok := rest[loc[0]:loc[1]]
				before := ""
				if loc[0] > 0 {
					before = lastRuneOf(rest[:loc[0]])
				}
				after := rest[loc[1]:]
				if !glue.MatchString(before) && !skipScratch(tok, spad) { // VB-EP-GLUE
					tok = vbEPTrailPunc.ReplaceAllString(tok, "")
					switch {
					case anchored:
						emit("   INFO    ephemeral-anchored line %d: %s (sha256-anchored beautified-temp view, METHODOLOGY §5)", ln+1, tok)
						c.a++
					case ok:
						emit("   INFO    ephemeral-ok line %d: %s (waived on purpose: %s)", ln+1, tok, reason)
						c.k++
					default:
						if mk >= 0 && !flagged {
							flagged = true
							emit("   WARN    invalid marker line %d: `<!-- ephemeral-ok: <reason> -->` needs a non-empty reason — marker ignored", ln+1)
							c.i++
						}
						if b.strictEP { // VB-EP-STRICT
							emit("   EPHEMERAL!  %s  (line %d; session/temp path — preserve under sources/probes/b<N>/)", tok, ln+1)
							c.n++
							b.rc = 1 // VB-EP-FAIL
						} else {
							emit("   EPHEMERAL?  %s  (line %d; session/temp path — preserve under sources/probes/b<N>/; opt-out --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 is active, the default is FAIL)", tok, ln+1)
							c.n++
						}
					}
				}
				rest = after
			}
		}
		scan(vbEPTmp, vbEPGlueTmp, false)     // VB-EP-TMP
		scan(vbEPScratch, vbEPGlueSpad, true) // VB-EP-SCRATCHPAD
	}
	b.echo("-- ephemeral-path cites (kit #1207/#1660: /tmp, /var/tmp, scratchpad — FAIL by default, WARN under --ephemeral=warn or RSDD_STRICT_EPHEMERAL=0; exempt: sha256 anchor, <!-- ephemeral-ok: <reason> --> marker) --")
	for _, l := range buf {
		b.echo("%s", l)
	}
	switch {
	case c.n == 0:
		b.echo("   (none — no unanchored ephemeral path cited; sha256-anchored: %d, ephemeral-ok: %d, invalid markers: %d)", c.a, c.k, c.i)
	case b.strictEP:
		b.echo("-- ephemeral-path cites: %d (FAIL — preserve under sources/probes/b<N>/, waive a non-evidence line with <!-- ephemeral-ok: <reason> -->, or opt out with --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 while the corpus is cleaned, kit #1660)", c.n)
	default:
		b.echo("-- ephemeral-path cites: %d (WARN — exit unchanged; opt-out --ephemeral=warn / RSDD_STRICT_EPHEMERAL=0 in force, the default is FAIL, kit #1660)", c.n)
	}
}

// skipScratch is skipspad(): the scratchpad arm needs a `scratchpad` PATH SEGMENT and must not be /tmp-owned.
func skipScratch(tok string, spad bool) bool {
	if !spad {
		return false
	}
	i := strings.Index(tok, "scratchpad/")
	if !(i == 0 || tok[i-1] == '/') { // VB-EP-SEGMENT
		return true
	}
	return vbEPOwned.MatchString(tok) // VB-EP-OWNED
}
