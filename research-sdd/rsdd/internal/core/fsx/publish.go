package fsx

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

// renameat2 flags and the AT_FDCWD directory descriptor.
const (
	AtFDCWD       = -100
	FlagNoReplace = 1
	FlagExchange  = 2
)

// Record is a path/size/digest triple as the staging helpers report it.
type Record struct {
	Path   string
	Size   int64
	SHA256 string
}

// Test seams: the raw renameat2 call and the post-copy identity check.
var (
	renameat2Fn = sysRenameat2
	identityFn  = Identity
)

// Renameat2 calls renameat2(2). ENOSYS and EINVAL (no kernel support, or a
// filesystem that does not take the flag) are ErrUnavailable; there is never a
// fallback to a plain rename. Every other failure is an *os.LinkError carrying
// the errno, so EEXIST satisfies errors.Is(err, fs.ErrExist).
func Renameat2(oldDirFD int, oldPath string, newDirFD int, newPath string, flags uint) error {
	if containsNUL(oldPath) || containsNUL(newPath) {
		return &os.LinkError{Op: "renameat2", Old: oldPath, New: newPath, Err: syscall.EINVAL}
	}
	err := renameat2Fn(oldDirFD, oldPath, newDirFD, newPath, flags)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, ErrUnavailable):
		return err
	case errors.Is(err, syscall.ENOSYS), errors.Is(err, syscall.EINVAL):
		return &Error{Kind: ErrUnavailable, Path: newPath, Err: err}
	}
	return &os.LinkError{Op: "renameat2", Old: oldPath, New: newPath, Err: err}
}

func containsNUL(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == 0 {
			return true
		}
	}
	return false
}

// RenameNoReplace renames oldPath to newPath, failing with EEXIST if newPath
// exists (RENAME_NOREPLACE).
func RenameNoReplace(oldPath, newPath string) error {
	return Renameat2(AtFDCWD, oldPath, AtFDCWD, newPath, FlagNoReplace)
}

// RenameExchange atomically swaps two existing paths (RENAME_EXCHANGE).
func RenameExchange(a, b string) error {
	return Renameat2(AtFDCWD, a, AtFDCWD, b, FlagExchange)
}

// Publish moves stage to dest without ever replacing dest: an existing dest is
// an EEXIST error, an unsupported kernel is ErrUnavailable. It does not sync
// the parent directory; call SyncDir for durability.
func Publish(stage, dest string) error { return RenameNoReplace(stage, dest) }

// SyncDir fsyncs a directory so a rename into it is durable.
func SyncDir(path string) error {
	fd, err := sysOpenDir(path)
	if err != nil {
		return &os.PathError{Op: "open", Path: path, Err: err}
	}
	defer func() { _ = sysClose(fd) }()
	if err := sysFsync(fd); err != nil {
		return &os.PathError{Op: "fsync", Path: path, Err: err}
	}
	return nil
}

// WriteAtomic writes data to path through the sibling ".<name>.tmp": write,
// fsync, rename over path. A stale temp is truncated and reused; the temp is
// removed if any step fails. The file mode is 0666 &^ umask, as Python's
// Path.write_bytes creates it.
func WriteAtomic(path string, data []byte) (err error) {
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.Remove(tmp)
		}
	}()
	if _, err = f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// StageFile copies source to the new file target through ONE source fd
// (O_NOFOLLOW, regular files only), hashing as it copies, then re-reads target
// and requires the same size and digest before applying mode. It returns the
// source record (resolved path) and the staged record (logical path).
//
// Any failure after target was created removes the partial target; a target
// that already existed is never removed. maxBytes caps the source (NoLimit for
// none).
func StageFile(source, target, logical string, mode os.FileMode, maxBytes int64) (Record, Record, error) {
	src, err := sysOpenRO(source)
	if err != nil {
		return Record{}, Record{}, &Error{Kind: ErrSourceOpen, Err: err}
	}
	defer func() { _ = sysClose(src) }()
	srcRec, total, digest, err := copyToTarget(src, target, maxBytes)
	if err != nil {
		return Record{}, Record{}, err
	}
	id, err := identityFn(target, maxBytes)
	if err != nil {
		return Record{}, Record{}, err
	}
	if id.Size != total || id.SHA256 != digest {
		return Record{}, Record{}, &Error{Kind: ErrStagedMismatch}
	}
	if err := os.Chmod(target, mode); err != nil {
		return Record{}, Record{}, err
	}
	srcRec.Size, srcRec.SHA256 = total, digest
	return srcRec, Record{Path: logical, Size: id.Size, SHA256: id.SHA256}, nil
}

// copyToTarget does the single-fd copy and unlinks target on any error once it
// has created it.
func copyToTarget(src int, target string, maxBytes int64) (rec Record, total int64, digest string, err error) {
	before, err := sysFstat(src)
	if err != nil {
		return rec, 0, "", &Error{Kind: ErrStageIO, Err: err}
	}
	if !before.IsRegular() {
		return rec, 0, "", &Error{Kind: ErrSourceNotRegular}
	}
	capped := maxBytes != NoLimit
	if capped && before.Size > maxBytes {
		return rec, 0, "", &Error{Kind: ErrTooLarge}
	}
	rec.Path = sysResolveFD(src, "")
	out, err := sysOpenWONew(target)
	if err != nil {
		return rec, 0, "", &Error{Kind: ErrStageIO, Err: err}
	}
	defer func() {
		if err != nil {
			_ = os.Remove(target)
		}
	}()
	h := sha256.New()
	buf := make([]byte, chunkSize)
	copyErr := func() error {
		for {
			want := int64(len(buf))
			if capped && maxBytes-total+1 < want {
				want = maxBytes - total + 1
			}
			n, err := sysRead(src, buf[:want])
			if err != nil {
				return &Error{Kind: ErrStageIO, Err: err}
			}
			if n == 0 {
				break
			}
			total += int64(n)
			if capped && total > maxBytes {
				return &Error{Kind: ErrTooLarge}
			}
			h.Write(buf[:n])
			for view := buf[:n]; len(view) > 0; {
				w, err := sysWrite(out, view)
				if err != nil {
					return &Error{Kind: ErrStageIO, Err: err}
				}
				view = view[w:]
			}
			if hashChunkHook != nil {
				hashChunkHook()
			}
		}
		if err := sysFsync(out); err != nil {
			return &Error{Kind: ErrStageIO, Err: err}
		}
		return nil
	}()
	closeErr := sysClose(out)
	if copyErr != nil {
		return rec, 0, "", copyErr
	}
	if closeErr != nil {
		return rec, 0, "", &Error{Kind: ErrStageIO, Err: closeErr}
	}
	after, err := sysFstat(src)
	if err != nil {
		return rec, 0, "", &Error{Kind: ErrStageIO, Err: err}
	}
	if after != before || total != before.Size {
		return rec, 0, "", &Error{Kind: ErrSourceChanged}
	}
	return rec, total, "sha256:" + hex.EncodeToString(h.Sum(nil)), nil
}
