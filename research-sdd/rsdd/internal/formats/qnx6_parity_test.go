//go:build linux && !nodiff

package formats

// The differential half of the qnx6-read tests: the frozen legacy script (testdata/qnx6/legacy) is the oracle.
// `make teeth` (-tags nodiff) leaves them out; the unit tests in qnx6_test.go carry the mutation kills.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// ---------------------------------------------------------------- differential tests against the legacy script

type qcase struct {
	Op              string `json:"op"`
	Input           string `json:"input"`
	Output          string `json:"output"`
	PartitionOffset int64  `json:"partition_offset"`
	FsPath          string `json:"fs_path"`
}

type qres struct {
	RC        int     `json:"rc"`
	Stderr    string  `json:"stderr"`
	Traceback bool    `json:"traceback"`
	OutputB64 *string `json:"output_b64"`
}

func oracleQNX6(t *testing.T, cases []qcase) []qres {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	in, _ := json.Marshal(cases)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, py, "-I", abs(t, qnxDriver), abs(t, qnxLegacy))
	var out, errb bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("oracle driver failed: %v\n%s", err, errb.String())
	}
	var rs []qres
	if err := json.Unmarshal(out.Bytes(), &rs); err != nil || len(rs) != len(cases) {
		t.Fatalf("oracle output: %v (%d results for %d cases)\n%s", err, len(rs), len(cases), out.String())
	}
	return rs
}

// compareToOracle runs c in Go (output redirected under goDir) and requires the legacy result py (output
// under pyDir). A legacy traceback is the one declared divergence: exit 1, no output, typed message.
func compareToOracle(t *testing.T, label string, c qcase, py qres, pyDir, goDir string) {
	t.Helper()
	gc := c
	gc.Output = strings.Replace(c.Output, pyDir, goDir, 1)
	args := []string{c.Op, "--input", gc.Input, "--output", gc.Output, "--partition-offset", fmt.Sprint(gc.PartitionOffset)}
	if c.Op == "extract" {
		args = append(args, "--fs-path", gc.FsPath)
	}
	rc, stdout, stderr := runQNX6(t, args...)
	var goOut *string
	if b, err := os.ReadFile(gc.Output); err == nil {
		e := base64.StdEncoding.EncodeToString(b)
		goOut = &e
	}
	if stdout != "" {
		t.Errorf("%s: stdout = %q, want empty", label, stdout)
	}
	if py.Traceback {
		if rc != 1 || goOut != nil || !strings.HasPrefix(stderr, "qnx6-read: ") {
			t.Errorf("%s: legacy traceback; go exit = %d output = %v stderr = %q, want exit 1, no output, typed stderr", label, rc, goOut != nil, stderr)
		}
		return
	}
	if rc != py.RC {
		t.Errorf("%s: exit go %d, legacy %d\n go stderr: %q\n py stderr: %q", label, rc, py.RC, stderr, py.Stderr)
	}
	if want := strings.ReplaceAll(py.Stderr, pyDir, goDir); stderr != want {
		t.Errorf("%s: stderr go %q, legacy %q", label, stderr, want)
	}
	if (goOut == nil) != (py.OutputB64 == nil) || (goOut != nil && *goOut != *py.OutputB64) {
		t.Errorf("%s: output differs (go present=%v, legacy present=%v)", label, goOut != nil, py.OutputB64 != nil)
	}
}

