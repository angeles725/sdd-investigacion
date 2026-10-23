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
