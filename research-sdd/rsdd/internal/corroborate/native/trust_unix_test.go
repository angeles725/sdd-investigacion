//go:build unix

package native

import (
	"io/fs"
	"syscall"
	"testing"
	"time"
)

// statInfo is a FileInfo whose owner and mode are chosen by the test, so the trust and mount-point checks are
// exercised without depending on who owns the files of the host (a user namespace maps them to nobody).
type statInfo struct {
	uid  uint32
	mode fs.FileMode
	sys  any
}

func (statInfo) Name() string        { return "x" }
func (statInfo) Size() int64         { return 0 }
func (s statInfo) Mode() fs.FileMode { return s.mode }
func (statInfo) ModTime() time.Time  { return time.Time{} }
func (s statInfo) IsDir() bool       { return s.mode.IsDir() }
func (s statInfo) Sys() any          { return s.sys }
func owned(uid uint32, mode fs.FileMode) statInfo {
	return statInfo{uid: uid, mode: mode, sys: &syscall.Stat_t{Uid: uid}}
}

func TestBwrapRootOwnedTrustMatrix(t *testing.T) {
	for _, c := range []struct {
		name string
		fi   fs.FileInfo
		ok   bool
	}{
		{"root, 0755", owned(0, 0o755), true},
		{"root, 0555", owned(0, 0o555), true},
		{"root, group-writable", owned(0, 0o775), false},
		{"root, other-writable", owned(0, 0o757), false},
		{"root, group and other writable", owned(0, 0o777), false},
		{"user-owned, 0755", owned(1000, 0o755), false},
		{"uid 1, 0755", owned(1, 0o755), false},
		{"no owner information", statInfo{mode: 0o755}, false},
	} {
		err := bwrapRootOwned(c.fi)
		if c.ok && err != nil {
			t.Errorf("%s: %v", c.name, err)
		}
		if !c.ok && (err == nil || err.Error() != "Bubblewrap must be root-owned and non-writable") {
			t.Errorf("%s: want the trust refusal, got %v", c.name, err)
		}
	}
}
