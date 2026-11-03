//go:build unix && !nodiff

package show

import (
	"os"
	"sync"
	"testing"
)

// TestDifferentialBlockedOpen runs blocked_open_count of the live lib/blocked-rows.sh beside the Go port on every
// scenario and asserts the golden equals the oracle.
func TestDifferentialBlockedOpen(t *testing.T) {
	var mu sync.Mutex
	sections := map[string]string{}
	t.Run("scenarios", func(t *testing.T) {
		for _, sc := range blockedOpenScenarios() {
			t.Run(sc.name, func(t *testing.T) {
				if sc.unreadable && os.Geteuid() == 0 {
					t.Skip("mode-000 files are readable by root")
				}
				root := sc.build(t)
				goOuts := runGoOps(t, sc, root)
				bashOuts := runS2Bash(t, sc, root)
				for i, op := range sc.ops {
					if goOuts[i] != bashOuts[i] {
						t.Errorf("op %s differs from the live library\ngo   rc=%d stdout=%q stderr=%q\nbash rc=%d stdout=%q stderr=%q",
							op.line(root), goOuts[i].rc, goOuts[i].out, goOuts[i].err, bashOuts[i].rc, bashOuts[i].out, bashOuts[i].err)
					}
				}
				mu.Lock()
				sections[sc.name] = renderS2(sc, bashOuts, root)
				mu.Unlock()
			})
		}
	})
	if t.Failed() && !*update {
		return
	}
	for _, sc := range blockedOpenScenarios() {
		if _, ok := sections[sc.name]; !ok && !*update {
			if old, ok := parseGoldenIfPresent(t, goldenBlockedOpen)[sc.name]; ok {
				sections[sc.name] = old
			}
		}
	}
	checkGolden(t, goldenBlockedOpen, sections)
}
