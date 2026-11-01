//go:build linux

package formats

// Guard-to-test table for qnx6-read. Every refusal of qnx6_read.py is pinned by a named test here; the
// differential tests (TestQNX6Parity*) hold the whole behavior against the frozen legacy script
// (testdata/qnx6/legacy/qnx6_read.py) run through testdata/qnx6/oracle_driver.py.
//
//	bash suite case (qnx6-read.test.sh)            Go test
//	T1  absent input: exit 2, no JSON               TestQNX6AbsentInput
//	T2  symlink input rejected (O_NOFOLLOW)         TestQNX6SymlinkInput
//	T3  bad magic: exit 1, status failed            TestQNX6BadMagic
//	T4  valid image: every field                    TestQNX6ListValid
//	T5  empty fs: complete, total_entries 0         TestQNX6EmptyFilesystem
//	T6  extract: exact bytes                        TestQNX6ExtractContent
//	T7  extract missing path: exit 1                TestQNX6ExtractMissingPath
//	T8  dangling inode: failed JSON                 TestQNX6FailedJSONCases
//	T9  indirect block past EOF: failed JSON        TestQNX6FailedJSONCases
//	T10 cyclic directories terminate                TestQNX6CyclicTerminates
//	T11 depth cap: truncated true                   TestQNX6DeepTruncated
//	T12 output symlink: victim intact               TestQNX6OutputSymlink
//	T13 FIFO input: no hang                         TestQNX6FIFOInput
//	T14 crafted num_blocks/longfile: no hang        TestQNX6OOMImageDoesNotHang
//	T15 truncated directory: failed, not silent 0   TestQNX6FailedJSONCases
//	M1..M10 mutants (O_NOFOLLOW, magic, write, path slash, walk error, visited set, fstat cap,
//	        truncated flag, output guards, O_NONBLOCK)  the tests above; each was mutation-checked by hand

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const (
	qnxData   = "testdata/qnx6/"
	qnxLegacy = "testdata/qnx6/legacy/qnx6_read.py"
	qnxDriver = "testdata/qnx6/oracle_driver.py"
)

func testStdio(cwd string) (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	var out, errb bytes.Buffer
	return cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env:     func(string) string { return "" },
		Environ: func() []string { return nil },
		Clock:   time.Now, Cwd: cwd,
	}, &out, &errb
}

// runQNX6 runs the command in process and bounds it: a hang is a test failure, not a stuck suite.
func runQNX6(t *testing.T, args ...string) (rc int, stdout, stderr string) {
	t.Helper()
	s, out, errb := testStdio(t.TempDir())
	done := make(chan int, 1)
	go func() { done <- QNX6Read(args, s) }()
	select {
	case rc = <-done:
	case <-time.After(20 * time.Second):
		t.Fatalf("qnx6-read %v did not finish within 20s", args)
	}
	return rc, out.String(), errb.String()
}

func listJSON(t *testing.T, image string, extra ...string) (int, map[string]any, string) {
	t.Helper()
	outPath := filepath.Join(t.TempDir(), "evidence.json")
	rc, _, stderr := runQNX6(t, append([]string{"list", "--input", image, "--output", outPath}, extra...)...)
	b, err := os.ReadFile(outPath)
	if err != nil {
		return rc, nil, stderr
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("evidence is not JSON: %v\n%s", err, b)
	}
	return rc, doc, stderr
}

func TestQNX6AbsentInput(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := runQNX6(t, "list", "--input", "/no/such/qnx6.img", "--output", out)
	if rc != 2 {
		t.Errorf("exit = %d, want 2", rc)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("an evidence file was written for an absent input")
	}
	if want := "qnx6-read: /no/such/qnx6.img: No such file or directory\n"; stderr != want {
		t.Errorf("stderr = %q, want %q", stderr, want)
	}
}

