package gaprows

import "strings"

var stopWords = func() map[string]struct{} {
	m := map[string]struct{}{}
	for _, w := range strings.Fields("an the of to in on for and or vs via is are be by with from at as it its this that whether which what why how not no any all full real exact own other") {
		m[w] = struct{}{}
	}
	return m
}()

// words is the set of content words of text: ASCII-lowercased runs `[a-z][a-z0-9_.]+`, stripped of ONE trailing "s"
// when longer than three bytes and not ending in "ss" (months = month), kept when at least three bytes long and not a
// stop word. Digit-initial tokens (9.5.0, 1166) are invisible to the measure; that is a documented limit.
func words(text string) map[string]struct{} {
	set := map[string]struct{}{}
	for i := 0; i < len(text); {
		if !isLetter(text[i]) {
			i++
			continue
		}
		j := i + 1
		for j < len(text) && isWordByte(text[j]) {
			j++
		}
		if j == i+1 { // a lone letter is not a word
			i++
			continue
		}
		w := lower(text[i:j])
		i = j
		if n := len(w); n > 3 && w[n-1] == 's' && w[n-2] != 's' {
			w = w[:n-1]
		}
		if _, stop := stopWords[w]; len(w) >= 3 && !stop {
			set[w] = struct{}{}
		}
	}
	return set
}

// Overlap is gap_overlap: how many content words of the row also occur in the bullet (shared) out of the row's
// content words (total). total == 0 means the row carries no comparable word; the caller must not call that drift.
func Overlap(row, bullet string) (shared, total int) {
	rw, bw := words(row), words(bullet)
	for w := range rw {
		total++
		if _, ok := bw[w]; ok {
			shared++
		}
	}
	return shared, total
}

func isLetter(c byte) bool   { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }
func isWordByte(c byte) bool { return isLetter(c) || c >= '0' && c <= '9' || c == '_' || c == '.' }

func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}
