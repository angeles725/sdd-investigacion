package sweep

import (
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
)

// The marker of a breakthrough block and the drift pass over the ledger pointers.

// reMarker is the one recognized marker form: a header-blockquote line `^>[[:space:]]*\*\*Breakthrough:\*\*`.
// A prose "HITO", a bare "BREAKTHROUGH" or the word anywhere else in the line is not the marker.
var reMarker = regexp.MustCompile(`^>[ \t\n\v\f\r]*\*\*Breakthrough:\*\*`)

// fileLines are the lines of data as grep -n and sed -n number them: a final newline ends the last line.
func fileLines(data []byte) []string {
	if len(data) == 0 {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

// markerLines are the 1-based numbers of the lines of data that carry the marker, in order.
func markerLines(data []byte) []int {
	var out []int
	for i, l := range fileLines(data) {
		if reMarker.MatchString(l) {
			out = append(out, i+1)
		}
	}
	return out
}

// driftPass checks that every ledger pointer still points at the marker: the file exists, still carries it, and
// carries it on the pointed line. The pointers are checked in ledger order; a pointer repeated is reported again.
// A relative pointer is read against the caller's directory, as the script's cwd was.
func driftPass(out io.Writer, cwd string, pointers []string, read readFunc, t *btTotals) {
	for _, ptr := range pointers {
		file, digits := splitPointer(ptr)
		path := file
		if !strings.HasPrefix(path, "/") && cwd != "" {
			path = cwd + "/" + path
		}
		if !isRegularFile(path) {
			fmt.Fprintf(out, "WARN: drift — indexed block file no longer exists: %s (from BREAKTHROUGHS.md)\n", file)
			t.drift++
			continue
		}
		data, err := read(path)
		if err != nil {
			fmt.Fprintf(out, "WARN: drift check skipped — indexed block file unreadable: %s (from BREAKTHROUGHS.md)\n", ptr)
			t.markUnreadable(file)
			continue
		}
		marks := markerLines(data)
		switch {
		case len(marks) == 0:
			fmt.Fprintf(out, "WARN: drift — indexed block no longer carries the **Breakthrough:** marker: %s (from BREAKTHROUGHS.md)\n", ptr)
			t.drift++
		case !carriesMarker(data, digits):
			fmt.Fprintf(out, "WARN: drift — indexed line does not carry the **Breakthrough:** marker (block still has it elsewhere): %s (from BREAKTHROUGHS.md)\n", ptr)
			t.drift++
		}
	}
}

// carriesMarker is `sed -n "${n}p" f | grep -E marker`: line n (digits, 1-based) of data carries the marker. Line
// 0 and a line past the end are no line, as for sed.
func carriesMarker(data []byte, digits string) bool {
	at, err := strconv.Atoi(trimZeros(digits)) // an overflow is far past any file: sed prints nothing
	if err != nil {
		return false
	}
	lines := fileLines(data)
	return at >= 1 && at <= len(lines) && reMarker.MatchString(lines[at-1])
}
