//go:build linux

package formats

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// zipInput is the input archive opened once, read only through its descriptor with pread, as the legacy
// readers did (os.pread on a descriptor opened O_NOFOLLOW|O_NONBLOCK).
type zipInput struct {
	fd   int
	path string
}

// zipOpenInput opens path through fsx.OpenRO and returns the descriptor with its fstat.
func zipOpenInput(path string) (*zipInput, fsx.Stat, error) {
	fd, st, err := fsx.OpenRO(path)
	if err != nil {
		return nil, fsx.Stat{}, err
	}
	return &zipInput{fd: fd, path: path}, st, nil
}

func (f *zipInput) Close() error { return syscall.Close(f.fd) }

// ReadAt is pread: it retries EINTR and returns a short count only at end of file.
func (f *zipInput) ReadAt(p []byte, off int64) (int, error) {
	total := 0
	for total < len(p) {
		n, err := syscall.Pread(f.fd, p[total:], off+int64(total))
		if errors.Is(err, syscall.EINTR) {
			continue
		}
		if err != nil {
			return total, &os.PathError{Op: "pread", Path: f.path, Err: err}
		}
		if n == 0 {
			return total, io.EOF
		}
		total += n
	}
	return total, nil
}

// Stat is fstat on the descriptor, in the tuple the legacy ensure_stable compared.
func (f *zipInput) Stat() (fsx.Stat, error) {
	var s syscall.Stat_t
	if err := syscall.Fstat(f.fd, &s); err != nil {
		return fsx.Stat{}, &os.PathError{Op: "fstat", Path: f.path, Err: err}
	}
	return fsx.Stat{
		Dev: uint64(s.Dev), Ino: uint64(s.Ino), Mode: uint32(s.Mode), Size: s.Size,
		MtimeNs: s.Mtim.Nano(), CtimeNs: s.Ctim.Nano(),
	}, nil
}

// Resolved is Path(f"/proc/self/fd/{fd}").resolve(): the canonical path of the opened file.
func (f *zipInput) Resolved() string {
	link, err := os.Readlink("/proc/self/fd/" + strconv.Itoa(f.fd))
	if err != nil {
		return f.path
	}
	if real, err := filepath.EvalSymlinks(link); err == nil {
		return real
	}
	return link
}

// zipOwnerOf reports the owner and link count of a file.
func zipOwnerOf(fi os.FileInfo) (uid uint32, nlink uint64, ok bool) {
	st, isStat := fi.Sys().(*syscall.Stat_t)
	if !isStat {
		return 0, 0, false
	}
	return st.Uid, uint64(st.Nlink), true
}

// zipGetuid is the owner the output tree must have; a test replaces it.
var zipGetuid = func() int { return os.Getuid() }
