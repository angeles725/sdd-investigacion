package lint

// Port of lint-block-packs/native-binary.py: R9, a [CERT] claim about a native binary needs the binary's sha256, an
// address anchor and two distinct instruments. The lookarounds became explicit scans.

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

var (
	r9MarkerRE = newLazyRE(`\[CERT(?:-hw|-live)?\]`)

	// R9_NATIVE_RE, case-sensitive. The first alternative is
	//   \b[\w.+-]+\.(?:dll|so(?:\.\d+)*|exe|dylib)\b(?![\w/-]|\.[A-Za-z])
	// A file-name token: some word rune must precede the dot inside its [\w.+-] run (the first one gives the leading
	// \b), the extension is followed by a non-word rune (the \b), which is not `/` or `-`, and not a `.` that is
	// followed by an ASCII letter (a longer name such as foo.dll.bak).
	r9NativeRE = newLazyRE(alt(
		`[`+wcls+`][`+wcls+`.+-]*\.(?:dll|so(?:\.\p{Nd}+)*|exe|dylib)(?:$|[^`+wcls+`/.-]|\.(?:$|[^A-Za-z]))`,
		lb+`PE32`, lb+`ELF(?:32|64)?`+rb, lb+`Mach-O`+rb,
		lb+`PE`+ws+`+(?:binary|binaries|file|image|header|section)s?`+rb, lb+`Authenticode`+rb,
	))

	r9HexRunRE = newLazyRE(`[0-9A-Fa-f]+`)
	// R9_ANCHOR_RE: `\b0x[0-9A-Fa-f]{3,}\b` here; the VA / RVA / offset form is anchorKeyRE plus anchorHex.
	r9HexAnchorRE = newLazyRE(lb + `0x[0-9A-Fa-f]{3,}` + rb)
	r9AnchorKeyRE = newLazyRE(`(?:VA|RVA|offset)` + ws + `*[:=]?` + ws + `*`)

	r9CodeSpanRE = newLazyRE("`([^`]*)`")
)

// r9Instruments are matched case-insensitively; `nm` and `strings` are ordinary words and count only inside a
// backtick code span. `r2` (radare2's CLI) counts only in exactly that lower-case spelling: matched
// case-insensitively it would collide with the rule id "R2".
var (
	r9Names = []string{
		"readelf", "objdump", "r2", "radare2", "rabin2", "ghidra", "pefile", "pelib", "osslsigncode", "ilspycmd", "ilspy", "diec",
		"dumpbin", "otool", "ldd", "gdb", "lldb", "capstone", "xxd", "hexdump", "binwalk", "debug/pe", "debug/gosym", "debug/elf", "gosym",
	}
	r9CodeOnly     = []string{"nm", "strings"}
	r9InstrumentRE *lazyRE
)

func init() {
	names := append([]string(nil), r9Names...)
	// longest first, so ilspycmd wins over ilspy (equal lengths cannot be prefixes of each other)
	sort.SliceStable(names, func(a, b int) bool { return len(names[a]) > len(names[b]) })
	quoted := make([]string, len(names))
	for i, n := range names {
		quoted[i] = regexp.QuoteMeta(n)
	}
	// `(?<![\w/])(names)(?![\w])`: the lookahead is the consuming rb, the lookbehind is checked at the match start.
	r9InstrumentRE = reCI(`(` + strings.Join(quoted, "|") + `)` + rb)
}

func r9Native(c string) bool { return r9NativeRE.MatchString(c) }

// r9Sha256 is `(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])`: a maximal run of hex digits exactly 64 long.
func r9Sha256(t string) bool {
	for _, run := range r9HexRunRE.FindAllString(t, -1) {
		if len(run) == 64 {
			return true
		}
	}
	return false
}

// r9Anchor: `0x` and 3+ hex digits, or VA / RVA / offset then 4+ hex digits that include a decimal digit
// (`(?=[0-9A-Fa-f]*\d)`: English words made only of hex letters, "offset decade", are not addresses). Both end at a
// word boundary, so the hex run is the maximal one.
func r9Anchor(t string) bool {
	if r9HexAnchorRE.MatchString(t) {
		return true
	}
	for pos := 0; pos < len(t); {
		loc := r9AnchorKeyRE.FindStringIndex(t[pos:])
		if loc == nil {
			return false
		}
		s, e := pos+loc[0], pos+loc[1]
		if !wordBefore(t, s) {
			end := e
			for end < len(t) && strings.IndexByte("0123456789abcdefABCDEF", t[end]) >= 0 {
				end++
			}
			if end-e >= 4 && !wordAfter(t, end) && strings.ContainsAny(t[e:end], "0123456789") {
				return true
			}
		}
		pos = s + 1 // the keyword starts with an ASCII letter
	}
	return false
}