func TestQNX6SymlinkInput(t *testing.T) {
	dir := t.TempDir()
	link := filepath.Join(dir, "sym.img")
	if err := os.Symlink(abs(t, qnxData+"valid.img"), link); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "o.json")
	rc, _, stderr := runQNX6(t, "list", "--input", link, "--output", out)
	if rc != 2 {
		t.Errorf("exit = %d, want 2", rc)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("an evidence file was written for a symlink input")
	}
	if want := "qnx6-read: " + link + ": is a symbolic link (rejected)\n"; stderr != want {
		t.Errorf("stderr = %q, want %q", stderr, want)
	}
}

func TestQNX6DirectoryInput(t *testing.T) {
	rc, _, stderr := runQNX6(t, "list", "--input", t.TempDir(), "--output", filepath.Join(t.TempDir(), "o.json"))
	if rc != 2 || !strings.Contains(stderr, "not a regular file (rejected)") {
		t.Errorf("exit = %d stderr = %q, want exit 2 and the not-a-regular-file refusal", rc, stderr)
	}
}

func TestQNX6FIFOInput(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "fifo.img")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "o.json")
	rc, _, stderr := runQNX6(t, "list", "--input", fifo, "--output", out)
	if rc != 2 {
		t.Errorf("exit = %d, want 2", rc)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("an evidence file was written for a FIFO input")
	}
	if want := "qnx6-read: " + fifo + ": not a regular file (rejected)\n"; stderr != want {
		t.Errorf("stderr = %q, want %q", stderr, want)
	}
}

func TestQNX6BadMagic(t *testing.T) {
	rc, doc, _ := listJSON(t, abs(t, qnxData+"bad_magic.img"))
	if rc != 1 {
		t.Fatalf("exit = %d, want 1", rc)
	}
	if doc["schema"] != "qnx6-evidence.v1" || doc["status"] != "failed" {
		t.Errorf("schema/status = %v/%v", doc["schema"], doc["status"])
	}
	errs := arr(doc["errors"])
	if len(errs) != 1 || errs[0] != "bad magic 0xdeadbeef (expected 0x68191122); not a QNX6 Power-Safe image" {
		t.Errorf("errors = %v", errs)
	}
	fs := obj(doc["filesystem"])
	if fs["block_size"] != nil || fs["num_blocks"] != nil || fs["num_inodes"] != nil {
		t.Errorf("filesystem numbers must be null on a parse failure, got %v", fs)
	}
}

func TestQNX6ListValid(t *testing.T) {
	image := abs(t, qnxData+"valid.img")
	rc, doc, _ := listJSON(t, image)
	if rc != 0 || doc["status"] != "complete" {
		t.Fatalf("exit = %d status = %v", rc, doc["status"])
	}
	entries := arr(doc["entries"])
	if len(entries) != 1 {
		t.Fatalf("entries = %v", entries)
	}
	e := obj(entries[0])
	if e["path"] != "/file" || e["type"] != "file" || e["size_bytes"] != float64(12) || e["mode"] != float64(0x8000) {
		t.Errorf("entry = %v", e)
	}
	fs := obj(doc["filesystem"])
	if fs["filesystem_type"] != "QNX6 Power-Safe" || fs["block_size"] != float64(512) || fs["num_inodes"] != float64(2) || fs["num_blocks"] != float64(26) {
		t.Errorf("filesystem = %v", fs)
	}
	in := obj(doc["input"])
	raw, _ := os.ReadFile(image)
	if in["partition_offset"] != float64(0) || in["size_bytes"] != float64(len(raw)) || in["sha256"] != sha256Hex(raw) {
		t.Errorf("input = %v", in)
	}
	sum := obj(doc["summary"])
	if sum["files"] != float64(1) || sum["dirs"] != float64(0) || sum["total_entries"] != float64(1) {
		t.Errorf("summary = %v", sum)
	}
	if doc["truncated"] != false || len(arr(doc["errors"])) != 0 {
		t.Errorf("truncated/errors = %v/%v", doc["truncated"], doc["errors"])
	}
}

