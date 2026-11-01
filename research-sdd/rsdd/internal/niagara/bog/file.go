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

// readError maps an fsx failure to the strerror-style ReadError of the legacy tools.
func readError(path string, err error) *ReadError {
	switch {
	case errors.Is(err, fsx.ErrNotRegular):
		return &ReadError{Path: path, Msg: "not a regular file (rejected)"}
	case errors.Is(err, fsx.ErrOpen):
		if errors.Is(err, syscall.ELOOP) {
			return &ReadError{Path: path, Msg: "is a symbolic link (rejected)"}
		}
		return &ReadError{Path: path, Msg: StrError(err)}
	default:
		return &ReadError{Path: path, Msg: StrError(err), IO: true}
	}
}

// Handle is an open regular file that can be read at any offset: the reader for files that may be far larger
// than the part a tool inspects (a module JAR, a station backup whose central directory sits at the end).
type Handle struct {
	f *os.File
	// Size is the length the kernel reported for the open file.
	Size int64
}

// Open opens path read-only without following a final symlink and without blocking on a FIFO (fsx.OpenRO) and
// refuses anything that is not a regular file. The refusals are the *ReadError values ReadFile returns.
func Open(path string) (*Handle, error) {
	fd, st, err := fsx.OpenRO(path)
	if err != nil {
		return nil, readError(path, err)
	}
	return &Handle{f: os.NewFile(uintptr(fd), path), Size: st.Size}, nil
}

// Close releases the file.
func (h *Handle) Close() error { return h.f.Close() }

// Head reads the first min(Size, max) bytes. The buffer grows with what is actually read, so a file that is
// larger than max (or lies about its size) never costs more than max bytes.
func (h *Handle) Head(max int64) ([]byte, error) {
	if max < 0 {
		max = 0
	}
	data, err := io.ReadAll(io.NewSectionReader(h.f, 0, min(h.Size, max)))
	if err != nil {
		return nil, &ReadError{Path: h.f.Name(), Msg: StrError(err), IO: true}
	}
	return data, nil
}

// Zip reads the central directory of the file without loading the archive into memory.
func (h *Handle) Zip() (*Zip, error) { return OpenZipAt(h.f, h.Size) }

// ReadFile opens path (see Open) and reads it whole. The digest is taken over the same bytes that are returned,
// so the evidence hash and the parsed content cannot disagree.
func ReadFile(path string) (File, error) {
	h, err := Open(path)
	if err != nil {
		return File{}, err
	}
	defer h.Close()
	data, err := io.ReadAll(h.f)
	if err != nil {
		return File{}, &ReadError{Path: path, Msg: StrError(err), IO: true}
	}
	return fileOf(data, h.Size), nil
}

// ReadFileCapped is ReadFile for a tool that inspects only the first max bytes (the 4 MiB plaintext cap of the
// security audit, its 512 KiB properties cap). Data and SHA256 cover the bytes read; Size is the file's full
// size, so a caller sees truncation as len(Data) < Size.
func ReadFileCapped(path string, max int64) (File, error) {
	h, err := Open(path)
	if err != nil {
		return File{}, err
	}
	defer h.Close()
	data, err := h.Head(max)
	if err != nil {
		return File{}, err
	}
	return fileOf(data, h.Size), nil
}

// SHA256 is the bare lowercase hex digest of the whole file, streamed: the evidence hash of a station backup
// that may be far larger than the part a tool reads.
func (h *Handle) SHA256() (string, error) {
	sum := sha256.New()
	if _, err := io.Copy(sum, io.NewSectionReader(h.f, 0, h.Size)); err != nil {
		return "", &ReadError{Path: h.f.Name(), Msg: StrError(err), IO: true}
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

func fileOf(data []byte, size int64) File {
	sum := sha256.Sum256(data)
	return File{Data: data, Size: size, SHA256: hex.EncodeToString(sum[:])}
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
