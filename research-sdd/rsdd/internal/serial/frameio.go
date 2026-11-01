package serial

import (
	"errors"
	"io"
	"os"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// File helpers shared by serial-frame-analyze and serial-frame-capture: a no-follow read-only open for the
// frame log, and an exclusive no-follow create for every output file. Both report failures as the text Python's
// OSError.strerror gave, so the "<tool>: <path>: <reason>" stderr line stays the same.

// ioReason is the reason text of a file-system failure: strerror of the errno inside err. A symlink refused by
// O_NOFOLLOW (ELOOP) keeps the legacy message, which is the same for the input and for a looping path.
func ioReason(err error, input bool) string {
	var fe *fsx.Error
	if errors.As(err, &fe) && errors.Is(fe.Kind, fsx.ErrNotRegular) {
		return notRegularReason(fe.Path)
	}
	if en, ok := errnoOf(err); ok {
		if input && en == syscall.ELOOP {
			return "is a symbolic link (rejected)"
		}
		return strerror(en)
	}
	return err.Error()
}

// notRegularReason names why a path that opened is still refused: a directory reads as EISDIR in Python (the
// first read fails); any other non-regular file (FIFO, device, socket) has no Python equivalent - a FIFO would
// block the open forever - and is refused with a typed reason.
func notRegularReason(path string) string {
	if st, err := os.Stat(path); err == nil && st.IsDir() {
		return strerror(syscall.EISDIR)
	}
	return "not a regular file"
}

// readLogFile opens path read-only without following a symlink, hashes the whole file and returns its first
// maxRead bytes. size is the file's st_size, so the caller can tell that the cap was hit.
func readLogFile(path string, maxRead int64) (data []byte, size int64, sha string, err error) {
	fd, st, err := fsx.OpenRO(path)
	if err != nil {
		return nil, 0, "", err
	}
	f := os.NewFile(uintptr(fd), path)
	defer func() { _ = f.Close() }()
	if sha, err = fsx.SHA256FD(fd); err != nil {
		return nil, 0, "", err
	}
	if _, err = f.Seek(0, io.SeekStart); err != nil {
		return nil, 0, "", err
	}
	data, err = io.ReadAll(io.LimitReader(f, min(st.Size, maxRead)))
	if err != nil {
		return nil, 0, "", err
	}
	return data, st.Size, sha, nil
}

// writeNew creates path exclusively (O_CREAT|O_EXCL|O_NOFOLLOW, mode 0600) and writes content to it.
func writeNew(path string, content []byte) error {
	fd, err := fsx.OpenWONew(path)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fd), path)
	_, err = f.Write(content)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// writeJSON writes doc as the key-sorted indent=2 JSON the legacy _write_json produced.
func writeJSON(path string, doc map[string]any) error {
	content, err := jsonout.Indented(doc)
	if err != nil {
		return err
	}
	return writeNew(path, content)
}
