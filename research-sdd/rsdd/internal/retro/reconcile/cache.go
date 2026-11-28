package reconcile

import (
	"fmt"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/issuesdue"
)

// Cache holds the pre-fetched OPEN issue bodies an audit reads instead of calling gh (--issues-cache). A cache
// built from a file is read when the audit reaches that step, so an unreadable file keeps the legacy position in
// the stderr stream.
type Cache struct {
	path   string
	bodies string
	inline bool
	flag   string
	// prefetched marks the batch prefetch (LoadCache): Run re-verifies the untracked rows it reports.
	prefetched bool
}

// CacheFile is a cache backed by the file the legacy --issues-cache names.
func CacheFile(path string) *Cache { return &Cache{path: path, flag: "--issues-cache"} }

// CacheBodies is a cache already in memory, shared by the audits of several retros.
func CacheBodies(text string) *Cache {
	return &Cache{bodies: text, inline: true, flag: "--issues-cache"}
}

// ClosedFile is a closed-issue cache backed by the file the legacy --closed-cache names: the bodies of the
// issues closed AS COMPLETED (Options.ClosedCache).
func ClosedFile(path string) *Cache { return &Cache{path: path, flag: "--closed-cache"} }

// ClosedBodies is a closed-issue cache already in memory.
func ClosedBodies(text string) *Cache {
	return &Cache{bodies: text, inline: true, flag: "--closed-cache"}
}

// read is `$(cat file)`: NUL bytes dropped and every trailing newline removed.
func (c *Cache) read() (string, error) {
	text := c.bodies
	if !c.inline {
		b, err := os.ReadFile(c.path)
		if err != nil {
			return "", fmt.Errorf("%s file not readable: %s", c.flag, c.path)
		}
		text = string(b)
	}
	return issuesdue.Normalize(text), nil
}
