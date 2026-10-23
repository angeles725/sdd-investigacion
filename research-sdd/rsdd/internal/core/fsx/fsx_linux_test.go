//go:build linux

package fsx

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func writeFile(t *testing.T, name string, data []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func sum(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

func fdCount(t *testing.T) int {
	t.Helper()
	e, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Fatal(err)
	}
	return len(e)
}

func fcntl(t *testing.T, fd int, cmd int) int {
	t.Helper()
	r, _, e := syscall.Syscall(syscall.SYS_FCNTL, uintptr(fd), uintptr(cmd), 0)
	if e != 0 {
		t.Fatal(e)
	}
	return int(r)
}

func TestOpenROReturnsFdAndStat(t *testing.T) {
	p := writeFile(t, "a", []byte("hello"))
	fd, st, err := OpenRO(p)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(fd)
	if st.Size != 5 || !st.IsRegular() || st.Ino == 0 || st.MtimeNs == 0 {
		t.Fatalf("bad stat %+v", st)
	}
	if fcntl(t, fd, syscall.F_GETFD)&syscall.FD_CLOEXEC == 0 {
		t.Fatal("fd is not close-on-exec")
	}
	if fcntl(t, fd, syscall.F_GETFL)&syscall.O_NONBLOCK == 0 {
		t.Fatal("fd is not O_NONBLOCK")
	}
}

func TestOpenRORefusesSymlink(t *testing.T) {
	p := writeFile(t, "a", []byte("x"))
	l := filepath.Join(filepath.Dir(p), "l")
	if err := os.Symlink(p, l); err != nil {
		t.Fatal(err)
	}
	before := fdCount(t)
	_, _, err := OpenRO(l)
	if !errors.Is(err, ErrOpen) || !errors.Is(err, syscall.ELOOP) {
		t.Fatalf("want ErrOpen+ELOOP, got %v", err)
	}
	if want := "cannot open regular non-symlink file: " + l; err.Error() != want {
		t.Fatalf("message %q != %q", err.Error(), want)
	}
	if fdCount(t) != before {
		t.Fatal("fd leaked")
	}
}

func TestOpenROMissingIsErrOpen(t *testing.T) {
	_, _, err := OpenRO(filepath.Join(t.TempDir(), "nope"))
	if !errors.Is(err, ErrOpen) || !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("got %v", err)
	}
}

func TestOpenRORefusesDirectoryAndClosesFd(t *testing.T) {
	before := fdCount(t)
	_, _, err := OpenRO(t.TempDir())
	if !errors.Is(err, ErrNotRegular) {
		t.Fatalf("got %v", err)
	}
	if fdCount(t) != before {
		t.Fatal("fd leaked on refusal")
	}
}

func TestOpenRORefusesWriterlessFIFOWithoutBlocking(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f")
	if err := syscall.Mkfifo(p, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, _, err := OpenRO(p); done <- err }()
	select {
	case err := <-done:
		if !errors.Is(err, ErrNotRegular) {
			t.Fatalf("got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("OpenRO blocked on a writerless FIFO")
	}
}

func TestIdentityHashesRegularFiles(t *testing.T) {
	big := make([]byte, 3<<20)
	for i := range big {
		big[i] = byte(i * 7)
	}
	for name, data := range map[string][]byte{"empty": {}, "small": []byte("abc"), "3MiB": big} {
		t.Run(name, func(t *testing.T) {
			p := writeFile(t, name, data)
			got, err := Identity(p, NoLimit)
			if err != nil {
				t.Fatal(err)
			}
			want, _ := filepath.EvalSymlinks(p)
			if got.Resolved != want || got.Size != int64(len(data)) || got.SHA256 != "sha256:"+sum(data) {
				t.Fatalf("got %+v want %s %d %s", got, want, len(data), sum(data))
			}
		})
	}
}

func TestIdentityResolvedFollowsParentSymlinks(t *testing.T) {
	p := writeFile(t, "a", []byte("x"))
	link := filepath.Join(t.TempDir(), "dirlink")
	if err := os.Symlink(filepath.Dir(p), link); err != nil {
		t.Fatal(err)
	}
	got, err := Identity(filepath.Join(link, "a"), NoLimit)
	if err != nil {
		t.Fatal(err)
	}
	if want, _ := filepath.EvalSymlinks(p); got.Resolved != want {
		t.Fatalf("resolved %q want %q", got.Resolved, want)
	}
}

func TestIdentityRefusals(t *testing.T) {
	p := writeFile(t, "a", []byte("x"))
	l := filepath.Join(filepath.Dir(p), "l")
	_ = os.Symlink(p, l)
	if _, err := Identity(l, NoLimit); !errors.Is(err, ErrOpen) {
		t.Fatalf("symlink: %v", err)
	}
	if _, err := Identity(t.TempDir(), NoLimit); !errors.Is(err, ErrNotRegular) {
		t.Fatalf("dir: %v", err)
	}
	fifo := filepath.Join(t.TempDir(), "f")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	w, err := syscall.Open(fifo, syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(w)
	if _, err := Identity(fifo, NoLimit); !errors.Is(err, ErrNotRegular) {
		t.Fatalf("fifo: %v", err)
	}
	if _, err := Identity(filepath.Join(t.TempDir(), "nope"), NoLimit); !errors.Is(err, ErrOpen) {
		t.Fatalf("missing: %v", err)
	}
}

func TestErrorUnwrapAndMessage(t *testing.T) {
	e := &Error{Kind: ErrTooLarge}
	if e.Error() != "input exceeds max-input-bytes" || !errors.Is(e, ErrTooLarge) || errors.Is(e, ErrOpen) {
		t.Fatalf("bad error %v", e)
	}
	if !strings.HasSuffix((&Error{Kind: ErrOpen, Path: "/p"}).Error(), ": /p") {
		t.Fatal("path suffix missing")
	}
}
