package secretscan

import (
	"bytes"
	"regexp"
)

// Deliberately conservative filters keep decompiled code and documentation from drowning the advisory signal; a
// guess must never block the pipeline, so the tier only ever warns.
var (
	placeholderPrefix = regexp.MustCompile(`(?i)^(?:x{3,}|redacted|changeme|example|placeholder|none|null|test|todo|your[_-]?)`)
	hexHash           = regexp.MustCompile(`(?i)^[0-9a-f]{32,64}$`)
	hashContext       = regexp.MustCompile(`(?i)sha[0-9]*|md5|hash|checksum|digest|fingerprint`)
)

// ellipsis is U+2026 as UTF-8.
var ellipsis = []byte("…")

// acceptValue reports whether a value extracted from content is a real-looking literal credential. The order of the
// checks is the legacy one.
func acceptValue(val, content []byte) bool {
	switch val[0] {
	case '<', '$', '{', '*', '%': // placeholder, variable or format
		return false
	}
	if bytes.Contains(val, []byte("...")) || bytes.Contains(val, ellipsis) { // truncated illustration
		return false
	}
	if bytes.ContainsAny(val, "[]()#") { // markdown link or code structure
		return false
	}
	if placeholderPrefix.Match(val) || len(val) < 8 { // too short to be a real secret
		return false
	}
	if !hasLetter(val) || !hasDigit(val) { // must mix (documented gap: all-alpha, all-digit)
		return false
	}
	// A bare hex value is a hash ONLY when its line cites it as one; otherwise a hex-shaped token is suspect.
	return !(hexHash.Match(val) && hashContext.Match(content))
}

func hasLetter(b []byte) bool {
	return bytes.IndexAny(b, asciiLetters) >= 0
}

func hasDigit(b []byte) bool { return bytes.ContainsAny(b, "0123456789") }
