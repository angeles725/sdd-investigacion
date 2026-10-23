// Package fsx is the one home for the kit's safe filesystem helpers: a
// no-follow regular-file open, fd-based identity hashing with a before/after
// fstat check, exclusive create, atomic write, and renameat2 publication.
// It replaces the per-tool Python copies (adapter_core.py, corroborate_*.py,
// zip_*.py, ...), keeping their semantics and error classes so callers can map
// the typed errors to reason codes.
//
// The package reads no environment, clock or stdout. Operations that need a
// Linux kernel facility return ErrUnavailable elsewhere; nothing falls back to
// a weaker primitive (a plain rename is never a substitute for NOREPLACE).
package fsx

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
)

// Error kinds. Messages match the Python helpers so reason-code mapping stays
// textually stable. Test with errors.Is against these sentinels.
var (
	ErrOpen        = errors.New("cannot open regular non-symlink file")
	ErrNotRegular  = errors.New("not a regular file")
	ErrTooLarge    = errors.New("input exceeds max-input-bytes")
	ErrChanged     = errors.New("file changed while hashing")
	ErrIO          = errors.New("I/O error reading file")
	ErrUnavailable = errors.New("atomic no-replace publication is unavailable")
)

// Error is a typed fsx failure: Kind is the sentinel, Path the operand (may be
// empty) and Err the underlying cause (an errno for syscall failures).
type Error struct {
	Kind error
	Path string
	Err  error
}

func (e *Error) Error() string {
	if e.Path == "" {
		return e.Kind.Error()
	}
	return e.Kind.Error() + ": " + e.Path
}

// Unwrap exposes both the kind and the cause, so errors.Is works for
// ErrOpen as well as for syscall.ELOOP or fs.ErrNotExist.
func (e *Error) Unwrap() []error {
	if e.Err == nil {
		return []error{e.Kind}
	}
	return []error{e.Kind, e.Err}
}

// NoLimit disables the size cap in Identity.
const NoLimit int64 = -1

// Stat is the identity tuple the Python helpers compare before and after a
// read: (dev, ino, mode, size, mtime_ns, ctime_ns).
type Stat struct {
	Dev, Ino         uint64
	Mode             uint32
	Size             int64
	MtimeNs, CtimeNs int64
}

const (
	modeTypeMask = 0o170000
	modeRegular  = 0o100000
)

// IsRegular reports S_ISREG.
func (s Stat) IsRegular() bool { return s.Mode&modeTypeMask == modeRegular }

// Ident is the result of Identity: the resolved path of the opened file, its
// size and "sha256:<hex>".
type Ident struct {
	Resolved string
	Size     int64
	SHA256   string
}

const chunkSize = 1024 * 1024

// hashChunkHook, when set by a test, runs after every chunk is hashed. It is
// the deterministic seam for "file mutated while hashing".
var hashChunkHook func()

// OpenRO opens path read-only with O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK and returns
// the fd with its fstat. A symlink or unopenable path is ErrOpen; a non-regular
// file is ErrNotRegular (the fd is closed on every error). O_NONBLOCK keeps a
// writerless FIFO from blocking the open before fstat can refuse it.
func OpenRO(path string) (int, Stat, error) {
	fd, err := sysOpenRO(path)
	if err != nil {
		return -1, Stat{}, &Error{Kind: ErrOpen, Path: path, Err: err}
	}
	st, err := sysFstat(fd)
	if err != nil {
		_ = sysClose(fd)
		return -1, Stat{}, &Error{Kind: ErrIO, Path: path, Err: err}
	}
	if !st.IsRegular() {
		_ = sysClose(fd)
		return -1, Stat{}, &Error{Kind: ErrNotRegular, Path: path}
	}
	return fd, st, nil
}

// Identity hashes path through a single fd, refusing a file that changed while
// it was read: fstat (dev, ino, mode, size, mtime_ns, ctime_ns) before and
// after must match and the bytes read must equal the size. maxBytes caps the
// size (NoLimit for none), both as declared and as actually read.
func Identity(path string, maxBytes int64) (Ident, error) {
	fd, before, err := OpenRO(path)
	if err != nil {
		return Ident{}, err
	}
	defer func() { _ = sysClose(fd) }()
	capped := maxBytes != NoLimit
	if capped && before.Size > maxBytes {
		return Ident{}, &Error{Kind: ErrTooLarge}
	}
	resolved := sysResolveFD(fd, path)
	h := sha256.New()
	var total int64
	buf := make([]byte, chunkSize)
	for {
		want := int64(len(buf))
		if capped && maxBytes-total+1 < want {
			want = maxBytes - total + 1
		}
		n, err := sysRead(fd, buf[:want])
		if err != nil {
			return Ident{}, &Error{Kind: ErrIO, Path: path, Err: err}
		}
		if n == 0 {
			break
		}
		total += int64(n)
		if capped && total > maxBytes {
			return Ident{}, &Error{Kind: ErrTooLarge}
		}
		h.Write(buf[:n])
		if hashChunkHook != nil {
			hashChunkHook()
		}
	}
	after, err := sysFstat(fd)
	if err != nil {
		return Ident{}, &Error{Kind: ErrIO, Path: path, Err: err}
	}
	if after != before || total != before.Size {
		return Ident{}, &Error{Kind: ErrChanged, Path: path}
	}
	return Ident{Resolved: resolved, Size: total, SHA256: "sha256:" + hex.EncodeToString(h.Sum(nil))}, nil
}
