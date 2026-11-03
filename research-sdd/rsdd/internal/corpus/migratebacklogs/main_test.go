package migratebacklogs

import (
	"os"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/parallelfloor"
)

// The differential and the golden replay run one corpus per subtest, each mostly waiting on the legacy bash and
// its awk and diff children: a floor of 8 parallel subtests (lesson L69).
func TestMain(m *testing.M) {
	parallelfloor.Raise(8)
	os.Exit(m.Run())
}
