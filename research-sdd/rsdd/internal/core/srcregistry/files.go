package srcregistry

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// SourcesFile is the registry's file name inside a sources directory.
const SourcesFile = "SOURCES.md"

// defaultMode is the mode of a SOURCES.md this package creates (the umask-free default of a text file).
const defaultMode os.FileMode = 0o644

// SHA256Hex is the bare 64-hex sha256 of b.
func SHA256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// Identity is the identity of the document at path: its resolved path, size and "sha256:<hex>" (fsx.Identity
// with no size cap). A symlink, a non-regular file or a file that changed while it was read is an error.
func Identity(path string) (fsx.Ident, error) { return fsx.Identity(path, fsx.NoLimit) }

// FileSHA256 is the bare 64-hex sha256 of the regular file at path, the form the sha256 cell stores.
// It streams the file through crypto/sha256, so it works on every OS (Identity needs a platform file identity that
// is unavailable off Linux); a symlink or a non-regular file is an error, as in Identity.
func FileSHA256(path string) (string, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !fi.Mode().IsRegular() {
		return "", fmt.Errorf("%s is not a regular file", path)
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Append registers row in SOURCES.md of sdir: it creates the document with Header when absent, inserts row at the
// end of the first table (InsertRow) and replaces the file atomically, keeping an existing file's mode.
func Append(sdir, row string) error {
	md, mode, err := read(filepath.Join(sdir, SourcesFile))
	if err != nil {
		return err
	}
	if md == nil {
		md = []byte(Header)
	}
	return write(filepath.Join(sdir, SourcesFile), InsertRow(md, row), mode)
}

// Retarget is RetargetFile on SOURCES.md of sdir; a missing document is not an error (others is 0).
func Retarget(sdir, oldFile, newFile, sha string) (others int, err error) {
	path := filepath.Join(sdir, SourcesFile)
	md, mode, err := read(path)
	if err != nil || md == nil {
		return 0, err
	}
	out, others := RetargetFile(md, oldFile, newFile, sha)
	return others, write(path, out, mode)
}

// Has is HasRow on SOURCES.md of sdir; a missing document has no row.
func Has(sdir, file, sha string) (bool, error) {
	md, _, err := read(filepath.Join(sdir, SourcesFile))
	if err != nil || md == nil {
		return false, err
	}
	return HasRow(md, file, sha), nil
}

// read returns the document and its mode; a missing file is (nil, default, nil), never an empty document.
func read(path string) ([]byte, os.FileMode, error) {
	md, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, defaultMode, nil
	}
	if err != nil {
		return nil, 0, err
	}
	mode := defaultMode
	if fi, err := os.Stat(path); err == nil {
		mode = fi.Mode().Perm()
	}
	return md, mode, nil
}

// write replaces path with b through a sibling temporary file, so a failure leaves the old document intact.
func write(path string, b []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".sources-md-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	_, werr := tmp.Write(b)
	cerr := tmp.Close()
	if err := errors.Join(werr, cerr, os.Chmod(name, mode)); err != nil {
		_ = os.Remove(name)
		return err
	}
	if err := os.Rename(name, path); err != nil {
		_ = os.Remove(name)
		return err
	}
	return nil
}
