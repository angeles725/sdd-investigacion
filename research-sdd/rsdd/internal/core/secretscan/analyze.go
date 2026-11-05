package secretscan

import (
	"bytes"
	"regexp"
	"sort"
)

// advHit is one advisory line: a credential-looking assignment (the value is never kept).
type advHit struct {
	Line    int
	Content string
}

// analysis is everything one buffer (a file or a committed blob) yields.
type analysis struct {
	HC  []hcHit
	Adv []advHit
	NUL bool // the buffer holds a NUL byte
}

// keywordCandidate finds the lines worth the exact advisory matcher; the exact matcher decides.
var keywordCandidate = regexp.MustCompile(`(?i)password|passwd|secret|api[_-]?key|apikey|token`)

// analyzeOpts say which scans run on a buffer.
type analyzeOpts struct {
	keepContent bool // keep the whole matching line (the committed report sorts and dedups on it)
	// advisoryOnNUL runs the advisory scan on a buffer with a NUL byte. The legacy working-tree scan skipped such
	// a file entirely (grep -I) and reported it as binary-skipped; committed blobs were always scanned raw.
	advisoryOnNUL bool
}

// analyze runs the high-confidence rules over the buffer, again over its NUL-stripped form (UTF-16 and UTF-32 text
// has NULs between the ASCII letters of a token, so the raw scan cannot see it; stripping NULs from text without
// NULs is a no-op), and the advisory scan.
func analyze(data []byte, o analyzeOpts) analysis {
	a := analysis{HC: scanHC(data, o.keepContent), NUL: bytes.IndexByte(data, 0) >= 0}
	if a.NUL {
		a.HC = mergeHits(a.HC, scanHC(bytes.ReplaceAll(data, []byte{0}, nil), o.keepContent))
		sort.SliceStable(a.HC, func(i, j int) bool {
			if a.HC[i].Rule != a.HC[j].Rule {
				return a.HC[i].Rule < a.HC[j].Rule
			}
			return a.HC[i].Line < a.HC[j].Line
		})
	}
	if !a.NUL || o.advisoryOnNUL {
		a.Adv = scanAdvisory(data, o.keepContent)
	}
	return a
}

// scanAdvisory returns the lines whose first keyword assignment carries a real-looking literal value.
func scanAdvisory(data []byte, keepContent bool) []advHit {
	var hits []advHit
	line, last, lastLineEnd := 1, 0, -1
	for _, loc := range keywordCandidate.FindAllIndex(data, -1) {
		if loc[0] < lastLineEnd { // another keyword on a line already judged
			continue
		}
		start := bytes.LastIndexByte(data[:loc[0]], '\n') + 1
		end := len(data)
		if i := bytes.IndexByte(data[loc[0]:], '\n'); i >= 0 {
			end = loc[0] + i
		}
		lastLineEnd = end + 1
		content := data[start:end]
		line += bytes.Count(data[last:start], newline)
		last = start
		val, ok := advisoryValue(content)
		if !ok || !acceptValue(val, content) {
			continue
		}
		h := advHit{Line: line}
		if keepContent {
			h.Content = string(content)
		}
		hits = append(hits, h)
	}
	return hits
}
