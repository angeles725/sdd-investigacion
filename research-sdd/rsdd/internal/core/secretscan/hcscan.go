package secretscan

import "bytes"

// hcHit is one high-confidence match. Match is the matched text: a dedup key, never printed (a verdict that echoed
// the value would itself leak it). Content is the whole line, kept only for the committed-history report.
type hcHit struct {
	Rule    int
	Line    int
	Match   string
	Content string
}

var newline = []byte{'\n'}

func containsAny(data []byte, literals []string) bool {
	for _, l := range literals {
		if bytes.Contains(data, []byte(l)) {
			return true
		}
	}
	return false
}

// lineAt returns the line of data that holds pos (without its newline).
func lineAt(data []byte, pos int) []byte {
	start, end := lineBounds(data, pos)
	return data[start:end]
}

// lineBounds is the [start, end) of the line of data that holds pos, newline excluded.
func lineBounds(data []byte, pos int) (int, int) {
	rest, _, _ := bytes.Cut(data[pos:], newline)
	return bytes.LastIndexByte(data[:pos], '\n') + 1, pos + len(rest)
}

// scanHC returns every match of every rule, rule by rule and in file order, as `grep -o` prints them: each match is
// its own hit, so a line with two tokens yields two hits. No pattern can span a newline, so one pass over the buffer
// equals a pass over its lines.
func scanHC(data []byte, keepContent bool) []hcHit {
	var hits []hcHit
	for i := range rules {
		r := &rules[i]
		if !containsAny(data, r.Literals) {
			continue
		}
		line, last := 1, 0
		for _, loc := range r.re.FindAllIndex(data, -1) {
			line += bytes.Count(data[last:loc[0]], newline)
			last = loc[0]
			h := hcHit{Rule: i, Line: line, Match: string(data[loc[0]:loc[1]])}
			if keepContent {
				h.Content = string(lineAt(data, loc[0]))
			}
			hits = append(hits, h)
		}
	}
	return hits
}

// mergeHits appends the hits of extra that base does not already hold (same rule, line and match text).
func mergeHits(base, extra []hcHit) []hcHit {
	type key struct {
		rule, line int
		match      string
	}
	seen := make(map[key]bool, len(base))
	for _, h := range base {
		seen[key{h.Rule, h.Line, h.Match}] = true
	}
	for _, h := range extra {
		if k := (key{h.Rule, h.Line, h.Match}); !seen[k] {
			seen[k] = true
			base = append(base, h)
		}
	}
	return base
}
