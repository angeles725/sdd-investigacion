//go:build unix

package sweep

import (
	"os"
	"strings"
	"testing"
)

// TestRetroAgeOfASymlinkIsTheLinksOwn pins the mtime fallback to `stat -c %Y`, which does not follow a symbolic
// link: a retro reachable through a link is as old as the link, not as its target. Following the link made a
// fresh link inherit an old target's age (and, across a second boundary, reordered the pending list).
func TestRetroAgeOfASymlinkIsTheLinksOwn(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a, "old.md", pendingMarker, 1)
	w.touch(a+"/retros/old.md", 40*day)
	// The link's target sits outside every retros/ directory, so the canonical-path dedup keeps the link.
	w.put(a+"/archive/real.md", retroText(pendingMarker, 1))
	w.touch(a+"/archive/real.md", 40*day)
	w.must(os.Symlink(a+"/archive/real.md", a+"/retros/link.md"))
	w.targets(a)
	w.env["RSDD_RETRO_AGE_DAYS"] = "7"
	res := w.run()
	var oldLine, linkLine string
	lines := strings.Split(res.out, "\n")
	for i, l := range lines {
		if !strings.HasPrefix(l, "PENDING  ") || i+1 >= len(lines) {
			continue
		}
		switch {
		case strings.HasSuffix(l, "/retros/old.md"):
			oldLine = lines[i+1]
		case strings.HasSuffix(l, "/retros/link.md"):
			linkLine = lines[i+1]
		}
	}
	if !strings.Contains(oldLine, "ESCALATED (aged 40d)") {
		t.Errorf("old.md detail = %q, want ESCALATED (aged 40d)\n%s", oldLine, res.out)
	}
	if linkLine == "" || strings.Contains(linkLine, "ESCALATED") {
		t.Errorf("link.md detail = %q, want a fresh (not escalated) row: its age is the link's own mtime\n%s", linkLine, res.out)
	}
}
