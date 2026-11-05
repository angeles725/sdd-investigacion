package srcregistry

import "strings"

// spaceChars is awk's [[:space:]]; cellTrim is the set the legacy cell trim removed (space and tab only).
const (
	spaceChars = " \t\n\v\f\r"
	cellTrim   = " \t"
)

// splitLines splits md into records the way awk reads them: on "\n", no empty record after a final newline.
func splitLines(md []byte) []string {
	if len(md) == 0 {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(md), "\n"), "\n")
}

// joinLines is the inverse: every record, the last one included, ends with "\n" (awk's ORS).
func joinLines(ls []string) []byte {
	var b strings.Builder
	for _, l := range ls {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	return []byte(b.String())
}

// isRow is awk's /^[[:space:]]*\|/.
func isRow(l string) bool { return strings.HasPrefix(strings.TrimLeft(l, spaceChars), "|") }

// cells returns the first seven "|"-separated fields of l, trimmed; index 0 is the text before the first "|".
func cells(l string) [7]string {
	var c [7]string
	for i, p := range strings.Split(l, "|") {
		if i >= len(c) {
			break
		}
		c[i] = strings.Trim(p, cellTrim)
	}
	return c
}