func TestQNX6ParityFixtures(t *testing.T) {
	pyDir, goDir := t.TempDir(), t.TempDir()
	imgs, _ := filepath.Glob(qnxData + "*.img")
	if len(imgs) < 10 {
		t.Fatalf("fixtures missing: %v", imgs)
	}
	var cases []qcase
	n := 0
	add := func(c qcase) {
		n++
		c.Output = filepath.Join(pyDir, fmt.Sprintf("o%03d", n))
		cases = append(cases, c)
	}
	for _, img := range imgs {
		img = abs(t, img)
		add(qcase{Op: "list", Input: img})
		for _, p := range []string{"/file", "/a.txt", "/sub", "/sub/b.bin", "/a-very-long-file-name-that-needs-longfile-1234567890.dat", "/e", "/", "", "//a.txt//", "/missing", "/sub/missing/x"} {
			add(qcase{Op: "extract", Input: img, FsPath: p})
		}
	}
	rich := abs(t, qnxData+"rich.img")
	for _, off := range []int64{-9000, -8192, -1, 1, 512, 4096, 1 << 40} {
		add(qcase{Op: "list", Input: rich, PartitionOffset: off})
		add(qcase{Op: "extract", Input: rich, PartitionOffset: off, FsPath: "/a.txt"})
	}
	dir := t.TempDir()
	link := filepath.Join(dir, "link.img")
	_ = os.Symlink(rich, link)
	fifo := filepath.Join(dir, "fifo.img")
	_ = syscall.Mkfifo(fifo, 0o600)
	exist := filepath.Join(dir, "exists")
	_ = os.WriteFile(exist, []byte("x"), 0o600)
	for _, in := range []string{filepath.Join(dir, "absent.img"), link, fifo, dir, "/proc/self/mem", "/dev/null"} {
		add(qcase{Op: "list", Input: in})
		add(qcase{Op: "extract", Input: in, FsPath: "/a.txt"})
	}
	add(qcase{Op: "list", Input: rich})
	cases[len(cases)-1].Output = exist
	add(qcase{Op: "extract", Input: rich, FsPath: "/a.txt"})
	cases[len(cases)-1].Output = exist
	add(qcase{Op: "list", Input: rich})
	cases[len(cases)-1].Output = filepath.Join(pyDir, "no-dir", "x")
	add(qcase{Op: "list", Input: rich})
	cases[len(cases)-1].Output = pyDir + "/o001" // already written by case 1
	results := oracleQNX6(t, cases)
	for i, c := range cases {
		compareToOracle(t, fmt.Sprintf("case %d %s %s %q off=%d", i, c.Op, filepath.Base(c.Input), c.FsPath, c.PartitionOffset), c, results[i], pyDir, goDir)
	}
}

// TestQNX6ParityMutants flips bytes of the structured parts of real images (superblock, inode table, directory
// blocks) with a fixed seed. Every parse error text and every partial listing must equal the legacy script's.
func TestQNX6ParityMutants(t *testing.T) {
	pyDir, goDir := t.TempDir(), t.TempDir()
	rng := rand.New(rand.NewPCG(2417, 6))
	type zone struct{ lo, hi int }
	zones := map[string][]zone{
		"valid.img":  {{8192, 8192 + 400}, {2048, 2048 + 256}, {2560, 2560 + 64}, {0, 13312}},
		"rich.img":   {{8192, 8192 + 400}, {2048, 2048 + 768}, {blkOff(23), blkOff(23) + 224}, {blkOff(25), blkOff(25) + 64}, {blkOff(28), blkOff(28) + 16}, {0, 16384}},
		"deep.img":   {{8192, 8192 + 400}, {2048, 2048 + 64}, {12288, 12288 + 200}},
		"cyclic.img": {{8192, 8192 + 400}, {2048, 2048 + 256}, {2560, 2560 + 128}},
	}
	var cases []qcase
	n := 0
	for name, zs := range zones {
		raw, err := os.ReadFile(abs(t, qnxData+name))
		if err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 70; i++ {
			img := append([]byte(nil), raw...)
			for k := 0; k <= rng.IntN(3); k++ {
				z := zs[rng.IntN(len(zs))]
				pos := z.lo + rng.IntN(z.hi-z.lo)
				switch rng.IntN(3) {
				case 0:
					img[pos] = 0xff
				case 1:
					img[pos] = 0
				default:
					img[pos] = byte(rng.IntN(256))
				}
			}
			if rng.IntN(8) == 0 {
				img = img[:rng.IntN(len(img))] // truncated image
			}
			p := filepath.Join(t.TempDir(), name)
			if err := os.WriteFile(p, img, 0o600); err != nil {
				t.Fatal(err)
			}
			n++
			cases = append(cases, qcase{Op: "list", Input: p, Output: filepath.Join(pyDir, fmt.Sprintf("m%03d", n))})
			n++
			cases = append(cases, qcase{Op: "extract", Input: p, FsPath: "/a.txt", Output: filepath.Join(pyDir, fmt.Sprintf("m%03d", n))})
		}
	}
	results := oracleQNX6(t, cases)
	failedJSON, traces := 0, 0
	for i, c := range cases {
		if results[i].Traceback {
			traces++
		}
		if c.Op == "list" && results[i].RC == 1 && results[i].OutputB64 != nil {
			failedJSON++
		}
		compareToOracle(t, fmt.Sprintf("mutant %d %s", i, c.Op), c, results[i], pyDir, goDir)
	}
	// The corpus must actually reach the error paths it exists for, or its agreement proves nothing.
	if failedJSON < 20 {
		t.Errorf("only %d mutants produced a failed evidence document; the corpus is too tame", failedJSON)
	}
	t.Logf("%d mutants, %d failed-JSON, %d legacy tracebacks", len(cases), failedJSON, traces)
}

func blkOff(n int) int { return (n + 1) * 512 }
