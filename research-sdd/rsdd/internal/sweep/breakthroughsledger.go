package sweep

import (
	"regexp"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// The pointers of BREAKTHROUGHS.md (METHODOLOGY section 22): the block `path:line` tokens of the "how" column of
// the ledger table | # | target | what (cracked) | how — block `path:line` | memory — engram topic-key |.

// reCellPointer is the awk match(rest, /`[^`]+:[0-9]+`/): a backtick-wrapped path:digits token.
var reCellPointer = regexp.MustCompile("`[^`]+:[0-9]+`")

const asciiSpace = " \t\n\v\f\r"

// researchHomeOf is `${RESEARCH_HOME:-$HOME}` without one trailing slash, the root of the portable pointers. It
// is read out of core/kit's own expansion of a TARGETS.md token, so there is one definition of it.
func researchHomeOf(getenv kit.Getenv) string {
	paths := kit.PathsAll("| `$RESEARCH_HOME/x` |\n", getenv)
	if len(paths) != 1 {
		return ""
	}
	return strings.TrimSuffix(paths[0], "/x")
}

// ledgerPointers is the pointer of every backtick-wrapped path:line token of the fourth cell of every ledger
// row, in order, with the portable $RESEARCH_HOME forms expanded against rh. The header, the separator rows and
// the skeleton row (first cell "#", a dash or empty) hold none.
func ledgerPointers(data []byte, rh string) []string {
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "|") || reLedgerSeparator.MatchString(line) {
			continue
		}
		cells := strings.Split(line, "|") // awk -F'|': cells[1] is $2, cells[4] is $5
		if len(cells) < 5 {
			continue
		}
		switch strings.Trim(cells[1], asciiSpace) {
		case "#", "—", "-", "":
			continue
		}
		rest := cells[4]
		for {
			loc := reCellPointer.FindStringIndex(rest)
			if loc == nil {
				break
			}
			ptr := rest[loc[0]+1 : loc[1]-1]
			rest = rest[loc[1]:]
			if r, ok := strings.CutPrefix(ptr, "${RESEARCH_HOME}/"); ok {
				ptr = rh + "/" + r
			} else if r, ok := strings.CutPrefix(ptr, "$RESEARCH_HOME/"); ok {
				ptr = rh + "/" + r
			}
			out = append(out, ptr)
		}
	}
	return out
}

// splitPointer cuts a pointer at its last colon: the file and the line digits.
func splitPointer(ptr string) (file, line string) {
	i := strings.LastIndexByte(ptr, ':')
	return ptr[:i], ptr[i+1:]
}

// trimZeros is the number a digit string spells: leading zeros dropped, "0" kept.
func trimZeros(digits string) string {
	if d := strings.TrimLeft(digits, "0"); d != "" {
		return d
	}
	return "0"
}

// pointerIndex answers "does the ledger point at this marker line".
type pointerIndex struct {
	keys map[string]bool
}

func newPointerIndex(pointers []string) pointerIndex {
	ix := pointerIndex{keys: map[string]bool{}}
	for _, p := range pointers {
		f, l := splitPointer(p)
		ix.keys[f+":"+trimZeros(l)] = true
	}
	return ix
}

// indexes reports whether the ledger points at any of the marker lines of the block file bf.
func (ix pointerIndex) indexes(bf string, lines []int) bool {
	for _, n := range lines {
		if ix.keys[bf+":"+strconv.Itoa(n)] {
			return true
		}
	}
	return false
}
