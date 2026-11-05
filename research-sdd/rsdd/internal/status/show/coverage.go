package show

import (
	"regexp"
	"strings"
)

// covLine is one `covers_through:` line of a retro, as the CV awk grammar of the script classifies it: a valid
// B<n> (n at most nine digits) with the focus slug it names ("-" when unscoped), or a malformed line.
type covLine struct {
	n         int
	slug      string
	malformed bool
}

// covLineRE is `^covers_through:[ \t]+B[0-9]+([ \t]+focus=[A-Za-z0-9._-]+)?[ \t]*$`.
var covLineRE = regexp.MustCompile(`^covers_through:[ \t]+B([0-9]+)(?:[ \t]+focus=([A-Za-z0-9._-]+))?[ \t]*$`)

// coverageLines is `awk "$_CV_AWK" retro` (the grammar shared with stage-retro-issues.sh). A fence line (``` or ~~~
// at column 0) opens a fence of its marker and only the same marker closes it; nothing inside a fence counts. A
// `covers_through:` line at column 0, with a trailing CR dropped, is valid only in the exact form above.
func coverageLines(src string) []covLine {
	var out []covLine
	fence := byte(0)
	for _, rec := range strings.Split(src, "\n") {
		if strings.HasPrefix(rec, "```") || strings.HasPrefix(rec, "~~~") {
			switch m := rec[0]; fence {
			case 0:
				fence = m
			case m:
				fence = 0
			}
			continue
		}
		if fence != 0 || !strings.HasPrefix(rec, "covers_through:") {
			continue
		}
		m := covLineRE.FindStringSubmatch(strings.TrimSuffix(rec, "\r"))
		switch {
		case m == nil || len(m[1]) > 9:
			out = append(out, covLine{malformed: true})
		default:
			n := 0
			for _, d := range m[1] {
				n = n*10 + int(d-'0')
			}
			slug := m[2]
			if slug == "" {
				slug = "-"
			}
			out = append(out, covLine{n: n, slug: slug})
		}
	}
	return out
}
