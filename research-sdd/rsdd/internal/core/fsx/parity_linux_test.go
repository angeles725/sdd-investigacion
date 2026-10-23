//go:build linux

package fsx

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
)

// pyResult is the driver's JSON object.
type pyResult struct {
	OK       bool   `json:"ok"`
	Class    string `json:"class"`
	Msg      string `json:"msg"`
	Errno    int    `json:"errno"`
	Resolved string `json:"resolved"`
	Size     int64  `json:"size"`
	SHA256   string `json:"sha256"`
	Regular  bool   `json:"regular"`
	Mode     uint32 `json:"mode"`
	Src      rec    `json:"src"`
	Staged   rec    `json:"staged"`
}

type rec struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

const toolbeltDir = "../../../../toolbelt"

// runPy runs the real Python helper through testdata/parity_driver.py. A
// missing python3 FAILS the test: a skipped parity test proves nothing.
func runPy(t *testing.T, op string, args ...string) pyResult {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	tb, err := filepath.Abs(toolbeltDir)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(py, append([]string{"-I", "testdata/parity_driver.py", tb, op}, args...)...)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("driver %s failed: %v\n%s", op, err, stderr.String())
	}
	var r pyResult
	if err := json.Unmarshal(out.Bytes(), &r); err != nil {
		t.Fatalf("driver output %q: %v", out.String(), err)
	}
	return r
}

func TestParityIdentity(t *testing.T) {
	dir := t.TempDir()
	mk := func(name string, data []byte) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, data, 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	big := bytes.Repeat([]byte("0123456789abcdef"), 3<<16) // 3 MiB
	fifo := filepath.Join(dir, "fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	w, err := syscall.Open(fifo, syscall.O_RDWR, 0) // a connected FIFO: Python's blocking open returns
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(w)
	link := filepath.Join(dir, "link")
	if err := os.Symlink(mk("target", []byte("t")), link); err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"empty": mk("empty", nil), "small": mk("small", []byte("abc")), "3MiB": mk("big", big),
		"symlink": link, "dir": dir, "fifo": fifo, "missing": filepath.Join(dir, "nope"),
	}
	for name, p := range cases {
		t.Run(name, func(t *testing.T) {
			py := runPy(t, "identity", p)
			got, err := Identity(p, NoLimit)
			if py.OK != (err == nil) {
				t.Fatalf("python ok=%v (%s) go err=%v", py.OK, py.Msg, err)
			}
			if err != nil {
				if err.Error() != py.Msg {
					t.Fatalf("message python %q go %q", py.Msg, err.Error())
				}
				return
			}
			if got.Resolved != py.Resolved || got.Size != py.Size || got.SHA256 != py.SHA256 {
				t.Fatalf("python %+v go %+v", py, got)
			}
		})
	}
}

func TestParityIdentityMaxBytes(t *testing.T) {
	p := writeFile(t, "a", []byte("12345"))
	for _, max := range []int64{4, 5, 6} {
		py := runPy(t, "identity", p, itoa(max))
		_, err := Identity(p, max)
		if py.OK != (err == nil) || (err != nil && err.Error() != py.Msg) {
			t.Fatalf("max=%d python %+v go %v", max, py, err)
		}
	}
}

func itoa(n int64) string { b, _ := json.Marshal(n); return string(b) }

func TestParityIdentityChangedWhileHashing(t *testing.T) {
	big := bytes.Repeat([]byte{1}, 3<<20)
	pyPath := writeFile(t, "py", big)
	goPath := writeFile(t, "go", big)
	py := runPy(t, "identity_append", pyPath)
	n := 0
	setHook(t, func() {
		if n++; n == 1 {
			appendTo(t, goPath, []byte("more"))
		}
	})
	_, err := Identity(goPath, NoLimit)
	if py.OK || !errors.Is(err, ErrChanged) {
		t.Fatalf("python %+v go %v", py, err)
	}
	if want := "file changed while hashing: " + pyPath; py.Msg != want {
		t.Fatalf("python message %q", py.Msg)
	}
}
