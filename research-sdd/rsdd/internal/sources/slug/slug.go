// Package slug derives the snapshot file stem of `fetch-doc web`.
package slug

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
)

// maxPlain is the longest slug returned unchanged; longer ones are shortened with a hash.
const maxPlain = 80

var scheme = regexp.MustCompile(`https?://`)

// bytewise replaces every byte outside [A-Za-z0-9._-] with "_" (never per rune: the rule is the C locale's).
func bytewise(s string) string {
	b := []byte(s)
	for i, c := range b {
		if !safe(c) {
			b[i] = '_'
		}
	}
	return string(b)
}

// safe reports whether c is kept as it is: [A-Za-z0-9._-].
func safe(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-'
}

// Web returns the snapshot stem for url: the scheme-less URL with every byte outside [A-Za-z0-9._-] turned into
// "_" (a multi-byte character becomes one "_" per byte, the locale-independent C-locale rule). A slug of at most
// 80 bytes is returned unchanged, so existing short-URL names stay stable. A longer one becomes
// <first 46>_<last 20>-<first 12 hex of sha256(FULL url)>: head and tail stay readable and the hash, taken over the
// URL WITH its scheme, makes the name distinct and deterministic per URL (80 bytes in all).
func Web(url string) string {
	s := bytewise(replaceFirst(url))
	if len(s) <= maxPlain {
		return s
	}
	h := sha256.Sum256([]byte(url))
	return s[:46] + "_" + s[len(s)-20:] + "-" + hex.EncodeToString(h[:])[:12]
}

// replaceFirst drops the first http:// or https:// wherever it occurs (sed 's#https?://##', no g flag).
func replaceFirst(url string) string {
	loc := scheme.FindStringIndex(url)
	if loc == nil {
		return url
	}
	return url[:loc[0]] + url[loc[1]:]
}
