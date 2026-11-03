package reconcile

import (
	"fmt"
	"os"
	"strings"
)

// Cache holds the pre-fetched OPEN issue bodies an audit reads instead of calling gh (--issues-cache). A cache
// built from a file is read when the audit reaches that step, so an unreadable file keeps the legacy position in
// the stderr stream.
type Cache struct {
	path   string
	bodies string
	inline bool
}

// CacheFile is a cache backed by the file the legacy --issues-cache names.
func CacheFile(path string) *Cache { return &Cache{path: path} }

// CacheBodies is a cache already in memory, shared by the audits of several retros.
func CacheBodies(text string) *Cache { return &Cache{bodies: text, inline: true} }

// read is `$(cat file)`: NUL bytes dropped and every trailing newline removed.
func (c *Cache) read() (string, error) {
	text := c.bodies
	if !c.inline {
		b, err := os.ReadFile(c.path)
		if err != nil {
			return "", fmt.Errorf("--issues-cache file not readable: %s", c.path)
		}
		text = string(b)
	}
	return strings.TrimRight(strings.ReplaceAll(text, "\x00", ""), "\n"), nil
}

// issueRowIDs extracts, for each signature prefix in turn, the row id of every body line carrying the exact
// "Source retro: <prefix> · " signature (a fixed-string match, so a regex metacharacter in the prefix means
// nothing). The id is the run of [A-Za-z0-9_-] after the LAST " · " of the line; duplicates are kept.
func issueRowIDs(bodies string, prefixes []string) []string {
	var ids []string
	if bodies == "" {
		return nil
	}
	lines := strings.Split(bodies, "\n")
	for _, p := range prefixes {
		needle := "Source retro: " + p + " · "
		for _, l := range lines {
			if !strings.Contains(l, needle) {
				continue
			}
			tail := l[strings.LastIndex(l, " · ")+len(" · "):]
			if id := leadingID(tail); id != "" {
				ids = append(ids, id)
			}
		}
	}
	return ids
}

func leadingID(s string) string {
	n := 0
	for n < len(s) && isIDByte(s[n]) {
		n++
	}
	return s[:n]
}

func isIDByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}
