package bog

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// File is one .bog read in full from a regular, non-symlink path.
type File struct {
	Data []byte
	// Size is the length the kernel reported for the open file.
	Size int64
	// SHA256 is the bare lowercase hex digest of Data (the evidence schema's input.sha256).
	SHA256 string
}

// ReadError is a refused or failed read. Msg is the strerror-style text the legacy tools print after the path
// ("No such file or directory", "is a symbolic link (rejected)", "not a regular file (rejected)"). IO is true
// when the failure came after a successful open (a read or fstat error), which the legacy tools report as
// "I/O error" rather than against the path.
type ReadError struct {
	Path string
	Msg  string
	IO   bool
}

func (e *ReadError) Error() string { return e.Path + ": " + e.Msg }

// ReadFile opens path read-only without following a final symlink and without blocking on a FIFO
// (fsx.OpenRO), refuses anything that is not a regular file, and reads it whole. The digest is taken over the
// same bytes that are returned, so the evidence hash and the parsed content cannot disagree.
func ReadFile(path string) (File, error) {
	fd, st, err := fsx.OpenRO(path)
	if err != nil {
		switch {
		case errors.Is(err, fsx.ErrNotRegular):
			return File{}, &ReadError{Path: path, Msg: "not a regular file (rejected)"}
		case errors.Is(err, fsx.ErrOpen):
			if errors.Is(err, syscall.ELOOP) {
				return File{}, &ReadError{Path: path, Msg: "is a symbolic link (rejected)"}
			}
			return File{}, &ReadError{Path: path, Msg: StrError(err)}
		default:
			return File{}, &ReadError{Path: path, Msg: StrError(err), IO: true}
		}
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	data, err := io.ReadAll(f)
	if err != nil {
		return File{}, &ReadError{Path: path, Msg: StrError(err), IO: true}
	}
	sum := sha256.Sum256(data)
	return File{Data: data, Size: st.Size, SHA256: hex.EncodeToString(sum[:])}, nil
}

// StrError renders an error the way Python's OSError.strerror does for the legacy messages: the C library's
// text for the underlying errno, capitalised (Go's table is the same text in lower case). Errors that carry no
// errno render their own message, capitalised.
func StrError(err error) string {
	var errno syscall.Errno
	text := err.Error()
	if errors.As(err, &errno) {
		text = errno.Error()
	}
	r, size := utf8.DecodeRuneInString(text)
	return string(unicode.ToUpper(r)) + strings.TrimPrefix(text, text[:size])
}
