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

// The block-file ERE of lib/block-files.sh, with or without a focus prefix (THE one definition, kit U11). The slug
// class is the only part that differs between the two locales the kit's scripts ran under: lib/block-files.sh
// is C-locale (blockSlugC); verify-block's awk ran under the caller's UTF-8 locale (blockSlugUnicode, kit #2600:
// kept as a pinned variant, see BlockFileNameUnicode). Both are derived from blockTail below.
const (
	blockSlugC       = `[[:alnum:]_-]`
	blockSlugUnicode = `[\p{L}\p{N}_-]`
)

// blockTailFor is the tail of the ERE for one slug class: `(block|bloque)<N>[-slug].md` at the end of the line.
// num is the number class: the C-locale tail must stay byte-identical to the grep ERE (the focus prefix is
// interpolated unescaped in front of it, so an extra group would change how a stray `[` in a prefix parses); the
// Unicode variants capture the number. Capture groups there: the kind, the number, the slug (with its dash).
func blockTailFor(slug, num string) string {
	return `(block|bloque)` + num + `(-` + slug + `+)?\.md$`
}

var (
	blockTail     = blockTailFor(blockSlugC, `[0-9]+`)
	blockNoPrefix = `(^|/)[^/]+-` + blockTail
)

// BlockFileNameUnicode matches a block file's basename with a Unicode slug: groups are the optional prefix (with its
// trailing dash), the kind, the number and the slug. Leftmost-longest, like the awk it replaces.
var BlockFileNameUnicode = unicodeRE(`^(.*-)?` + blockTailFor(blockSlugUnicode, `([0-9]+)`))

// BlockPathUnicode matches a path whose last element is a canonical block file with a Unicode slug.
var BlockPathUnicode = unicodeRE(`(^|/)[^/]+-` + blockTailFor(blockSlugUnicode, `([0-9]+)`))

func unicodeRE(p string) *regexp.Regexp {
	r := regexp.MustCompile(p)
	r.Longest()
	return r
}

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
