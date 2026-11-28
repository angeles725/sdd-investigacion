package console

import (
	"fmt"
	"io"
	"os"
	"syscall"
)

// tee is `tee -- "$OUT"` as the script used it: every byte goes to stdout and to the evidence file. When the file
// cannot be created or written, tee names the path on stderr once, keeps feeding stdout, and ends with status 1.
type tee struct {
	e    *env
	path string
	f    *os.File
	rc   int
}

func (e *env) openTee(path string) *tee {
	t := &tee{e: e, path: path}
	f, err := os.OpenFile(e.at(path), os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		t.fail(err)
		return t
	}
	t.f = f
	return t
}

func (t *tee) fail(err error) {
	t.rc = 1
	fmt.Fprintf(t.e.s.Err, "tee: %s: %s\n", t.e.quoteShell(t.path), errText(err))
}

func (t *tee) Write(p []byte) (int, error) {
	if t.f != nil {
		if _, err := t.f.Write(p); err != nil {
			_ = t.f.Close()
			t.f = nil
			t.fail(err)
		}
	}
	_, _ = t.e.s.Out.Write(p) // tee goes on when stdout fails; the preserved line below is what a reader checks
	return len(p), nil
}

// close ends the file and returns tee's exit status.
func (t *tee) close() int {
	if t.f != nil {
		if err := t.f.Close(); err != nil {
			t.fail(err)
		}
		t.f = nil
	}
	return t.rc
}

var _ io.Writer = (*tee)(nil)

// errText is strerror for the errno behind err.
func errText(err error) string {
	if en, ok := errnoOf(err); ok {
		return strerror(en)
	}
	return err.Error()
}

// mkdirAll is `mkdir -p -- dir`: it creates every missing component in order and, on the first it cannot make,
// returns that component as typed (the prefix of dir up to its end, slashes kept) and the errno mkdir would
// report. A component that exists as something other than a directory is "Not a directory" when more
// components follow it and "File exists" when it is the last one, as coreutils reports them.
func (e *env) mkdirAll(dir string) (string, error) {
	ends := []int{}
	for i := 1; i < len(dir); i++ {
		if dir[i] == '/' && hasNonSlash(dir[i:]) { // a repeated slash only repeats the prefix before it
			ends = append(ends, i)
		}
	}
	ends = append(ends, len(dir))
	for _, end := range ends {
		p := dir[:end]
		if fi, err := os.Stat(e.at(p)); err == nil && fi.IsDir() {
			continue
		}
		err := os.Mkdir(e.at(p), 0o777)
		if err == nil {
			continue
		}
		if fi, serr := os.Stat(e.at(p)); serr == nil {
			if fi.IsDir() { // made by someone else meanwhile
				continue
			}
			if end != len(dir) {
				return p, errnoError(syscall.ENOTDIR)
			}
		}
		if en, ok := errnoOf(err); ok {
			return p, errnoError(en)
		}
		return p, err
	}
	return "", nil
}

func hasNonSlash(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] != '/' {
			return true
		}
	}
	return false
}

// errnoError wraps an errno so that printing it gives strerror's text.
type errnoError syscall.Errno

func (e errnoError) Error() string { return strerror(syscall.Errno(e)) }
