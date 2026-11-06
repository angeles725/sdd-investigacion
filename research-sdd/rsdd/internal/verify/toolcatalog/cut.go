package toolcatalog

// cutBytes is `cut -c1-<n> | <drop an incomplete UTF-8 sequence at the end>`: the first n bytes of line, and when
// they end inside a multi-byte character, without that character's leading bytes. cut counts bytes, so it can split
// a character; the incomplete tail is dropped by a sed over the bytes of that cut.
func cutBytes(line string, n int) string {
	line = line[:min(len(line), n)]
	return line[:completeLen(line)]
}

// completeLen is the length of the longest prefix of s that does not end in an incomplete UTF-8 sequence: a lead
// byte with too few continuation bytes after it, within the last three bytes. The leftmost such start is cut, as
// the sed expression `([\xC0-\xDF]|[\xE0-\xEF][\x80-\xBF]?|[\xF0-\xF7][\x80-\xBF]{0,2})$` does.
func completeLen(s string) int {
	for i := max(0, len(s)-3); i < len(s); i++ {
		if incompleteAt(s, i) {
			return i
		}
	}
	return len(s)
}

// incompleteAt reports whether s[i:] is a lead byte followed by fewer continuation bytes than its sequence needs
// (and by nothing else).
func incompleteAt(s string, i int) bool {
	most, isLead := continuationsAdmitted(s[i])
	if !isLead {
		return false
	}
	rest := s[i+1:]
	if len(rest) > most {
		return false
	}
	for j := 0; j < len(rest); j++ {
		if rest[j] < 0x80 || rest[j] > 0xBF {
			return false
		}
	}
	return true
}

// continuationsAdmitted is how many continuation bytes a lead byte may have after it and still be cut as incomplete
// (the sequence length minus the lead, minus one), and whether b is a lead byte at all.
func continuationsAdmitted(b byte) (int, bool) {
	if b >= 0xC0 && b <= 0xDF {
		return 0, true
	}
	if b >= 0xE0 && b <= 0xEF {
		return 1, true
	}
	if b >= 0xF0 && b <= 0xF7 {
		return 2, true
	}
	return 0, false
}
