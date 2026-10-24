package kit

import (
	"path/filepath"
	"regexp"
	"strings"
)

// Port of toolbelt/lib/focus-prefix.sh derive_focus_prefix (METHODOLOGY §16).
//
// It reads FOCUSES.md with `awk -F'|'` on lines that start with a pipe at column 0, NOT with core/gfm: every pipe
// splits (an escaped `\|` too) and a row indented by a blank is not a row. Cells are awk fields: fields[0] is
// the text before the first pipe, so the state-file cell is $4 = fields[3].

// PrefixSource is where DeriveFocusPrefix found its value, or why it found none.
type PrefixSource int

const (
	PrefixNotState    PrefixSource = iota // the basename is neither RESEARCH-STATE.md nor RESEARCH-STATE-<focus>.md
	PrefixFromName                        // RESEARCH-STATE-<focus>.md: "<focus>-"
	PrefixNoFocuses                       // RESEARCH-STATE.md without a sibling FOCUSES.md
	PrefixNoRow                           // FOCUSES.md has no root row with a prefix-shaped cell
	PrefixFromFocuses                     // the root row's "Block prefix" cell
)

// FocusPrefix is the block filename prefix of a state file; Value is "" unless Source is PrefixFromName or
// PrefixFromFocuses (an empty prefix means "count every block", correct for a single-focus corpus).
type FocusPrefix struct {
	Value  string
	Source PrefixSource
}

// DeriveFocusPrefix is derive_focus_prefix. Bash prints the filename form without a newline and the FOCUSES.md
// form with one (callers read both through $(...)). An unreadable FOCUSES.md is ErrUnreadable where bash lets awk
// complain on stderr and still prints nothing (DEFERRED.md, finding F9).
func DeriveFocusPrefix(sf string) (FocusPrefix, error) {
	base := filepath.Base(sf)
	if base == "RESEARCH-STATE.md" {
		return prefixFromFocuses(bashDirname(sf) + "/FOCUSES.md")
	}
	if slug, ok := strings.CutPrefix(base, "RESEARCH-STATE-"); ok && strings.HasSuffix(slug, ".md") {
		return FocusPrefix{strings.TrimSuffix(slug, ".md") + "-", PrefixFromName}, nil
	}
	return FocusPrefix{Source: PrefixNotState}, nil
}

func prefixFromFocuses(fm string) (FocusPrefix, error) {
	src, err := readRegular(fm)
	if err == ErrAbsentInput {
		return FocusPrefix{Source: PrefixNoFocuses}, nil
	} else if err != nil {
		return FocusPrefix{}, err
	}
	for _, line := range SplitLines(src) {
		f := strings.Split(line, "|")
		if !strings.HasPrefix(line, "|") || stateCell(f) != "RESEARCH-STATE.md" {
			continue
		}
		if bp := cutBlockPattern(strings.Trim(awkField(f, 5), "\t `")); isPrefixShaped(bp) {
			return FocusPrefix{bp, PrefixFromFocuses}, nil
		}
	}
	return FocusPrefix{Source: PrefixNoRow}, nil
}

var reBlockPattern = regexp.MustCompile(`block[A-Za-z0-9]*\.md`)

// awkField is awk's $i (1-based) over the pipe-split fields: "" past NF.
func awkField(f []string, i int) string {
	if i < 1 || i > len(f) {
		return ""
	}
	return f[i-1]
}

// stateCell is the state-file cell ($4) both awks read: blanks and backticks trimmed, and a `[name](link)` cell
// reduced to the text before the first `]` (no `]` at all gives "").
func stateCell(f []string) string {
	c := strings.Trim(awkField(f, 4), "\t `")
	if rest, ok := strings.CutPrefix(c, "["); ok {
		i := strings.Index(rest, "]")
		if i < 0 {
			i = 0
		}
		c = rest[:i]
	}
	return c
}

// cutBlockPattern is `sub(/block[A-Za-z0-9]*\.md.*/, "")`: a file-pattern cell such as `cob-block<N>.md` keeps
// what precedes its first block…\.md.
func cutBlockPattern(s string) string {
	if loc := reBlockPattern.FindStringIndex(s); loc != nil {
		return s[:loc[0]]
	}
	return s
}

// isPrefixShaped is `bp ~ /^[A-Za-z]/ && bp ~ /-$/`.
func isPrefixShaped(s string) bool {
	return s != "" && isASCIILetter(s[0]) && strings.HasSuffix(s, "-")
}

func isASCIILetter(b byte) bool { return b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z' }

// bashDirname is dirname(1): trailing slashes are dropped before and after the last component is cut.
func bashDirname(path string) string {
	p := strings.TrimRight(path, "/")
	i := strings.LastIndex(p, "/")
	switch {
	case p == "" && path != "":
		return "/"
	case i < 0:
		return "."
	}
	if d := strings.TrimRight(p[:i], "/"); d != "" {
		return d
	}
	return "/"
}
