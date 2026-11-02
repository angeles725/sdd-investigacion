//go:build unix

package floss

import (
	"errors"
	"io"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// flossError is FlossError: a fail-closed refusal of the adapter, printed as "corroborate-floss: <msg>".
type flossError struct{ msg string }

func (e *flossError) Error() string { return e.msg }

func flossErr(msg string) error { return &flossError{msg} }

// afterRead is the test seam between the read and the second fstat.
var afterRead func()

// readStdoutJSON reads the captured floss stdout with the same guards as _read_stdout_json: lstat first (a
// link, or anything that is not a regular file, is refused), then an O_NOFOLLOW open, one read of the size
// seen plus one byte, and a second fstat that must match the first (a file changed while reading is refused).
//
// It returns the parsed document, or (nil, "", nil) when floss printed nothing (an empty file, or the JSON
// text null), or (nil, text, nil) when the file is not JSON: text is the evidence error to record.
func readStdoutJSON(path string) (any, string, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, "", flossErr("cannot stat floss stdout: " + path)
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return nil, "", flossErr("symlink detected at floss output path: " + path)
	}
	if !fi.Mode().IsRegular() {
		return nil, "", flossErr("floss stdout is not a regular file: " + path)
	}
	if fi.Size() == 0 {
		return nil, "", nil
	}
	fd, _, err := fsx.OpenRO(path)
	if err != nil {
		return nil, "", flossErr("cannot open floss stdout (symlink?): " + path)
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	before, err := f.Stat()
	if err != nil {
		return nil, "", err
	}
	buf := make([]byte, max(int64(1), fi.Size()+1))
	n, err := f.Read(buf)
	if err != nil && n == 0 && !errors.Is(err, io.EOF) {
		return nil, "", err
	}
	if afterRead != nil {
		afterRead()
	}
	after, err := f.Stat()
	if err != nil {
		return nil, "", err
	}
	if !os.SameFile(before, after) || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return nil, "", flossErr("floss stdout changed while reading (TOCTOU)")
	}
	if n == 0 {
		return nil, "", nil
	}
	v, err := decodePyJSON(buf[:n])
	if err != nil {
		var je *jsonError
		if errors.As(err, &je) {
			return nil, "malformed JSON in floss stdout: " + je.Error(), nil
		}
		return nil, "", flossErr(err.Error())
	}
	return v, "", nil
}
