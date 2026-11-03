//go:build linux || darwin

package firmware

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// statTuple is the identity compared before and after a read: (dev, ino, mode, size, mtime_ns, ctime_ns).
type statTuple struct {
	dev, ino         uint64
	mode             uint32
	size             int64
	mtimeNs, ctimeNs int64
}

func tupleOf(fi os.FileInfo) statTuple {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return statOf(st)
	}
	return statTuple{}
}

// owner is the uid of fi; ok is false when the platform gives no stat record.
func owner(fi os.FileInfo) (uid uint64, ok bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return uint64(st.Uid), true
}

// openNoFollow opens path read-only without following a final symlink; O_NONBLOCK keeps a writerless FIFO from
// blocking the open before the type check can refuse it.
func openNoFollow(path string) (*os.File, error) {
	for {
		fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return nil, &os.PathError{Op: "open", Path: path, Err: err}
		}
		return os.NewFile(uintptr(fd), path), nil
	}
}

// canExec is access(2) X_OK, the check behind os.access(path, os.X_OK).
func canExec(path string) bool { return syscall.Access(path, 0x1) == nil }

// resolveFD is the canonical path of the open file: the /proc/self/fd link, else the path resolved lexically.
func resolveFD(f *os.File, path string) string {
	if p, err := os.Readlink("/proc/self/fd/" + strconv.Itoa(int(f.Fd()))); err == nil {
		return p
	}
	if abs, err := filepath.Abs(path); err == nil {
		if real, err := filepath.EvalSymlinks(abs); err == nil {
			return real
		}
		return abs
	}
	return path
}

// gate is the analyzer trust rule, applied to an OPENED descriptor so the file that is checked is the file
// that is read: it and its directory must be owned by one of uids and not group- or world-writable.
type gate struct {
	uids map[uint64]bool
	hint string // appended to the file refusal: how to select a user-owned install
}

func (g *gate) require(fi os.FileInfo, resolved string) error {
	uid, ok := owner(fi)
	if !ok || !g.uids[uid] || fi.Mode().Perm()&0o022 != 0 {
		return refusal("Binwalk must be root-owned and non-writable" + g.hint)
	}
	parent, err := os.Stat(filepath.Dir(resolved))
	if err != nil {
		return osError(err, filepath.Dir(resolved))
	}
	puid, ok := owner(parent)
	if !ok || !g.uids[puid] || parent.Mode().Perm()&0o022 != 0 {
		return refusal("Binwalk's directory must be root-owned (or the invoking user's for RSDD_BINWALK) and not group/world-writable")
	}
	return nil
}

// trustedIdentity is the script's identity(): hash path through one no-follow descriptor, refusing a file that
// changed while it was read. A non-nil g gates the descriptor first, and uidSink receives the owner of the
// checked file so the trust label comes from the same descriptor, not from a second stat of the path.
func trustedIdentity(path string, g *gate, uidSink *uint64) (resolved string, size int64, digest string, err error) {
	f, err := openNoFollow(path)
	if err != nil {
		return "", 0, "", &fsx.Error{Kind: fsx.ErrOpen, Path: path, Err: err}
	}
	defer f.Close()
	before, err := f.Stat()
	if err != nil {
		return "", 0, "", &fsx.Error{Kind: fsx.ErrIO, Path: path, Err: err}
	}
	if !before.Mode().IsRegular() {
		return "", 0, "", &fsx.Error{Kind: fsx.ErrNotRegular, Path: path}
	}
	resolved = resolveFD(f, path)
	if g != nil {
		if err := g.require(before, resolved); err != nil {
			return "", 0, "", err
		}
	}
	if uid, ok := owner(before); ok && uidSink != nil {
		*uidSink = uid
	}
	h := sha256.New()
	total, err := io.Copy(h, f)
	if err != nil {
		return "", 0, "", &fsx.Error{Kind: fsx.ErrIO, Path: path, Err: err}
	}
	after, err := f.Stat()
	if err != nil {
		return "", 0, "", &fsx.Error{Kind: fsx.ErrIO, Path: path, Err: err}
	}
	if tupleOf(before) != tupleOf(after) || total != before.Size() {
		return "", 0, "", &fsx.Error{Kind: fsx.ErrChanged, Path: path}
	}
	return resolved, total, "sha256:" + hex.EncodeToString(h.Sum(nil)), nil
}

// stageTrusted is the script's stage_file() with the descriptor trust gate: copy source into the NEW file
// target through one no-follow descriptor, hashing as it copies, then require the staged copy to re-read to the
// same size and digest before applying mode. It returns the source record (resolved path) and the staged one
// (logical path). Any failure after target was created removes it.
func stageTrusted(source, target, logical string, mode os.FileMode, g *gate, uidSink *uint64) (src, staged fsx.Record, err error) {
	f, err := openNoFollow(source)
	if err != nil {
		return src, staged, &fsx.Error{Kind: fsx.ErrSourceOpen, Err: err}
	}
	defer f.Close()
	before, err := f.Stat()
	if err != nil {
		return src, staged, &fsx.Error{Kind: fsx.ErrStageIO, Err: err}
	}
	if !before.Mode().IsRegular() {
		return src, staged, &fsx.Error{Kind: fsx.ErrSourceNotRegular}
	}
	resolved := resolveFD(f, source)
	if g != nil {
		if err := g.require(before, resolved); err != nil {
			return src, staged, err
		}
	}
	if uid, ok := owner(before); ok && uidSink != nil {
		*uidSink = uid
	}
	fd, err := fsx.OpenWONew(target)
	if err != nil {
		return src, staged, err
	}
	out := os.NewFile(uintptr(fd), target)
	defer func() {
		if err != nil {
			_ = os.Remove(target)
		}
	}()
	h := sha256.New()
	total, err := io.Copy(io.MultiWriter(out, h), f)
	if err == nil {
		err = out.Sync()
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return src, staged, &fsx.Error{Kind: fsx.ErrStageIO, Err: err}
	}
	after, err := f.Stat()
	if err != nil {
		return src, staged, &fsx.Error{Kind: fsx.ErrStageIO, Err: err}
	}
	if tupleOf(before) != tupleOf(after) || total != before.Size() {
		err = &fsx.Error{Kind: fsx.ErrSourceChanged}
		return src, staged, err
	}
	digest := "sha256:" + hex.EncodeToString(h.Sum(nil))
	id, err := fsx.Identity(target, fsx.NoLimit)
	if err != nil {
		return src, staged, err
	}
	if id.Size != total || id.SHA256 != digest {
		err = &fsx.Error{Kind: fsx.ErrStagedMismatch}
		return src, staged, err
	}
	if err = os.Chmod(target, mode); err != nil {
		return src, staged, err
	}
	return fsx.Record{Path: resolved, Size: total, SHA256: digest}, fsx.Record{Path: logical, Size: id.Size, SHA256: id.SHA256}, nil
}
