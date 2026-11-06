//go:build unix && !nodiff

package sweep

import (
	"os"
	"testing"
)

// TestRetrosDifferentialSymlinkAge pins the mtime fallback against the frozen script with a link whose own mtime
// and its target's sit 40 days apart, so a port that follows the link reorders and escalates differently
// regardless of the wall clock (TestRetrosDifferentialOrder only saw it when its setup crossed a second).
func TestRetrosDifferentialSymlinkAge(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a, "mid.md", pendingMarker, 1)
	w.touch(a+"/retros/mid.md", 20*day)
	w.put(a+"/archive/real.md", retroText(pendingMarker, 1))
	w.touch(a+"/archive/real.md", 40*day)
	w.must(os.Symlink(a+"/archive/real.md", a+"/retros/link.md"))
	w.targets(a)
	w.env["RSDD_RETRO_AGE_DAYS"] = "7"
	w.same("report", w.run(), w.bash("sweep-retros.sh"))
}
