//go:build !linux && !darwin

package carve

import (
	"errors"
	"os"
)

// The carve runs bubblewrap and reads /proc: it exists only on Linux. Elsewhere the module still builds and the
// command reports the platform as unsupported before it touches anything.

type statTuple struct {
	dev, ino         uint64
	mode             uint32
	size             int64
	mtimeNs, ctimeNs int64
}

var errPlatform = errors.New("firmware carving requires Linux (bubblewrap and /proc)")

func tupleOf(os.FileInfo) statTuple                  { return statTuple{} }
func owner(os.FileInfo) (uid, nlink uint64, ok bool) { return 0, 0, false }
func openNoFollow(path string) (*os.File, error)     { return nil, errPlatform }

func launchWorker(launchSpec) error { return errPlatform }
