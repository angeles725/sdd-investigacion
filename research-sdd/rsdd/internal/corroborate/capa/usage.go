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

// wrapText is textwrap.wrap(text, width) with its default word separators (whitespace and hyphens).
func wrapText(text string, width int) []string {
	var lines []string
	cur, glue := "", false
	for _, w := range strings.Fields(text) {
		pieces := splitHyphens(w)
		for i, c := range pieces {
			sep := " "
			if glue {
				sep = ""
			}
			if cur == "" {
				cur = c
			} else if utf8.RuneCountInString(cur)+len(sep)+utf8.RuneCountInString(c) <= width {
				cur += sep + c
			} else {
				lines = append(lines, cur)
				cur = c
			}
			glue = i < len(pieces)-1
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	return lines
}

// splitHyphens cuts a word after a hyphen that sits between two letters (textwrap's wordsep_re), keeping
// the hyphen with the left part.
func splitHyphens(w string) []string {
	rs := []rune(w)
	var out []string
	start := 0
	isWord := func(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' }
	for i := 1; i < len(rs)-1; i++ {
		if rs[i] != '-' || !(isWord(rs[i-1]) && !unicode.IsDigit(rs[i-1])) {
			continue
		}
		j := i + 1
		for j < len(rs) && isWord(rs[j]) {
			j++
		}
		run := rs[i+1 : j]
		ok := false
		for k := 1; k < len(run); k++ {
			if !unicode.IsDigit(run[k]) {
				ok = true
			}
		}
		if ok {
			out = append(out, string(rs[start:i+1]))
			start = i + 1
		}
	}
	return append(out, string(rs[start:]))
}
