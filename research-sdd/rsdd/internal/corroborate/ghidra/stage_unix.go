//go:build unix

package ghidra

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// stageFile copies source to target (inside the stage) with fsx's single-descriptor copy and returns the source
// and staged identities. Errors keep the legacy driver's wording.
func stageFile(source, target, logical string, mode os.FileMode) (fsx.Record, fsx.Record, error) {
	if err := os.MkdirAll(filepath.Dir(target), 0o777); err != nil {
		return fsx.Record{}, fsx.Record{}, osError(err, filepath.Dir(target))
	}
	src, staged, err := fsx.StageFile(source, target, logical, mode, fsx.NoLimit)
	return src, staged, stageError(err)
}

// stageError maps fsx's typed staging failures to the legacy messages (bare, without the cause).
func stageError(err error) error {
	if errors.Is(err, fsx.ErrSourceNotRegular) {
		return errors.New("source is not regular")
	}
	for _, kind := range []error{fsx.ErrSourceOpen, fsx.ErrSourceChanged, fsx.ErrStagedMismatch} {
		if errors.Is(err, kind) {
			return errors.New(kind.Error())
		}
	}
	return err
}

// stageOpen copies an already-open authenticated file (the Bubblewrap launcher) so that no path lookup can swap
// it between authentication and copy. The copy is hashed as it is written and re-read from disk; both digests
// must agree. Device, inode, size, modification time and mode must not move while it is read.
func stageOpen(src *os.File, target, logical string, mode os.FileMode, resolved string) (fsx.Record, fsx.Record, error) {
	before, err := src.Stat()
	if err != nil || !before.Mode().IsRegular() {
		return fsx.Record{}, fsx.Record{}, errors.New("source is not regular")
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o777); err != nil {
		return fsx.Record{}, fsx.Record{}, osError(err, filepath.Dir(target))
	}
	fd, err := fsx.OpenWONew(target)
	if err != nil {
		return fsx.Record{}, fsx.Record{}, err
	}
	out := os.NewFile(uintptr(fd), target)
	h := sha256.New()
	total, copyErr := io.Copy(io.MultiWriter(out, h), io.NewSectionReader(src, 0, 1<<62))
	if copyErr == nil {
		copyErr = out.Sync()
	}
	if cerr := out.Close(); copyErr == nil {
		copyErr = cerr
	}
	discard := func(err error) (fsx.Record, fsx.Record, error) {
		_ = os.Remove(target)
		return fsx.Record{}, fsx.Record{}, err
	}
	if copyErr != nil {
		return discard(copyErr)
	}
	after, err := src.Stat()
	if err != nil || !os.SameFile(before, after) || total != before.Size() || before.Size() != after.Size() ||
		!before.ModTime().Equal(after.ModTime()) || before.Mode() != after.Mode() {
		return discard(errors.New("source changed while staging"))
	}
	digest := "sha256:" + hex.EncodeToString(h.Sum(nil))
	id, err := identity(target)
	if err != nil || id.Size != total || id.SHA256 != digest {
		return discard(errors.New("staged identity mismatch"))
	}
	if err := os.Chmod(target, mode); err != nil {
		return discard(err)
	}
	return fsx.Record{Path: resolved, Size: total, SHA256: digest}, fsx.Record{Path: logical, Size: id.Size, SHA256: id.SHA256}, nil
}

// lockedFile is a staged file held open: the descriptor is what the sandbox binds and executes.
type lockedFile struct {
	f    *os.File
	path string
	rec  fsx.Record
}

// lockStaged opens path without following symlinks and requires its bytes to still be rec.
func lockStaged(path string, rec fsx.Record) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, osError(err, path)
	}
	size, digest, err := fdIdentity(f)
	if err != nil || size != rec.Size || digest != rec.SHA256 {
		_ = f.Close()
		return nil, errors.New("staged identity changed before lock")
	}
	return f, nil
}

// verify re-checks a lock: the pathname still names the locked inode and the locked bytes are unchanged.
func (l lockedFile) verify() error {
	byPath, err := os.Stat(l.path)
	if err != nil {
		return errors.New("staged pathname replaced")
	}
	byFD, err := l.f.Stat()
	if err != nil || !os.SameFile(byPath, byFD) {
		return errors.New("staged pathname replaced")
	}
	size, digest, err := fdIdentity(l.f)
	if err != nil || size != l.rec.Size || digest != l.rec.SHA256 {
		return errors.New("locked staged bytes changed")
	}
	return nil
}
