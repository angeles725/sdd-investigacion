package sweep

import (
	"bytes"
	"io/fs"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// The directory walk and the claim count of sweep-audits.sh. The walk is the `find` of the retro pass (walkRaw,
// isIndexName and notGitPath are shared with it): readdir order, symbolic links listed and never entered.

// reClaimRow is `grep -cE '^\| *[0-9]+ \|'`: a table row that opens with a number, one blank before its pipe.
var reClaimRow = regexp.MustCompile(`^\| *[0-9]+ \|`)

// inAuditsPath is `-path '*/audits/*.md'`: fnmatch without FNM_PATHNAME, so each `*` also crosses slashes and the
// whole path (the target prefix included) is matched. The FIRST "/audits/" leaves the longest remainder, so it
// decides. The ".md" of the pattern always fits in that remainder: "/audits/" ends in a slash, so a path that ends
// in ".md" cannot overlap it (pinned by TestAuditsInAuditsPath, which has the bare "/audits/.md").
func inAuditsPath(path string) bool {
	return strings.Contains(path, "/audits/") && strings.HasSuffix(path, ".md")
}

// findAudits is `find P -maxdepth 4 -path '*/audits/*.md' -not -path '*/.git/*' -not -iname '*index*.md'`.
// An index or manifest file is a generated table of contents, not an audit report.
func findAudits(p string) []string {
	var out []string
	walkRaw(p, 4, func(path string, _ fs.FileMode) {
		if inAuditsPath(path) && notGitPath(path) && !isIndexName(path) {
			out = append(out, path)
		}
	})
	return out
}

// countClaims is the number of lines of data that are claim rows. A last line without a newline is a line.
func countClaims(data []byte) int {
	n := 0
	for _, line := range bytes.Split(data, []byte("\n")) {
		if reClaimRow.Match(line) {
			n++
		}
	}
	return n
}

// auditClaims is `claims=$(grep -cE ... "$f" 2>/dev/null)` followed by ${claims:-?}: grep prints 0 for a directory
// and nothing at all for a file it cannot open, which reads as "?" (the count is unknown, not zero).
func auditClaims(f string) string {
	if st, err := os.Stat(f); err == nil && st.IsDir() {
		return "0"
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return "?"
	}
	return strconv.Itoa(countClaims(b))
}
