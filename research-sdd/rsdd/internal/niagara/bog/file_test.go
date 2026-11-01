package bog

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// readErr runs ReadFile and returns its error; a nil error is reported as a nil *ReadError.
func readErr(path string) (*ReadError, error) {
	_, err := ReadFile(path)
	var re *ReadError
	if !errors.As(err, &re) {
		return nil, err
	}
	return re, nil
}

func TestReadFileRegular(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a.bog")
	content := []byte("<bajaObjectGraph/>")
	if err := os.WriteFile(p, content, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(content)
	if string(f.Data) != string(content) || f.Size != int64(len(content)) || f.SHA256 != hex.EncodeToString(sum[:]) {
		t.Errorf("File = %q size %d sha %s", f.Data, f.Size, f.SHA256)
	}
}

func TestReadFileEmptyIsNotAbsent(t *testing.T) {
	p := filepath.Join(t.TempDir(), "empty.bog")
	if err := os.WriteFile(p, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := ReadFile(p)
	if err != nil || f.Size != 0 || len(f.Data) != 0 {
		t.Fatalf("empty regular file: %+v, %v", f, err)
	}
	if f.SHA256 != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
		t.Errorf("sha256 of empty input = %s", f.SHA256)
	}
}

func TestReadFileRefusals(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real.bog")
	if err := os.WriteFile(target, []byte("<a/>"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.bog")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "in.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name, path, msg string
		io              bool
	}{
		{"absent", filepath.Join(dir, "nope.bog"), "No such file or directory", false},
		{"symlink", link, "is a symbolic link (rejected)", false},
		{"directory", dir, "not a regular file (rejected)", false},
		{"fifo", fifo, "not a regular file (rejected)", false},
		{"path through a regular file", filepath.Join(target, "x"), "Not a directory", false},
		{"empty path", "", "No such file or directory", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			type result struct {
				re  *ReadError
				err error
			}
			done := make(chan result, 1)
			go func() { re, err := readErr(tt.path); done <- result{re, err} }()
			select {
			case r := <-done:
				re := r.re
				if re == nil {
					t.Fatalf("ReadFile(%s) error = %v, want *ReadError", tt.path, r.err)
				}
				if re.Msg != tt.msg || re.IO != tt.io || re.Path != tt.path {
					t.Errorf("ReadError = %+v, want msg %q io %v path %q", re, tt.msg, tt.io, tt.path)
				}
				if re.Error() != tt.path+": "+tt.msg {
					t.Errorf("Error() = %q", re.Error())
				}
			case <-time.After(5 * time.Second):
				t.Fatal("ReadFile hung (a FIFO without a writer must be refused, not opened blocking)")
			}
		})
	}
}

func TestStrError(t *testing.T) {
	tests := []struct {
		err  error
		want string
	}{
		{syscall.ENOENT, "No such file or directory"},
		{syscall.EACCES, "Permission denied"},
		{syscall.EEXIST, "File exists"},
		{syscall.ELOOP, "Too many levels of symbolic links"},
		{&os.PathError{Op: "open", Path: "x", Err: syscall.EROFS}, "Read-only file system"},
		{errors.New("plain"), "Plain"},
	}
	for _, tt := range tests {
		if got := StrError(tt.err); got != tt.want {
			t.Errorf("StrError(%v) = %q, want %q", tt.err, got, tt.want)
		}
	}
}
