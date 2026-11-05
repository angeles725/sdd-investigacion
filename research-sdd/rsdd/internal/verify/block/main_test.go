package block

import (
	"os"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/parallelfloor"
)

// TestMain raises the default -parallel to 8: the parallel tests are bound by the bash and git children they fork,
// not by CPU, so the GOMAXPROCS default (2 in the lanes) leaves them waiting in line (L69). An explicit -parallel wins.
func TestMain(m *testing.M) {
	parallelfloor.Raise(8)
	os.Exit(m.Run())
}
