package grammar

import (
	"fmt"
	"strings"
)

// defence is retro_grammar_defenced (kit issues #1356, #1369): raw minus every CLOSED fenced code block, plus the
// 1-based line of a fence still open at EOF (0 when none). CommonMark fence rules as the bash lib applies them:
//   - a fence OPENS on 3+ backticks or tildes indented at most 3 spaces; a backtick opener whose info string holds
//     a backtick is inline code, not a fence;
//   - a line indented 4+ spaces (or by a tab after up to 3 spaces) is indented code: it neither opens nor closes;
//   - it CLOSES on a run of the SAME character, at least as long as the opener, followed only by blanks or CR;
//   - an unclosed fence is NOT a fence (its lines stay, so real entries never become a silent zero); the caller
//     reports it with FenceWarning.
func defence(raw []string) ([]string, int) {
	skip := make([]bool, len(raw))
	open, start, fch, flen := false, 0, byte(0), 0
	for i, line := range raw {
		if indent(line) >= 4 { // RETRO_GRAMMAR_FENCE_INDENT
			continue
		}
		s := strings.TrimLeft(line, " ")
		if s == "" {
			continue
		}
		c := s[0]
		n := runLen(s, c)
		rest := s[n:]
		switch {
		case !open && (c == '`' || c == '~') && n >= 3 && !(c == '`' && strings.Contains(rest, "`")):
			open, start, fch, flen = true, i, c, n
		case open && c == fch && n >= flen && strings.Trim(rest, " \t\r") == "": // RETRO_GRAMMAR_FENCE_CLOSER
			for k := start; k <= i; k++ {
				skip[k] = true
			}
			open = false
		}
	}
	kept := make([]string, 0, len(raw))
	for i, line := range raw {
		if !skip[i] {
			kept = append(kept, line)
		}
	}
	if open {
		return kept, start + 1
	}
	return kept, 0
}

// indent is the awk indent(): leading spaces, plus 4 when a tab follows them.
func indent(s string) int {
	n := runLen(s, ' ')
	if n < len(s) && s[n] == '\t' {
		n += 4
	}
	return n
}

// runLen counts the leading bytes of s equal to c.
func runLen(s string, c byte) int {
	n := 0
	for n < len(s) && s[n] == c {
		n++
	}
	return n
}

// FenceWarning is the stderr line retro_grammar_defenced prints for an unclosed fence, "" when there is none.
// Bash prints it on a consumer's first read only (_RG_QUIET_FENCE=1 silences the secondary reads); a Go caller
// reads once and prints it once.
func (d *Doc) FenceWarning() string {
	if d.UnclosedFence == 0 {
		return ""
	}
	return fmt.Sprintf("WARN: unclosed code fence opened at line %d in %s — treated as text\n", d.UnclosedFence, d.Path)
}
