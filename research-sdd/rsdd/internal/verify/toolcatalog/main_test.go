package toolcatalog

import (
	"os"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/parallelfloor"
)

// TestMain raises the default -parallel to 8: the differential tests are bound by the bash children they fork, not
// by CPU, so the GOMAXPROCS default (2 in the lanes) would leave them waiting in line. An explicit -parallel wins.
func TestMain(m *testing.M) {
	parallelfloor.Raise(8)
	os.Exit(m.Run())
}
