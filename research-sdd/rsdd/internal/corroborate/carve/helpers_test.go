package carve

import (
	"bytes"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// TestMain lets the test binary stand in for rsdd: as the rlimit re-exec helper (what launchWorker starts)
// and as `rsdd corroborate carve` itself (the sandboxed worker of a real bubblewrap run).
func TestMain(m *testing.M) {
	switch {
	case len(os.Args) > 1 && os.Args[1] == proc.HelperCommand:
		os.Exit(proc.HelperMain(os.Args[2:], os.Environ(), os.Stderr))
	case len(os.Args) > 3 && os.Args[1] == "corroborate" && os.Args[2] == "carve":
		s, err := cli.OSStdio()
		if err != nil {
			os.Exit(1)
		}
		os.Exit(Run(os.Args[3:], s))
	}
	os.Exit(m.Run())
}

const uimagePayload = "UIMAGE-PAYLOAD"

// uimage is a 64-byte uImage header followed by its payload, both CRCs valid.
func uimage(payload string) []byte {
	h := make([]byte, 64)
	be := binary.BigEndian
	be.PutUint32(h[0:], 0x27051956)
	be.PutUint32(h[12:], uint32(len(payload)))
	be.PutUint32(h[24:], crc32.ChecksumIEEE([]byte(payload)))
	copy(h[28:32], []byte{5, 2, 2, 0})
	copy(h[32:36], "test")
	be.PutUint32(h[4:], crc32.ChecksumIEEE(h))
	return append(h, payload...)
}

// squashfs is a 160-byte SquashFS v4 little-endian image: a valid superblock and nothing behind it.
func squashfs() []byte {
	s := make([]byte, 160)
	le := binary.LittleEndian
	le.PutUint32(s[0:], 0x73717368)
	le.PutUint32(s[4:], 1)     // inodes
	le.PutUint32(s[12:], 4096) // block size
	le.PutUint16(s[20:], 1)    // compression
	le.PutUint16(s[22:], 12)   // block log
	le.PutUint16(s[26:], 1)    // ids
	le.PutUint16(s[28:], 4)    // major
	le.PutUint64(s[40:], 160)  // bytes used
	le.PutUint64(s[48:], 128)  // id table
	le.PutUint64(s[56:], noTable)
	le.PutUint64(s[64:], 96)  // inode table
	le.PutUint64(s[72:], 120) // directory table
	le.PutUint64(s[80:], noTable)
	le.PutUint64(s[88:], noTable)
	return s
}

// firmwareImage is a uImage at offset 4 and a SquashFS behind a gap.
func firmwareImage() []byte {
	return bytes.Join([][]byte{[]byte("PFX!"), uimage(uimagePayload), []byte("GAP!"), squashfs()}, nil)
}

const (
	uimageAt   = 4
	squashAt   = 4 + 64 + len(uimagePayload) + 4
	reportName = "firmware-carve.v1.json"
)

// world is one hermetic run: a scratch directory, injected deps and captured streams.
type world struct {
	t    *testing.T
	root string
	d    deps
	out  *bytes.Buffer
	err  *bytes.Buffer
}

func newWorld(t *testing.T) *world {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("the carve refuses root; run the tests as an unprivileged user")
	}
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil { // TempDir honours the umask; the carve wants a parent nobody else can write
		t.Fatal(err)
	}
	w := &world{t: t, root: root, out: &bytes.Buffer{}, err: &bytes.Buffer{}}
	w.d = deps{
		creds:     adapter.CurrentCreds,
		mountinfo: func() (string, error) { return "1 0 0:1 / / rw - ext4 disk rw\n", nil },
		bwrap:     func() (string, string, error) { return "/usr/bin/bwrap", "sha256:" + strings.Repeat("ab", 32), nil },
		syncDir:   fsx.SyncDir,
		self:      func() (string, error) { return "/rsdd", nil },
	}
	w.d.launch = func(sp launchSpec) error { return w.inProcess(sp) }
	return w
}

// inProcess is the stand-in for the sandbox: it runs the worker half in this process against the stage the
// real worker would see mounted at /tmp/work, and reports its failure the way launchWorker does.
func (w *world) inProcess(sp launchSpec) error {
	i := slices.Index(sp.argv, "--")
	args := slices.Clone(sp.argv[i+1+3:]) // after: -- self corroborate carve
	for j, a := range args {
		if a == "/tmp/work" && args[j-1] == "--stage" {
			args[j] = sp.dir
		}
	}
	var stderr bytes.Buffer
	if code := execute(args, cli.Stdio{Out: io.Discard, Err: &stderr}, w.d); code != 0 {
		return errors.New("isolated worker failed: " + strings.TrimSpace(stderr.String()))
	}
	return nil
}

func (w *world) path(name string) string { return filepath.Join(w.root, name) }

func (w *world) write(name string, data []byte) string {
	w.t.Helper()
	if err := os.WriteFile(w.path(name), data, 0o644); err != nil {
		w.t.Fatal(err)
	}
	return w.path(name)
}

// carve runs `rsdd corroborate carve --input <input> --output <out> extra...` and returns the exit code.
func (w *world) carve(input, out string, extra ...string) int {
	w.t.Helper()
	w.out.Reset()
	w.err.Reset()
	args := append([]string{"--input", input, "--output", out}, extra...)
	return execute(args, cli.Stdio{Out: w.out, Err: w.err, Cwd: w.root, Environ: os.Environ, Clock: time.Now}, w.d)
}

func (w *world) exists(name string) bool {
	_, err := os.Lstat(w.path(name))
	return err == nil
}

// mustCarve runs a carve that has to succeed.
func (w *world) mustCarve(input, out string, extra ...string) {
	w.t.Helper()
	if code := w.carve(input, out, extra...); code != 0 {
		w.t.Fatalf("carve exit %d, stderr %q", code, w.err.String())
	}
}

func (w *world) files(dir string) []string {
	w.t.Helper()
	var out []string
	err := filepath.WalkDir(w.path(dir), func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			rel, _ := filepath.Rel(w.path(dir), p)
			out = append(out, rel)
		}
		return err
	})
	if err != nil {
		w.t.Fatal(err)
	}
	slices.Sort(out)
	return out
}