// r9Instruments is instruments(): the distinct instrument names a text cites, lower-cased and sorted.
func r9Instruments(text string) []string {
	found := map[string]bool{}
	// finditer: the next search starts where the previous match ENDED (the name, not the rune rb consumed).
	for pos := 0; pos < len(text); {
		m := r9InstrumentRE.FindStringSubmatchIndex(text[pos:])
		if m == nil {
			break
		}
		s, e := pos+m[2], pos+m[3]
		if r, n := utf8.DecodeLastRuneInString(text[:s]); n > 0 && (isPyWord(r) || r == '/') { // (?<![\w/])
			_, n := utf8.DecodeRuneInString(text[s:])
			pos = s + n
			continue
		}
		if name := text[s:e]; name != "R2" { // the rule id "R2", not radare2
			found[pyLower(name)] = true
		}
		pos = e
	}
	for _, m := range r9CodeSpanRE.FindAllStringSubmatch(text, -1) {
		for _, name := range r9CodeOnly {
			if codeOnlyName(m[1], name) {
				found[name] = true
			}
		}
	}
	out := make([]string, 0, len(found))
	for n := range found {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// codeOnlyName is `(?<![\w/-])name(?![\w-])` searched in a code span.
func codeOnlyName(span, name string) bool {
	for off := 0; ; {
		i := strings.Index(span[off:], name)
		if i < 0 {
			return false
		}
		i += off
		before, bn := utf8.DecodeLastRuneInString(span[:i])
		okBefore := bn == 0 || !(isPyWord(before) || before == '/' || before == '-')
		after, an := utf8.DecodeRuneInString(span[i+len(name):])
		okAfter := an == 0 || !(isPyWord(after) || after == '-')
		if okBefore && okAfter {
			return true
		}
		off = i + 1
	}
}

func nativeBinaryRules() []packRule {
	// sectionText is the heading plus its OWN body: every unit up to the first following heading of any level (a
	// child section never clears its parent); an empty body is judged on the heading alone and therefore fires.
	sectionText := func(d *doc, h unit) string {
		end := 0
		for _, u := range d.units {
			if u.kind == "heading" && u.line > h.line {
				end = u.line
				break
			}
		}
		var parts []string
		for _, u := range d.units {
			if u.line >= h.line && (end == 0 || u.line < end) {
				parts = append(parts, u.text)
			}
		}
		return strings.Join(parts, " ")
	}
	rule := func(d *doc) []finding {
		var out []finding
		for _, u := range d.units {
			if !claimKind(u.kind) {
				continue
			}
			// Trigger: some clause pairs an evidence marker with native-binary context; the requirements are then
			// checked over the WHOLE unit (sha256, address and instruments sit in neighbouring clauses).
			claim := false
			for _, c := range clauses(u.text) {
				if r9MarkerRE.MatchString(c) && r9Native(c) {
					claim = true
					break
				}
			}
			if !claim {
				continue
			}
			d.bump("r9_triggers", 1)
			if d.waived("R9", u) {
				continue
			}
			text := u.text
			if u.kind == "heading" {
				text = sectionText(d, u)
			}
			var missing []string
			if !r9Sha256(text) {
				missing = append(missing, "no sha256 (64 hex) of the binary")
			}
			if !r9Anchor(text) {
				missing = append(missing, "no address anchor (0x... VA or file offset)")
			}
			if n := len(r9Instruments(text)); n < 2 {
				missing = append(missing, fmt.Sprintf("%d of 2 instruments named (allowlist R9_INSTRUMENTS)", n))
			}
			if len(missing) > 0 {
				out = append(out, finding{u.line, "R9", "native-binary claim: " + strings.Join(missing, "; ") + ": " + pyExcerpt(u.text, 100)})
			}
		}
		return out
	}
	return []packRule{{"R9", rule}}
}
