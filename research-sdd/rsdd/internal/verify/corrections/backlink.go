package corrections

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// The reciprocal-backlink vocabulary (METHODOLOGY §14; #1835 item 2, #1868 item 6, #1874 item 1): a target block
// "carries the note" when one of its lines matches the vocabulary AND names the correcting block, or when it has
// the corrigendum NOUN shape naming that block.
//
// The legacy script ran the vocabulary grep under LC_ALL=C (ASCII case folding, a byte-range boundary class) and
// the "names block C" grep under the caller's locale. Here both are locale-independent: ASCII case folding
// everywhere, and a word is a Unicode letter, digit or underscore, which is what the legacy second grep did under
// the UTF-8 locales the kit runs in (documented in tool-registry.d/verify-corrections.md).

// ci expands the ASCII letters of s into [xX] classes: a case-insensitive match that never folds a non-ASCII
// character (the legacy grep -i ran under LC_ALL=C).
func ci(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z':
			b.WriteString("[" + string(c) + string(c-'a'+'A') + "]")
		case c >= 'A' && c <= 'Z':
			b.WriteString("[" + string(c-'A'+'a') + string(c) + "]")
		default:
			b.WriteString(regexp.QuoteMeta(string(c)))
		}
	}
	return b.String()
}

// punct is the UTF-8 punctuation that may directly precede the word (em/en dash, curly quotes, guillemets,
// inverted ? and !, middle dot): a boundary, not word text (#1847).
const punct = `—|–|‘|’|“|”|«|»|¿|¡|·`

var (
	// reVocabulary is the backlink vocabulary behind a left word boundary. `_` is a boundary here: markdown
	// italics `_corrected in B33_` is a real note.
	reVocabulary = regexp.MustCompile(`(^|[\x00-\x2f\x3a-\x40\x5b-\x60\x7b-\x7f]|` + punct + `)(` + strings.Join([]string{
		ci("corrected"),
		ci("corregid") + `[oOaA]` + ci("s") + `?`,
		ci("corrigend") + `(` + ci("um") + `|` + ci("a") + `)`,
		ci("errat") + `(` + ci("um") + `|` + ci("a") + `)`,
		ci("refined") + `[[:space:]]+(` + ci("in") + `|` + ci("by") + `|` + ci("at") + `|` + ci("as") + `|` + ci("per") + `)`,
		ci("refinad") + `[oOaA]` + ci("s") + `?[[:space:]]+(` + ci("en") + `|` + ci("por") + `)`,
		`§14[[:space:]]+` + ci("refinement"),
		ci("refinement") + `[[:space:]]*\(`,
		ci("refinamiento") + `[[:space:]]*(\(|§14)`,
	}, "|") + `)`)

	// nounHead/nounTail frame the corrigendum NOUN shape: `**CORRECCIÓN (2026-07-26) — [Block 292].**`. The noun
	// alone is prose, so the shape is strict: an optional parenthetical tag, an optional dash, then DIRECTLY the
	// [Block N] ref of the correcting block, closing its sentence or followed by a § locator (a `:` or `,` after
	// the ref continues the sentence, and a colon before it introduces the corrected thing).
	nounHead = `(^|[\x00-\x2f\x3a-\x40\x5b-\x5e\x60\x7b-\x7f]|` + punct + `)(` + ci("correcci") + `(ó|Ó|` + ci("o") + `)` + ci("n") + `|` + ci("correction") + `)` +
		`[[:space:]*]*(\([^)]*\))?[[:space:]*]*(—|–|-)?[[:space:]*]*\[[[:space:]]*(` + ci("block") + `|` + ci("bloque") + `)[[:space:]]*0*`
	nounTail = `[[:space:]]*\][[:space:]*]*(§[[:space:]]*[0-9][0-9.]*)?[[:space:]*]*([.;]|$)`
)

// hasVocabulary reports whether line carries a backlink-vocabulary word behind a left word boundary.
func hasVocabulary(line string) bool { return reVocabulary.MatchString(line) }

// nounRegexp is the corrigendum-noun shape naming block c (cached by the caller).
func nounRegexp(c string) *regexp.Regexp { return regexp.MustCompile(nounHead + c + nounTail) }

// isWordRune is a word character for the boundary of a block reference: a Unicode letter, digit or underscore.
func isWordRune(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) }

func wordBefore(s string, i int) bool {
	if i <= 0 {
		return false
	}
	r, _ := utf8.DecodeLastRuneInString(s[:i])
	return r != utf8.RuneError && isWordRune(r)
}

func wordAfter(s string, i int) bool {
	if i >= len(s) {
		return false
	}
	r, _ := utf8.DecodeRuneInString(s[i:])
	return r != utf8.RuneError && isWordRune(r)
}

// namesBlock reports whether line names block c (a canonical decimal, no leading zero): `B33`, `b033`,
// `Block 33`, `bloque  033`, each as a whole word; never `B330`, `B33a`, `xB33`.
func namesBlock(line, c string) bool {
	low := asciiLower(line)
	for i := 0; i < len(low); i++ {
		if low[i] != 'b' || wordBefore(low, i) {
			continue
		}
		j := i + 1
		switch {
		case strings.HasPrefix(low[i:], "bloque"):
			j = i + len("bloque")
		case strings.HasPrefix(low[i:], "block"):
			j = i + len("block")
		}
		if j > i+1 {
			for j < len(low) && strings.IndexByte(" \t\n\v\f\r", low[j]) >= 0 {
				j++
			}
		}
		k := j
		for k < len(low) && low[k] >= '0' && low[k] <= '9' {
			k++
		}
		// A trailing `_` closes markdown emphasis (`_corrected in B33_`), it is not word text (the legacy `\b` read it as
		// one and rejected the very shape the vocabulary comment promises).
		if k == j || (wordAfter(low, k) && low[k] != '_') {
			continue
		}
		d := strings.TrimLeft(low[j:k], "0")
		if d == "" {
			d = "0"
		}
		if d == c {
			return true
		}
	}
	return false
}

// reciprocated reports whether the target text back-links block c, by the vocabulary line or by the noun shape.
func reciprocated(lines []string, c string, noun *regexp.Regexp) bool {
	for _, l := range lines {
		if hasVocabulary(l) && namesBlock(l, c) {
			return true
		}
	}
	for _, l := range lines {
		if noun.MatchString(l) {
			return true
		}
	}
	return false
}
