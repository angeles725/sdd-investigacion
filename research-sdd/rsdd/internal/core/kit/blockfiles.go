package kit

import (
	"errors"
	"regexp"
	"strings"
)

// Typed outcomes of FilterBlockFiles (grep's 1 and 2). An empty stream and a stream with no canonical block file
// are distinct states here; bash returns 1 for both.
var (
	ErrNoMatch    = errors.New("kit: no match")
	ErrEmptyInput = errors.New("kit: empty input")
	// ErrBadPattern: the focus prefix made the ERE invalid (grep exits 2). The prefix is interpolated unescaped,
	// exactly as lib/block-files.sh does.
	ErrBadPattern = errors.New("kit: bad pattern")
)

// The block-file ERE of lib/block-files.sh, with or without a focus prefix (THE one definition, kit U11).
const (
	blockTail     = `(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$`
	blockNoPrefix = `(^|/)[^/]+-` + blockTail
)

var reBlock = regexp.MustCompilePOSIX(blockNoPrefix)

// FilterBlockFiles is `block_file_filter [-v] [<prefix>]` over lines: the lines whose basename is a canonical block
// file (invert: the lines that are NOT). The prefix, when non-empty, is a raw ERE fragment anchored after (^|/).
//
// Outcomes: matches and nil (rc 0); ErrEmptyInput for no lines and ErrNoMatch for no selected line (rc 1);
// ErrBadPattern for a prefix grep rejects (rc 2). The `[ -t 0 ]` interactive-stdin refusal is the caller's: the
// lines are already read. Regex dialect: Go POSIX ERE, equal to GNU `grep -E` under LC_ALL=C for the
// prefixes the kit derives (DEFERRED.md lists the escapes where the two dialects part).
func FilterBlockFiles(lines []string, invert bool, prefix string) ([]string, error) {
	re := reBlock
	if prefix != "" {
		var err error
		if re, err = regexp.CompilePOSIX(`(^|/)` + prefix + blockTail); err != nil {
			return nil, ErrBadPattern
		}
	}
	if len(lines) == 0 {
		return nil, ErrEmptyInput
	}
	var out []string
	for _, l := range lines {
		if re.MatchString(l) != invert {
			out = append(out, l)
		}
	}
	if len(out) == 0 {
		return nil, ErrNoMatch
	}
	return out, nil
}

// SplitLines splits a stream into lines the way grep and `read` see them: a trailing newline ends the last line,
// a final fragment without one is still a line, and an empty stream has none.
func SplitLines(src string) []string {
	if src == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(src, "\n"), "\n")
}