func TestQNX6EmptyFilesystem(t *testing.T) {
	rc, doc, _ := listJSON(t, abs(t, qnxData+"empty.img"))
	if rc != 0 || doc["status"] != "complete" {
		t.Fatalf("exit = %d status = %v, an empty filesystem is complete", rc, doc["status"])
	}
	if n := obj(doc["summary"])["total_entries"]; n != float64(0) {
		t.Errorf("total_entries = %v, want 0", n)
	}
	if e := arr(doc["entries"]); len(e) != 0 {
		t.Errorf("entries = %v", e)
	}
}

func TestQNX6FailedJSONCases(t *testing.T) {
	for image, wantErr := range map[string]string{
		"bad_inode.img":     "walk error: inode 999 out of range",
		"indirect_eof.img":  "unpack_from requires a buffer of at least 512 bytes for unpacking 512 bytes at offset 0 (actual buffer size is 0)",
		"truncated_dir.img": "walk error: directory data truncated: inode 1 declared 32 bytes but only 0 were readable (image truncated or block past EOF)",
	} {
		t.Run(image, func(t *testing.T) {
			rc, doc, _ := listJSON(t, abs(t, qnxData+image))
			if rc != 1 {
				t.Fatalf("exit = %d, want 1", rc)
			}
			if doc == nil || doc["status"] != "failed" {
				t.Fatalf("a failed JSON is required, got %v", doc)
			}
			errs := arr(doc["errors"])
			if len(errs) != 1 || errs[0] != wantErr {
				t.Errorf("errors = %v, want [%q]", errs, wantErr)
			}
		})
	}
}

func TestQNX6CyclicTerminates(t *testing.T) {
	rc, doc, _ := listJSON(t, abs(t, qnxData+"cyclic.img"))
	if rc != 0 || doc["status"] != "complete" {
		t.Fatalf("exit = %d status = %v", rc, doc["status"])
	}
	if n, _ := obj(doc["summary"])["total_entries"].(float64); n >= 100 || n == 0 {
		t.Errorf("total_entries = %v, want bounded and non-zero", n)
	}
}

func TestQNX6DeepTruncated(t *testing.T) {
	rc, doc, _ := listJSON(t, abs(t, qnxData+"deep.img"))
	if rc != 0 || doc["status"] != "complete" || doc["truncated"] != true {
		t.Errorf("exit = %d status = %v truncated = %v, want 0 complete true", rc, doc["status"], doc["truncated"])
	}
	if n := obj(doc["summary"])["dirs"]; n != float64(41) {
		t.Errorf("dirs = %v, want 41 (depths 0..40 are listed, 41 is cut)", n)
	}
}

func TestQNX6OOMImageDoesNotHang(t *testing.T) {
	start := time.Now()
	rc, doc, _ := listJSON(t, abs(t, qnxData+"oom.img"))
	if rc != 0 && rc != 1 {
		t.Fatalf("exit = %d", rc)
	}
	if doc == nil || doc["status"] == nil {
		t.Errorf("a clean result is required, got %v", doc)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Errorf("took %s: the fstat-bounded read cap is gone", d)
	}
}

