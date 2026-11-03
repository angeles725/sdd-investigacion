package stage

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"strings"
)

// slugOf is the script's `basename "$retro" .md | tr -c 'a-zA-Z0-9._-' '-' | sed 's/-\{2,\}/-/g;s/^-//;s/-$//'`:
// every byte outside [A-Za-z0-9._-] becomes '-', runs of '-' collapse (a '-' that was in the name included), and
// one leading and one trailing '-' go. A name with no such byte at all (a file named after non-ASCII text) used to
// give an empty slug, so every such retro of a target shared one branch; it now gets "retro-" and the first eight
// hex digits of the SHA-256 of the file name, which keeps the branch stable per file and distinct between files.
func slugOf(retro string) string {
	base := filepath.Base(retro)
	name := base
	if name != ".md" {
		name = strings.TrimSuffix(name, ".md") // basename keeps a name that is exactly the suffix
	}
	var b strings.Builder
	for i := 0; i < len(name); i++ {
		c := name[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-' {
			b.WriteByte(c)
		} else {
			b.WriteByte('-')
		}
	}
	s := b.String()
	for strings.Contains(s, "--") {
		s = strings.ReplaceAll(s, "--", "-")
	}
	s = strings.TrimSuffix(strings.TrimPrefix(s, "-"), "-")
	if s == "" {
		sum := sha256.Sum256([]byte(base))
		return "retro-" + hex.EncodeToString(sum[:4])
	}
	return s
}

// shellQuote is a POSIX single-quoted word: the suggested commands are meant to be pasted into a shell, and a
// single quote in the target label or in the retro's file name used to end the quoting early.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
