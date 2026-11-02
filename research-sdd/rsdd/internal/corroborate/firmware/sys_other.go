//go:build !linux && !darwin

package firmware

import (
	"errors"
	"os"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// The analyzer runs under bubblewrap and the process cap reads /proc: both exist only on Linux. Elsewhere the
// module still builds and every run is refused when it first needs one of them.

var errPlatform = errors.New("firmware evidence requires Linux (bubblewrap and /proc)")

type gate struct {
	uids map[uint64]bool
	hint string
}

func owner(os.FileInfo) (uint64, bool) { return 0, false }
func canExec(string) bool              { return false }

func trustedIdentity(string, *gate, *uint64) (string, int64, string, error) {
	return "", 0, "", errPlatform
}

func stageTrusted(string, string, string, os.FileMode, *gate, *uint64) (fsx.Record, fsx.Record, error) {
	return fsx.Record{}, fsx.Record{}, errPlatform
}

type runSpec struct {
	argv     []string
	dir      string
	env      []string
	self     string
	timeout  time.Duration
	maxBytes int64
	maxProcs int
	now      func() time.Time
}

func runBounded(runSpec) (runRecord, []string, error) { return runRecord{}, nil, errPlatform }
