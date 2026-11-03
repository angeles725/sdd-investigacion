package sweep

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// targetList is what a sweep reads out of the kit's TARGETS.md: the paths it can walk, and the truncated
// ones (a "..." in the path) it must name as skipped.
type targetList struct {
	usable  []string
	skipped []string
}

// targetsError is a sweep that cannot start (no TARGETS.md, no usable path): an operational failure whose
// message is the exact stderr text.
type targetsError struct{ lines []string }

func (e *targetsError) Error() string { return strings.Join(e.lines, "\n") }

// readTargetList reads <kitDir>/TARGETS.md for the sweep called name (its diagnostic prefix). A missing or
// non-regular file and a file with no usable path are errors that carry the exact stderr lines.
func readTargetList(name, kitDir string, getenv kit.Getenv) (targetList, error) {
	md := kitDir + "/TARGETS.md"
	if st, err := os.Stat(md); err != nil || !st.Mode().IsRegular() {
		return targetList{}, &targetsError{[]string{fmt.Sprintf("%s: cannot find %s", name, md)}}
	}
	src, _ := kit.ReadTargets(md) // an unreadable file reads as no paths, like the scripts' silent grep
	var t targetList
	for _, p := range kit.PathsAll(src, getenv) {
		if strings.Contains(p, "...") {
			t.skipped = append(t.skipped, p)
		} else {
			t.usable = append(t.usable, p)
		}
	}
	if len(t.usable) == 0 {
		return targetList{}, &targetsError{[]string{
			fmt.Sprintf("%s: ERROR — no usable target paths in %s", name, md),
			fmt.Sprintf("%s: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths", name),
		}}
	}
	return t, nil
}

// printTo writes the error lines of a failed start.
func (e *targetsError) printTo(w io.Writer) {
	for _, l := range e.lines {
		fmt.Fprintln(w, l)
	}
}

// words is `for p in $paths`: the usable paths split on whitespace.
func (t targetList) words() []string { return strings.Fields(strings.Join(t.usable, "\n")) }
