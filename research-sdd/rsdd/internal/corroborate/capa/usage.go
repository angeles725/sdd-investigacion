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
	oneLine := prog + " " + strings.Join(usageParts, " ")
	if utf8.RuneCountInString(prefix)+utf8.RuneCountInString(oneLine) <= textWidth {
		return prefix + oneLine + "\n"
	}
	getLines := func(parts []string, indent string, withPrefix bool) []string {
		var lines, line []string
		lineLen := len(indent) - 1
		if withPrefix {
			lineLen = len(prefix) - 1
		}
		for _, p := range parts {
			if lineLen+1+len(p) > textWidth && len(line) > 0 {
				lines = append(lines, indent+strings.Join(line, " "))
				line, lineLen = nil, len(indent)-1
			}
			line = append(line, p)
			lineLen += len(p) + 1
		}
		if len(line) > 0 {
			lines = append(lines, indent+strings.Join(line, " "))
		}
		if withPrefix {
			lines[0] = lines[0][len(indent):]
		}
		return lines
	}
	var lines []string
	if float64(len(prefix)+len(prog)) <= 0.75*float64(textWidth) {
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
	for i, w := range strings.Fields(text) {
		if i > 0 {
			chunks = append(chunks, []rune(" "))
		}
		chunks = append(chunks, splitHyphens([]rune(w))...)
	}
	var lines []string
	for len(chunks) > 0 {
		var cur [][]rune
		curLen := 0
		if string(chunks[0]) == " " && len(lines) > 0 {
			chunks = chunks[1:]
		}
		for len(chunks) > 0 && curLen+len(chunks[0]) <= width {
			cur = append(cur, chunks[0])
			curLen += len(chunks[0])
			chunks = chunks[1:]
		}
		if len(chunks) > 0 && len(chunks[0]) > width { // handle_long_word
			spaceLeft := max(width-curLen, 1)
			end := spaceLeft
			chunk := chunks[0]
			if len(chunk) > spaceLeft {
				if h := lastIndexRune(chunk[:spaceLeft], '-'); h > 0 && anyNot(chunk[:h], '-') {
					end = h + 1
				}
			}
			cur = append(cur, chunk[:end])
			chunks[0] = chunk[end:]
		}
		if n := len(cur); n > 0 && string(cur[n-1]) == " " {
			cur = cur[:n-1]
		}
		if len(cur) > 0 {
			var b strings.Builder
			for _, c := range cur {
				b.WriteString(string(c))
			}
			lines = append(lines, b.String())
		}
	}
	return lines
}

func lastIndexRune(rs []rune, r rune) int {
	for i := len(rs) - 1; i >= 0; i-- {
		if rs[i] == r {
			return i
		}
	}
	return -1
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
// letter pair (textwrap's wordsep_re), keeping the hyphen with the left chunk.
func splitHyphens(rs []rune) [][]rune {
	letter := func(i int) bool { return i >= 0 && i < len(rs) && (unicode.IsLetter(rs[i]) || rs[i] == '_') }
	var out [][]rune
	start := 0
	for i := 1; i < len(rs); i++ {
		if rs[i] != '-' {
			continue
		}
		behind := letter(i-1) && letter(i-2) || letter(i-1) && i >= 3 && rs[i-2] == '-' && letter(i-3)
		ahead := letter(i+1) && (letter(i+2) || i+3 < len(rs) && rs[i+2] == '-' && letter(i+3))
		if behind && ahead {
			out = append(out, rs[start:i+1])
			start = i + 1
		}
	}
	return append(out, rs[start:])
}
