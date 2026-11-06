//go:build !nodiff

package fetchdoc

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// TestDivergencesPinnedAgainstLegacy runs the frozen legacy script on every intended divergence that declares what
// the script did, so each one is pinned from BOTH sides: the old behaviour is asserted here, the new one in
// TestIntendedDivergences. A divergence the legacy script no longer shows (because the oracle moved) fails here.
func TestDivergencesPinnedAgainstLegacy(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", "fetch-doc.sh")
	for _, d := range divergences() {
		if d.legacy == nil {
			continue
		}
		t.Run(d.name, func(t *testing.T) {
			w := newWorld(t, d.stubs...)
			w.setEnv(d.env...)
			if d.setup != nil {
				d.setup(w)
			}
			l := kitworld.RunBash(t, w.dir, w.environ(), stage+"/fetch-doc.sh", d.args(w)...)
			d.legacy(t, w, ran{out: l.Out, err: l.Err, rc: l.RC})
		})
	}
}
