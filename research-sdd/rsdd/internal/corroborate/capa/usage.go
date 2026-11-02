package capa

// The legacy parser's usage and help text, rendered the way argparse's HelpFormatter does for a terminal
// of a given width (shutil.get_terminal_size: $COLUMNS when it is a positive integer, else 80).

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

const prog = "corroborate-capa"

// usageParts are the usage tokens after the program name; --manifest-cli is suppressed from the help.
var usageParts = []string{
	"[-h]", "--input", "INPUT", "--output", "OUTPUT", "[--rules RULES]", "[--timeout TIMEOUT]",
	"[--max-capabilities MAX_CAPABILITIES]",
}

// helpEntries are the documented options: invocation and help text.
var helpEntries = [][2]string{
	{"-h, --help", "show this help message and exit"},
	{"--input INPUT", "PE/ELF/.NET binary to analyse"},
	{"--output OUTPUT", "New output directory (must not exist)"},
	{"--rules RULES", "capa rules directory (default: ~/.local/share/capa-rules)"},
	{"--timeout TIMEOUT", "Wall-clock timeout for capa (seconds, default 300)"},
	{"--max-capabilities MAX_CAPABILITIES", "Maximum capabilities sampled in the inventory (default 500)"},
}

// terminalWidth is argparse's formatter width: columns - 2, columns from $COLUMNS (positive integer) or 80.
func terminalWidth(columns string) int {
	n := 80
	if v, ok := parsePyInt(columns); ok && v.IsInt64() && v.Int64() > 0 {
		n = int(v.Int64())
	}
	return n - 2
}

// usageText is format_usage(): "usage: ..." wrapped to width, ending in one newline.
func usageText(width int) string {
	const prefix = "usage: "
	textWidth := max(width, 11)
	// argparse returns the one-line form when it fits; packing the parts greedily gives the same text then, so
	// there is no separate fast path. The first part of every line always fits (textWidth is at least 11).
	getLines := func(parts []string, indent string, withPrefix bool) []string {
		var lines, line []string
		lineLen := len(indent) - 1
		if withPrefix {
			lineLen = len(prefix) - 1
		}
		for _, p := range parts {
			if lineLen+1+len(p) > textWidth {
				lines = append(lines, indent+strings.Join(line, " "))
				line, lineLen = nil, len(indent)-1
			}
			line = append(line, p)
			lineLen += len(p) + 1
		}
		lines = append(lines, indent+strings.Join(line, " "))
		if withPrefix {
			lines[0] = lines[0][len(indent):]
		}
		return lines
	}
	var lines []string
	// len(prefix)+len(prog) <= 0.75*textWidth, as the smallest textWidth that satisfies it.
	if textWidth >= (4*(len(prefix)+len(prog))+2)/3 {
		lines = getLines(append([]string{prog}, usageParts...), strings.Repeat(" ", len(prefix)+len(prog)+1), true)
	} else {
		indent := strings.Repeat(" ", len(prefix))
		lines = append([]string{prog}, getLines(usageParts, indent, false)...)
	}
	return prefix + strings.Join(lines, "\n") + "\n"
}

// helpText is format_help().
func helpText(width int) string {
	var b strings.Builder
	b.WriteString(usageText(width))
	b.WriteString("\noptions:\n")
	helpPos := min(39, min(24, max(width-20, 4)))
	helpWidth := max(width-helpPos, 11)
	actionWidth := helpPos - 2 - 2
	for _, e := range helpEntries {
		lines := wrapText(e[1], helpWidth)
		header := "  " + e[0]
		if utf8.RuneCountInString(e[0]) <= actionWidth {
			b.WriteString(header + strings.Repeat(" ", actionWidth-utf8.RuneCountInString(e[0])+2))
		} else {
			b.WriteString(header + "\n" + strings.Repeat(" ", helpPos))
		}
		b.WriteString(lines[0] + "\n")
		for _, l := range lines[1:] {
			b.WriteString(strings.Repeat(" ", helpPos) + l + "\n")
		}
	}
	return b.String()
}

// wrapText is textwrap.wrap(text, width) with its defaults (whitespace and hyphen word breaks, long words
// broken, leading whitespace of a continuation line dropped).
func wrapText(text string, width int) []string {
	var chunks [][]rune
	words := strings.Fields(text)
	for i, w := range words {
		chunks = append(chunks, splitHyphens([]rune(w))...)
		if i < len(words)-1 {
			chunks = append(chunks, []rune(" "))
		}
	}
	var lines []string
	for len(chunks) > 0 {
		var cur [][]rune
		curLen := 0
		if string(chunks[0]) == " " {
			chunks = chunks[1:]
		}
		for len(chunks) > 0 && curLen+len(chunks[0]) <= width {
			cur = append(cur, chunks[0])
			curLen += len(chunks[0])
			chunks = chunks[1:]
		}
		if len(chunks) > 0 && len(chunks[0]) > width { // handle_long_word
			// width is at least 11 here. spaceLeft may be 0: textwrap then appends an empty piece and ends the line.
			spaceLeft := width - curLen
			end := spaceLeft
			chunk := chunks[0]
			// the chunk is longer than the width, so longer than spaceLeft: break after the last hyphen of the
			// space left when something other than hyphens precedes it (no hyphen, or one at index 0, finds none)
			s := string(chunk[:spaceLeft])
			if h := utf8.RuneCountInString(s[:max(strings.LastIndexByte(s, '-'), 0)]); anyNot(chunk[:h], '-') {
				end = h + 1
			}
			cur = append(cur, chunk[:end])
			chunks[0] = chunk[end:]
		}
		// cur is never empty here: a line starts with a word (leading spaces are dropped) and a word that does
		// not fit is broken by the long-word branch above.
		if n := len(cur); strings.TrimSpace(string(cur[n-1])) == "" {
			cur = cur[:n-1]
		}
		var b strings.Builder
		for _, c := range cur {
			b.WriteString(string(c))
		}
		lines = append(lines, b.String())
	}
	return lines
}

func anyNot(rs []rune, r rune) bool {
	for _, c := range rs {
		if c != r {
			return true
		}
	}
	return false
}

// splitHyphens cuts a word after a hyphen that follows two letters (or letter-hyphen-letter) and precedes a
// letter pair (textwrap's wordsep_re), keeping the hyphen with the left chunk. The em-dash alternative of that
// regexp (a word immediately followed by two or more hyphens) is not modelled: no help text has one.
func splitHyphens(rs []rune) [][]rune {
	letter := func(i int) bool { return i >= 0 && i < len(rs) && (unicode.IsLetter(rs[i]) || rs[i] == '_') }
	var out [][]rune
	start := 0
	for i := 1; i < len(rs); i++ {
		if rs[i] != '-' {
			continue
		}
		behind := letter(i-1) && letter(i-2) || letter(i-1) && letter(i-3) && rs[i-2] == '-'
		ahead := letter(i+1) && (letter(i+2) || letter(i+3) && rs[i+2] == '-')
		if behind && ahead {
			out = append(out, rs[start:i+1])
			start = i + 1
		}
	}
	return append(out, rs[start:])
}
