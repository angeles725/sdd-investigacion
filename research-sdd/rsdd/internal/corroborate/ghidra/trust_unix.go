//go:build unix

//lint:file-ignore ST1005 the messages are the legacy driver's, kept byte for byte (parity)

package ghidra

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// defPath is os.defpath, the only search path the Bubblewrap launcher is trusted to be found on.
const defPath = "/bin:/usr/bin"

// canExec is access(2) X_OK.
func canExec(path string) bool { return syscall.Access(path, 0x1) == nil }

// ownerUID is the owning user id of fi.
func ownerUID(fi os.FileInfo) (int, bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return int(st.Uid), true
}

// identity is the fsx identity of path with the legacy driver's error wording.
func identity(path string) (fsx.Ident, error) { return identityAs(path, path) }

// identityAs opens open but names show in its errors (the path as the user typed it).
func identityAs(open, show string) (fsx.Ident, error) {
	id, err := fsx.Identity(open, fsx.NoLimit)
	var fe *fsx.Error
	if errors.As(err, &fe) {
		switch {
		case errors.Is(fe, fsx.ErrOpen):
			return id, errors.New("cannot safely open " + show)
		case errors.Is(fe, fsx.ErrNotRegular):
			return id, errors.New("not a regular file: " + show)
		case errors.Is(fe, fsx.ErrChanged):
			return id, errors.New("file changed while hashing: " + show)
		}
	}
	return id, err
}

// fdIdentity is the size and "sha256:<hex>" of the whole file behind f, read by offset so f's position is untouched.
func fdIdentity(f *os.File) (int64, string, error) {
	h := sha256.New()
	n, err := io.Copy(h, io.NewSectionReader(f, 0, 1<<62))
	if err != nil {
		return 0, "", err
	}
	return n, "sha256:" + hex.EncodeToString(h.Sum(nil)), nil
}

// trusted authenticates a launcher: it opens without following symlinks, must be the file expected (when
// given), executable, and owned by root or the caller and not writable by group or other.
func trusted(path, expected string) (string, fsx.Record, error) {
	id, err := identity(path)
	if err != nil {
		return "", fsx.Record{}, err
	}
	if expected != "" {
		same, err := sameFile(id.Resolved, expected)
		if err != nil {
			return "", fsx.Record{}, osError(err, expected)
		}
		if !same {
			return "", fsx.Record{}, errors.New("trusted path mismatch")
		}
	}
	if !canExec(id.Resolved) {
		return "", fsx.Record{}, errors.New("trusted executable is not executable")
	}
	fi, err := os.Stat(id.Resolved)
	if err != nil {
		return "", fsx.Record{}, osError(err, id.Resolved)
	}
	if owner, _ := ownerUID(fi); untrustedFile(owner, os.Getuid(), fi.Mode().Perm()) {
		return "", fsx.Record{}, errors.New("trusted executable is writable by others")
	}
	return id.Resolved, fsx.Record{Path: id.Resolved, Size: id.Size, SHA256: id.SHA256}, nil
}

// untrustedFile is the launcher policy on one file: owned by root or the caller, not writable by group or other.
func untrustedFile(owner, uid int, perm os.FileMode) bool {
	return (owner != 0 && owner != uid) || perm&0o022 != 0
}

func sameFile(a, b string) (bool, error) {
	sa, err := os.Stat(a)
	if err != nil {
		return false, err
	}
	sb, err := os.Stat(b)
	if err != nil {
		return false, err
	}
	return os.SameFile(sa, sb), nil
}

// trustedBwrap authenticates the Bubblewrap launcher and returns it OPEN: every later copy and execution goes
// through this descriptor, not the path. Outside test-only mode it must be the launcher the trusted default PATH
// selects, owned by root, not writable by others, with every ancestor directory root-owned and not writable by others.
func trustedBwrap(path string, testOnly bool) (*os.File, string, fsx.Record, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, "", fsx.Record{}, errors.New("Bubblewrap cannot be opened safely")
	}
	fail := func(err error) (*os.File, string, fsx.Record, error) {
		_ = f.Close()
		return nil, "", fsx.Record{}, err
	}
	fi, err := f.Stat()
	if err != nil {
		return fail(err)
	}
	resolved, err := os.Readlink("/proc/self/fd/" + strconv.Itoa(int(f.Fd())))
	if err != nil {
		resolved = path
	}
	if !fi.Mode().IsRegular() || fi.Mode().Perm()&0o111 == 0 {
		return fail(errors.New("Bubblewrap is not executable"))
	}
	if !testOnly {
		if err := checkBwrapTrust(fi, resolved); err != nil {
			return fail(err)
		}
	}
	size, digest, err := fdIdentity(f)
	if err != nil {
		return fail(err)
	}
	return f, resolved, fsx.Record{Path: resolved, Size: size, SHA256: digest}, nil
}

// trustOps are the filesystem facts checkBwrapTrust reads; tests replace them because a test cannot make a
// root-owned file. The defaults are the real calls.
type trustOps struct {
	selected     func() (string, bool)
	evalSymlinks func(string) (string, error)
	sameFile     func(a, b string) (bool, error)
	stat         func(string) (os.FileInfo, error)
	owner        func(os.FileInfo) (int, bool)
}

var bwrapTrustOps = trustOps{
	selected:     func() (string, bool) { return lookPath("bwrap", defPath) },
	evalSymlinks: filepath.EvalSymlinks,
	sameFile:     sameFile,
	stat:         os.Stat,
	owner:        ownerUID,
}

// checkBwrapTrust is the production launcher policy (see trustedBwrap).
func checkBwrapTrust(fi os.FileInfo, resolved string) error {
	ops := bwrapTrustOps
	selected, ok := ops.selected()
	if !ok {
		return errors.New("Bubblewrap must match trusted PATH-selected bwrap")
	}
	real, err := ops.evalSymlinks(selected)
	if err != nil {
		return osError(err, selected)
	}
	same, err := ops.sameFile(resolved, real)
	if err != nil || !same {
		return errors.New("Bubblewrap must match trusted PATH-selected bwrap")
	}
	if owner, _ := ops.owner(fi); owner != 0 || fi.Mode().Perm()&0o022 != 0 {
		return errors.New("Bubblewrap must be root-owned and non-writable")
	}
	for dir := filepath.Dir(resolved); ; dir = filepath.Dir(dir) {
		di, err := ops.stat(dir)
		if err != nil {
			return osError(err, dir)
		}
		if owner, _ := ops.owner(di); owner != 0 || di.Mode().Perm()&0o022 != 0 {
			return errors.New("Bubblewrap ancestor chain is not trusted")
		}
		if dir == "/" || dir == "." {
			return nil
		}
	}
}

// lookPath is shutil.which over an explicit search path: the first executable non-directory name on it.
func lookPath(name, search string) (string, bool) {
	for _, dir := range filepath.SplitList(search) {
		p := filepath.Join(dir, name)
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && canExec(p) {
			return p, true
		}
	}
	return "", false
}
