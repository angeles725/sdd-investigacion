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

func errnoOf(err error) int {
	var e syscall.Errno
	if errors.As(err, &e) {
		return int(e)
	}
	return 0
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

func TestParityOpenRO(t *testing.T) {
	dir := t.TempDir()
	reg := filepath.Join(dir, "r")
	_ = os.WriteFile(reg, []byte("abc"), 0o644)
	link := filepath.Join(dir, "l")
	_ = os.Symlink(reg, link)
	fifo := filepath.Join(dir, "f") // no writer: both sides use O_NONBLOCK so neither blocks
	_ = syscall.Mkfifo(fifo, 0o600)
	for name, p := range map[string]string{"regular": reg, "symlink": link, "dir": dir, "fifo": fifo, "missing": filepath.Join(dir, "x")} {
		t.Run(name, func(t *testing.T) {
			py := runPy(t, "open_ro", p)
			fd, st, err := OpenRO(p)
			if err == nil {
				_ = syscall.Close(fd)
			}
			switch {
			case !py.OK: // Python's open itself failed: Go must fail with the same errno as ErrOpen
				if !errors.Is(err, ErrOpen) || errnoOf(err) != py.Errno {
					t.Fatalf("python errno %d go %v", py.Errno, err)
				}
			case py.Regular: // Python opened a regular file
				if err != nil || st.Size != py.Size {
					t.Fatalf("go %v %+v", err, st)
				}
			default: // Python opened a non-regular file (its caller then refuses): Go refuses here
				if !errors.Is(err, ErrNotRegular) {
					t.Fatalf("go %v", err)
				}
			}
		})
	}
}

func TestParityOpenWONew(t *testing.T) {
	old := syscall.Umask(0)
	defer syscall.Umask(old)
	dir := t.TempDir()
	existing := filepath.Join(dir, "e")
	_ = os.WriteFile(existing, nil, 0o644)
	link := filepath.Join(dir, "l")
	_ = os.Symlink(filepath.Join(dir, "gone"), link)
	for name, p := range map[string]string{"new": filepath.Join(dir, "n"), "existing": existing, "symlink": link} {
		t.Run(name, func(t *testing.T) {
			py := runPy(t, "open_wo_new", p)
			// run Go on a sibling path so both sides see the same pre-state
			gp := p
			if name == "new" {
				gp = filepath.Join(dir, "n-go")
			}
			fd, err := OpenWONew(gp)
			if err == nil {
				_ = syscall.Close(fd)
			}
			if py.OK != (err == nil) {
				t.Fatalf("python %+v go %v", py, err)
			}
			if err != nil && errnoOf(err) != py.Errno {
				t.Fatalf("errno python %d go %v", py.Errno, err)
			}
			if err == nil {
				if st, _ := os.Stat(gp); uint32(st.Mode().Perm()) != py.Mode {
					t.Fatalf("mode python %o go %o", py.Mode, st.Mode().Perm())
				}
			}
		})
	}
}

func TestParitySHA256FD(t *testing.T) {
	data := bytes.Repeat([]byte("xyz"), 100000)
	p := writeFile(t, "a", data)
	py := runPy(t, "sha256_fd", p)
	fd, _, err := OpenRO(p)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(fd)
	got, err := SHA256FD(fd)
	if err != nil || got != py.SHA256 {
		t.Fatalf("python %q go %q %v", py.SHA256, got, err)
	}
}

func TestParityPublish(t *testing.T) {
	setup := func(dir string, destExists bool) (string, string) {
		_ = os.WriteFile(filepath.Join(dir, "stage"), []byte("S"), 0o644)
		if destExists {
			_ = os.WriteFile(filepath.Join(dir, "dest"), []byte("D"), 0o644)
		}
		return filepath.Join(dir, "stage"), filepath.Join(dir, "dest")
	}
	for name, exists := range map[string]bool{"fresh": false, "existing dest": true} {
		t.Run(name, func(t *testing.T) {
			ps, pd := setup(t.TempDir(), exists)
			gs, gd := setup(t.TempDir(), exists)
			py := runPy(t, "publish", ps, pd)
			err := Publish(gs, gd)
			if py.OK != (err == nil) || (err != nil && (errnoOf(err) != py.Errno || !errors.Is(err, syscall.EEXIST))) {
				t.Fatalf("python %+v go %v", py, err)
			}
			for _, pair := range [][2]string{{ps, gs}, {pd, gd}} {
				a, _ := os.ReadFile(pair[0])
				b, _ := os.ReadFile(pair[1])
				if !bytes.Equal(a, b) {
					t.Fatalf("state differs for %s: %q vs %q", pair[0], a, b)
				}
			}
		})
	}
}

func TestParityExchange(t *testing.T) {
	setup := func(dir string) (string, string) {
		_ = os.WriteFile(filepath.Join(dir, "a"), []byte("A"), 0o644)
		_ = os.WriteFile(filepath.Join(dir, "b"), []byte("B"), 0o644)
		return filepath.Join(dir, "a"), filepath.Join(dir, "b")
	}
	pa, pb := setup(t.TempDir())
	ga, gb := setup(t.TempDir())
	if py := runPy(t, "exchange", pa, pb); !py.OK {
		t.Fatalf("python %+v", py)
	}
	if err := RenameExchange(ga, gb); err != nil {
		t.Fatal(err)
	}
	for _, pair := range [][2]string{{pa, ga}, {pb, gb}} {
		a, _ := os.ReadFile(pair[0])
		b, _ := os.ReadFile(pair[1])
		if !bytes.Equal(a, b) {
			t.Fatalf("exchange state differs: %q vs %q", a, b)
		}
	}
	// a missing counterpart: both fail with the same errno and create nothing
	pm, gm := filepath.Join(filepath.Dir(pa), "missing"), filepath.Join(filepath.Dir(ga), "missing")
	py := runPy(t, "exchange", pa, pm)
	err := RenameExchange(ga, gm)
	if py.OK || err == nil || errnoOf(err) != py.Errno || exists(pm) || exists(gm) {
		t.Fatalf("python %+v go %v", py, err)
	}
}

func TestParityWrite(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)
	pd, gd := t.TempDir(), t.TempDir()
	py := runPy(t, "write", filepath.Join(pd, "o.json"), `{"b":[1,2],"a":"x"}`)
	if err := WriteAtomic(filepath.Join(gd, "o.json"), []byte(`{"a":"x","b":[1,2]}`+"\n")); err != nil {
		t.Fatal(err)
	}
	a, _ := os.ReadFile(filepath.Join(pd, "o.json"))
	b, _ := os.ReadFile(filepath.Join(gd, "o.json"))
	st, _ := os.Stat(filepath.Join(gd, "o.json"))
	if !bytes.Equal(a, b) || uint32(st.Mode().Perm()) != py.Mode {
		t.Fatalf("python %q mode %o; go %q mode %o", a, py.Mode, b, st.Mode().Perm())
	}
	pe, _ := os.ReadDir(pd)
	ge, _ := os.ReadDir(gd)
	if len(pe) != 1 || len(ge) != 1 {
		t.Fatalf("leftovers python %d go %d", len(pe), len(ge))
	}
}