func TestQNX6OutputSymlink(t *testing.T) {
	dir := t.TempDir()
	victim := filepath.Join(dir, "victim.txt")
	if err := os.WriteFile(victim, []byte("victim-content\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "out.json")
	if err := os.Symlink(victim, out); err != nil {
		t.Fatal(err)
	}
	rc, _, stderr := runQNX6(t, "list", "--input", abs(t, qnxData+"valid.img"), "--output", out)
	if rc != 2 {
		t.Errorf("exit = %d, want 2", rc)
	}
	if b, _ := os.ReadFile(victim); string(b) != "victim-content\n" {
		t.Errorf("the symlink target was overwritten: %q", b)
	}
	if want := "qnx6-read: I/O error: [Errno 17] File exists: " + pyRepr(out) + "\n"; stderr != want {
		t.Errorf("stderr = %q, want %q", stderr, want)
	}
}

func TestQNX6OutputExists(t *testing.T) {
	out := filepath.Join(t.TempDir(), "out.json")
	if err := os.WriteFile(out, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, op := range [][]string{
		{"list", "--input", abs(t, qnxData+"valid.img"), "--output", out},
		{"extract", "--input", abs(t, qnxData+"valid.img"), "--fs-path", "/file", "--output", out},
	} {
		if rc, _, _ := runQNX6(t, op...); rc != 2 {
			t.Errorf("%s over an existing output: exit = %d, want 2", op[0], rc)
		}
	}
	if b, _ := os.ReadFile(out); string(b) != "keep" {
		t.Errorf("existing output overwritten: %q", b)
	}
}

func TestQNX6ExtractContent(t *testing.T) {
	out := filepath.Join(t.TempDir(), "file")
	rc, _, stderr := runQNX6(t, "extract", "--input", abs(t, qnxData+"valid.img"), "--fs-path", "/file", "--output", out)
	if rc != 0 || stderr != "" {
		t.Fatalf("exit = %d stderr = %q", rc, stderr)
	}
	if b, _ := os.ReadFile(out); string(b) != "hello-world\n" {
		t.Errorf("content = %q", b)
	}
	// An indirect-block file and a long-named file from the richer image.
	out = filepath.Join(t.TempDir(), "b.bin")
	if rc, _, _ := runQNX6(t, "extract", "--input", abs(t, qnxData+"rich.img"), "--fs-path", "/sub/b.bin", "--output", out); rc != 0 {
		t.Fatalf("rich extract exit = %d", rc)
	}
	want := make([]byte, 700)
	for i := range want {
		want[i] = byte(i * 7)
	}
	if b, _ := os.ReadFile(out); !bytes.Equal(b, want) {
		t.Errorf("indirect-block content differs (%d bytes)", len(b))
	}
}

func TestQNX6ExtractMissingPath(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o")
	rc, _, stderr := runQNX6(t, "extract", "--input", abs(t, qnxData+"valid.img"), "--fs-path", "/no-such-file", "--output", out)
	if rc != 1 || stderr != "qnx6-read: /no-such-file: path not found in image\n" {
		t.Errorf("exit = %d stderr = %q", rc, stderr)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("an output file was created for a missing path")
	}
}

func TestQNX6ExtractParseError(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o")
	rc, _, stderr := runQNX6(t, "extract", "--input", abs(t, qnxData+"bad_magic.img"), "--fs-path", "/file", "--output", out)
	if rc != 1 || !strings.HasPrefix(stderr, "qnx6-read: parse error: bad magic 0xdeadbeef") {
		t.Errorf("exit = %d stderr = %q", rc, stderr)
	}
}

func TestQNX6PartitionOffset(t *testing.T) {
	rich, err := os.ReadFile(abs(t, qnxData+"rich.img"))
	if err != nil {
		t.Fatal(err)
	}
	img := filepath.Join(t.TempDir(), "disk.img")
	if err := os.WriteFile(img, append(make([]byte, 1024), rich...), 0o600); err != nil {
		t.Fatal(err)
	}
	rc, doc, _ := listJSON(t, img, "--partition-offset", "1024")
	if rc != 0 || doc["status"] != "complete" || obj(doc["summary"])["total_entries"] != float64(5) {
		t.Errorf("exit = %d doc = %v", rc, doc)
	}
	if obj(doc["input"])["partition_offset"] != float64(1024) {
		t.Errorf("input = %v", doc["input"])
	}
	if rc, doc, _ := listJSON(t, img); rc != 1 || doc["status"] != "failed" {
		t.Errorf("offset 0 on a shifted image: exit = %d status = %v, want 1 failed", rc, doc["status"])
	}
	// A negative offset that puts the superblock before the file is an I/O error, never a silent parse.
	rc, _, stderr := runQNX6(t, "list", "--input", img, "--partition-offset", "-9000", "--output", filepath.Join(t.TempDir(), "o.json"))
	if rc != 2 || stderr != "qnx6-read: I/O error: [Errno 22] Invalid argument\n" {
		t.Errorf("exit = %d stderr = %q", rc, stderr)
	}
}

func TestQNX6Usage(t *testing.T) {
	good := abs(t, qnxData+"valid.img")
	out := filepath.Join(t.TempDir(), "o")
	for name, args := range map[string][]string{
		"no subcommand":     {},
		"unknown":           {"frobnicate"},
		"list no input":     {"list", "--output", out},
		"list no output":    {"list", "--input", good},
		"extract no path":   {"extract", "--input", good, "--output", out},
		"bad offset":        {"list", "--input", good, "--output", out, "--partition-offset", "abc"},
		"unknown flag":      {"list", "--input", good, "--output", out, "--nope"},
		"extract no output": {"extract", "--input", good, "--fs-path", "/file"},
	} {
		t.Run(name, func(t *testing.T) {
			rc, stdout, stderr := runQNX6(t, args...)
			if rc != 2 || stdout != "" || stderr == "" {
				t.Errorf("exit = %d stdout = %q stderr = %q, want exit 2 with a message on stderr only", rc, stdout, stderr)
			}
		})
	}
	if rc, stdout, _ := runQNX6(t, "-h"); rc != 0 || !strings.Contains(stdout, "list") || !strings.Contains(stdout, "extract") {
		t.Errorf("-h: exit = %d stdout = %q", rc, stdout)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("a usage error created the output file")
	}
}

func TestQNX6RelativePathsUseTheInjectedCwd(t *testing.T) {
	dir := t.TempDir()
	raw, _ := os.ReadFile(abs(t, qnxData+"valid.img"))
	if err := os.WriteFile(filepath.Join(dir, "in.img"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	s, _, errb := testStdio(dir)
	if rc := QNX6Read([]string{"list", "--input", "in.img", "--output", "out.json"}, s); rc != 0 {
		t.Fatalf("exit = %d stderr = %q", rc, errb)
	}
	if _, err := os.Stat(filepath.Join(dir, "out.json")); err != nil {
		t.Errorf("relative output was not resolved against Stdio.Cwd: %v", err)
	}
}

func TestQNX6Registered(t *testing.T) {
	for _, c := range Commands {
		if c.Group == "formats" && c.Name == "qnx6-read" {
			return
		}
	}
	t.Error("formats qnx6-read is not in Commands")
}

func TestQNX6BlockPositionOverflowIsAParseError(t *testing.T) {
	// The script's lseek raises an uncaught OverflowError past 2**63; the port reports a parse error.
	r := &qnxReader{bs: 0xFFFFFFFF, off: 39}
	if _, err := r.blockPos(0xFFFFFFFE); err == nil {
		t.Error("a position beyond 2**63 was accepted")
	}
	r = &qnxReader{bs: 512, off: 1, poff: 1 << 62}
	if pos, err := r.blockPos(3); err != nil || pos != 1<<62+2048 {
		t.Errorf("pos = %d err = %v, want %d", pos, err, int64(1<<62+2048))
	}
	r = &qnxReader{bs: 1 << 31, off: 0, poff: 1 << 62}
	if _, err := r.blockPos(1 << 31); err == nil {
		t.Error("a sum beyond 2**63 was accepted")
	}
	r = &qnxReader{bs: 512, off: 0, poff: -9000}
	if pos, err := r.blockPos(1); err != nil || pos != -8488 {
		t.Errorf("pos = %d err = %v, want -8488 (the read then fails with EINVAL)", pos, err)
	}
}
