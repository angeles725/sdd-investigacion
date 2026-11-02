package firmware

import (
	"math/big"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// pyWS is the class Python's \s means for str patterns: ASCII whitespace, the file/group/record/unit
// separators and the Unicode space characters.
const pyWS = `\t\n\v\f\r \x1c-\x1f\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}`

var (
	// Python's \d for str patterns is any Unicode decimal digit.
	findingRe = regexp.MustCompile(`^[` + pyWS + `]*(\p{Nd}+)[` + pyWS + `]+0x([0-9a-fA-F]+)[` + pyWS + `]+(.+?)[` + pyWS + `]*$`)
	ansiRe    = regexp.MustCompile(`\x1b\[[0-9;]*m`)
)

// finding is one Binwalk output line: its offset (any size, like Python's int), the offset in hex, and the
// description with whitespace collapsed.
type finding struct {
	Description string
	Hex         string
	Offset      *big.Int
}

func (f finding) object() map[string]any {
	return map[string]any{"description": f.Description, "hex": f.Hex, "offset": jsonNumber(f.Offset)}
}

// parseFindings reads a Binwalk listing the way the script does: one finding per line shaped
// "<decimal offset> 0x<hex offset> <description>" (ANSI colour codes removed first); every other line is
// ignored. Lines naming "entropy" are entropy edges, the rest signatures; each list is sorted by
// (offset, description).
func parseFindings(text string) (signatures, entropy []finding) {
	for _, line := range pySplitlines(strings.ToValidUTF8(text, "�")) {
		m := findingRe.FindStringSubmatch(ansiRe.ReplaceAllString(line, ""))
		if m == nil {
			continue
		}
		hex, _ := new(big.Int).SetString(m[2], 16)
		item := finding{
			Description: strings.Join(strings.FieldsFunc(m[3], isPySpace), " "),
			Hex:         "0x" + hex.Text(16),
			Offset:      decimal(m[1]),
		}
		if strings.Contains(strings.ToLower(item.Description), "entropy") {
			entropy = append(entropy, item)
		} else {
			signatures = append(signatures, item)
		}
	}
	less := func(list []finding) func(i, j int) bool {
		return func(i, j int) bool {
			if c := list[i].Offset.Cmp(list[j].Offset); c != 0 {
				return c < 0
			}
			return list[i].Description < list[j].Description
		}
	}
	sort.SliceStable(signatures, less(signatures))
	sort.SliceStable(entropy, less(entropy))
	return signatures, entropy
}

// decimal is int(text) for a run of Unicode decimal digits.
func decimal(text string) *big.Int {
	var b strings.Builder
	for _, r := range text {
		b.WriteByte(byte('0' + digitValue(r)))
	}
	n, _ := new(big.Int).SetString(b.String(), 10)
	return n
}

// digitValue is the numeric value of a Unicode decimal digit: the position inside its block of ten.
func digitValue(r rune) int {
	if r <= 0xffff {
		for _, rg := range unicode.Nd.R16 {
			if uint16(r) >= rg.Lo && uint16(r) <= rg.Hi {
				return int(uint16(r)-rg.Lo) % 10
			}
		}
	}
	for _, rg := range unicode.Nd.R32 {
		if uint32(r) >= rg.Lo && uint32(r) <= rg.Hi {
			return int(uint32(r)-rg.Lo) % 10
		}
	}
	return 0
}

// isPySpace is str.isspace for one character: Go's white space plus the four ASCII separators.
func isPySpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

// pySplitlines is str.splitlines(): it splits at \n, \r, \r\n, \v, \f, the separators 0x1c-0x1e, NEL, LS and PS,
// and a trailing break does not make an empty last line.
func pySplitlines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); {
		r, w := utf8.DecodeRuneInString(s[i:])
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			lines = append(lines, s[start:i])
			start = i + w
		case '\r':
			lines = append(lines, s[start:i])
			if i+1 < len(s) && s[i+1] == '\n' {
				w++
			}
			start = i + w
		}
		i += w
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}
