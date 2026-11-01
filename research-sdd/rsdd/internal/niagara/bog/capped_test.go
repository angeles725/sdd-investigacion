package bog

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

func writeTemp(t *testing.T, data []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "f.bog")
	if err := os.WriteFile(p, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// ReadFileCapped reads at most max bytes: the evidence (hash, data) covers what was read, Size is the file's size.
func TestReadFileCappedStopsAtTheCap(t *testing.T) {
	content := bytes.Repeat([]byte("0123456789"), 100)
	p := writeTemp(t, content)
	tests := []struct {
		name string
		max  int64
		want int
	}{
		{"below the size", 10, 10},
		{"exactly the size", 1000, 1000},
		{"above the size", 5000, 1000},
		{"zero reads nothing", 0, 0},
		{"a negative cap reads nothing", -5, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f, err := ReadFileCapped(p, tt.max)
			if err != nil {
				t.Fatal(err)
			}
			sum := sha256.Sum256(content[:tt.want])
			if len(f.Data) != tt.want || f.Size != 1000 || f.SHA256 != hex.EncodeToString(sum[:]) {
				t.Errorf("len %d size %d sha %s, want len %d size 1000 sha of the prefix", len(f.Data), f.Size, f.SHA256, tt.want)
			}
		})
	}
}

// A huge file must not be read in full: the cap bounds the allocation, not just the returned slice.
func TestReadFileCappedDoesNotReadPastTheCap(t *testing.T) {
	p := filepath.Join(t.TempDir(), "sparse.bog")
	fh, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := fh.Truncate(256 << 20); err != nil { // 256 MiB sparse
		t.Skipf("sparse file not supported here: %v", err)
	}
	fh.Close()
	f, err := ReadFileCapped(p, 4096)
	if err != nil || len(f.Data) != 4096 || f.Size != 256<<20 {
		t.Fatalf("len %d size %d err %v", len(f.Data), f.Size, err)
	}
}

func TestReadFileCappedRefusals(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real")
	if err := os.WriteFile(target, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	tests := []struct{ name, path, msg string }{
		{"absent", filepath.Join(dir, "nope"), "No such file or directory"},
		{"symlink", link, "is a symbolic link (rejected)"},
		{"directory", dir, "not a regular file (rejected)"},
		{"fifo", fifo, "not a regular file (rejected)"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			done := make(chan error, 1)
			go func() { _, err := ReadFileCapped(tt.path, 10); done <- err }()
			select {
			case err := <-done:
				re, ok := err.(*ReadError)
				if !ok || re.Msg != tt.msg || re.Path != tt.path {
					t.Errorf("error = %#v, want ReadError %q", err, tt.msg)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("hung on a FIFO")
			}
		})
	}
}

func TestOpenHandleReadsHeadAndZip(t *testing.T) {
	data := bogtest.Bog(bogtest.ValidXML)
	p := writeTemp(t, data)
	h, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	if h.Size != int64(len(data)) {
		t.Errorf("Size = %d, want %d", h.Size, len(data))
	}
	head, err := h.Head(8)
	if err != nil || !bytes.Equal(head, data[:8]) {
		t.Errorf("Head(8) = %q, %v", head, err)
	}
	head, err = h.Head(1 << 30)
	if err != nil || !bytes.Equal(head, data) {
		t.Errorf("Head(huge) returns %d bytes, %v; want the whole file", len(head), err)
	}
	z, err := h.Zip()
	if err != nil {
		t.Fatal(err)
	}
	body, trunc, err := z.ReadMember("file.xml", MaxInflate)
	if err != nil || trunc || !bytes.Contains(body, []byte("bajaObjectGraph")) {
		t.Errorf("ReadMember = %q, %v, %v", body, trunc, err)
	}
}

func TestOpenRefusesWhatReadFileRefuses(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real")
	if err := os.WriteFile(target, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	for name, path := range map[string]string{"symlink": link, "directory": dir, "absent": filepath.Join(dir, "nope")} {
		if h, err := Open(path); err == nil {
			h.Close()
			t.Errorf("Open(%s) succeeded, want a refusal", name)
		}
	}
}

func TestHandleZipOfANonArchiveIsErrNotZip(t *testing.T) {
	h, err := Open(writeTemp(t, []byte("<a/>")))
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	if _, err := h.Zip(); err != ErrNotZip {
		t.Errorf("Zip() error = %v, want ErrNotZip", err)
	}
}

func TestOpenZipAtMatchesOpenZip(t *testing.T) {
	data := bogtest.Zip(bogtest.Entry{Name: "a", Data: []byte("1")}, bogtest.Entry{Name: "dir/", Data: nil}, bogtest.Entry{Name: "file.xml", Data: []byte("<a/>")})
	z1, err1 := OpenZip(data)
	z2, err2 := OpenZipAt(bytes.NewReader(data), int64(len(data)))
	if err1 != nil || err2 != nil {
		t.Fatal(err1, err2)
	}
	got, want := z2.Names(), z1.Names()
	if len(got) != 3 || len(want) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Errorf("OpenZipAt names %v, OpenZip names %v", got, want)
	}
	if _, err := OpenZipAt(bytes.NewReader([]byte("nope")), 4); err != ErrNotZip {
		t.Errorf("garbage: %v", err)
	}
}

func TestPyReprPath(t *testing.T) {
	tests := []struct{ in, want string }{
		{"/tmp/o.json", "'/tmp/o.json'"},
		{"", "''"},
		{"it's", `"it's"`},
		{`a"b'c`, `'a"b\'c'`},
		{"tab\there", `'tab\there'`},
		{"bad\xffbyte", `'bad\udcffbyte'`},
		{"é", "'é'"},
		{"nul\x00", `'nul\x00'`},
	}
	for _, tt := range tests {
		if got := PyReprPath(tt.in); got != tt.want {
			t.Errorf("PyReprPath(%q) = %s, want %s", tt.in, got, tt.want)
		}
	}
}
