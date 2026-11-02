//go:build linux

package serial

// Guard-to-test table for serial-frame-analyze. Behaviour is held two ways: TestAnalyzeGolden replays 50 cases
// (testdata/golden, generated from the frozen legacy script by testdata/gen_analyze.py) and requires the same
// exit code, stderr and evidence bytes; the named tests below pin each guard on its own. The differential half
// against the live legacy script is parity_test.go.
//
//	behaviour (pre-port bash suite; numbered for this table)    Go test
//	T1  absent input: exit 2, no JSON                           TestAnalyzeAbsentInput
//	T2  symlink input rejected (O_NOFOLLOW)                     TestAnalyzeSymlinkInput
//	T3  empty log: complete, frame_count 0                      TestAnalyzeGolden/stats_empty
//	T4  valid stats: every field                                TestAnalyzeGolden/stats_basic
//	T5  diff: shared types and changed positions                TestAnalyzeGolden/diff_basic_basic_b
//	T6  checksum: every algorithm family                        TestAnalyzeGolden/checksum_*
//	T7  malformed log: exit 1, status failed                    TestAnalyzeGolden/*_malformed*
//	T8  output exists / symlink: exit 2, victim intact          TestAnalyzeOutputExists, TestAnalyzeOutputSymlink
//	T9  caps: 10000 frames, 10 MB                               TestAnalyzeFrameCap, TestAnalyzeReadCap
//	T10 FIFO / directory input: no hang                         TestAnalyzeFIFOInput, TestAnalyzeDirectoryInput
//	T11 usage errors: exit 2                                    TestAnalyzeUsage
//	T12 zero-byte log: complete, frame_count 0                  TestAnalyzeZeroByteInput
//	T13 only line has a non-hex byte: exit 1, failed            TestAnalyzeNonHexOnlyLine

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

type goldenCase struct {
	name string
	args []string
}

func goldenCases(t *testing.T, minimum int) []goldenCase {
	t.Helper()
	files, _ := filepath.Glob("testdata/golden/*.args")
	if len(files) < minimum {
		t.Fatalf("golden cases missing: %d found, want at least %d", len(files), minimum)
	}
	var cases []goldenCase
	for _, f := range files {
		var args []string
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(b, &args); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		cases = append(cases, goldenCase{strings.TrimSuffix(filepath.Base(f), ".args"), args})
	}
	return cases
}

func expectedFile(t *testing.T, name, ext string) (string, bool) {
	t.Helper()
	b, err := os.ReadFile("testdata/golden/" + name + "." + ext)
	if os.IsNotExist(err) {
		return "", false
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(b), true
}

func TestAnalyzeGolden(t *testing.T) {
	for _, c := range goldenCases(t, 55) {
		t.Run(c.name, func(t *testing.T) {
			tmp := t.TempDir()
			args := make([]string, len(c.args))
			for i, a := range c.args {
				args[i] = strings.ReplaceAll(a, "{TMP}", tmp)
			}
			rc, stdout, stderr := analyze(t, args...)
			wantRC, _ := expectedFile(t, c.name, "rc")
			if fmt.Sprint(rc)+"\n" != wantRC {
				t.Errorf("exit = %d, want %q", rc, strings.TrimSpace(wantRC))
			}
			wantErr, _ := expectedFile(t, c.name, "stderr")
			if got := strings.ReplaceAll(stderr, tmp, "{TMP}"); got != wantErr {
				t.Errorf("stderr = %q, want %q", got, wantErr)
			}
			if stdout != "" {
				t.Errorf("stdout = %q, want empty", stdout)
			}
			got, err := os.ReadFile(filepath.Join(tmp, "out.json"))
			want, hasFull := expectedFile(t, c.name, "json")
			wantSum, hasSum := expectedFile(t, c.name, "sha256")
			sum := sha256.Sum256(got)
			switch {
			case (hasFull || hasSum) && err != nil:
				t.Errorf("no evidence written")
			case hasFull && string(got) != want:
				t.Errorf("evidence differs\n got: %s\nwant: %s", got, want)
			case hasSum && hex.EncodeToString(sum[:])+"\n" != wantSum:
				t.Errorf("evidence differs from the legacy bytes (sha256 mismatch)\n got: %s", got)
			case !hasFull && !hasSum && err == nil:
				t.Errorf("evidence written where the legacy script wrote none: %s", got)
			}
		})
	}
}

func evidence(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("evidence not written: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("evidence is not JSON: %v\n%s", err, b)
	}
	return doc
}

func TestAnalyzeAbsentInput(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := analyze(t, "stats", "--input", "testdata/frames/none.log", "--output", out)
	if rc != 2 || !strings.HasPrefix(stderr, "serial-frame-analyze: testdata/frames/none.log: No such file or directory") {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("evidence written for an absent input")
	}
}

func TestAnalyzeSymlinkInput(t *testing.T) {
	dir := t.TempDir()
	link := filepath.Join(dir, "sym.log")
	if err := os.Symlink(abs(t, "testdata/frames/basic.log"), link); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"stats", "--input", link, "--output", filepath.Join(dir, "a.json")},
		{"checksum", "--input", link, "--output", filepath.Join(dir, "b.json")},
		{"diff", "--input-a", link, "--input-b", abs(t, "testdata/frames/basic.log"), "--output", filepath.Join(dir, "c.json")},
		{"diff", "--input-a", abs(t, "testdata/frames/basic.log"), "--input-b", link, "--output", filepath.Join(dir, "d.json")},
	} {
		rc, _, stderr := analyze(t, args...)
		if rc != 2 || !strings.HasSuffix(stderr, link+": is a symbolic link (rejected)\n") {
			t.Errorf("%v: rc = %d stderr = %q", args, rc, stderr)
		}
	}
	if m, _ := filepath.Glob(filepath.Join(dir, "*.json")); len(m) != 0 {
		t.Errorf("evidence written for a symlink input: %v", m)
	}
}

func TestAnalyzeDirectoryInput(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := analyze(t, "stats", "--input", t.TempDir(), "--output", out)
	if rc != 2 || !strings.HasSuffix(stderr, ": Is a directory\n") {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
}

func TestAnalyzeFIFOInput(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "in.log")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	rc, _, stderr := analyze(t, "stats", "--input", fifo, "--output", filepath.Join(dir, "o.json"))
	if rc != 2 || !strings.HasSuffix(stderr, fifo+": not a regular file\n") {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
	if _, err := os.Stat(filepath.Join(dir, "o.json")); err == nil {
		t.Error("evidence written for a FIFO input")
	}
}

func TestAnalyzeOutputExists(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "o.json")
	if err := os.WriteFile(out, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, input := range []string{"basic", "malformed"} { // complete and failed documents are both refused
		rc, _, stderr := analyze(t, "stats", "--input", "testdata/frames/"+input+".log", "--output", out)
		if rc != 2 || stderr != "serial-frame-analyze: "+out+": File exists\n" {
			t.Errorf("%s: rc = %d stderr = %q", input, rc, stderr)
		}
	}
	if b, _ := os.ReadFile(out); string(b) != "keep" {
		t.Errorf("existing output modified: %q", b)
	}
}

func TestAnalyzeOutputSymlink(t *testing.T) {
	dir := t.TempDir()
	victim := filepath.Join(dir, "victim.txt")
	if err := os.WriteFile(victim, []byte("victim"), 0o600); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "o.json")
	if err := os.Symlink(victim, out); err != nil {
		t.Fatal(err)
	}
	rc, _, stderr := analyze(t, "stats", "--input", "testdata/frames/basic.log", "--output", out)
	if rc != 2 || !strings.Contains(stderr, ": File exists") {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
	if b, _ := os.ReadFile(victim); string(b) != "victim" {
		t.Errorf("symlink target modified: %q", b)
	}
}

func TestAnalyzeOutputMode(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o.json")
	if rc, _, stderr := analyze(t, "stats", "--input", "testdata/frames/basic.log", "--output", out); rc != 0 {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	st, err := os.Stat(out)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm()&0o077 != 0 {
		t.Errorf("evidence mode = %v, want no group/other access (0600 before umask)", st.Mode().Perm())
	}
}

func writeFrames(t *testing.T, n int, comment string) string {
	t.Helper()
	var b strings.Builder
	b.WriteString(comment)
	for i := range n {
		fmt.Fprintf(&b, "%d.0 len=2 aa %02x\n", i, i%256)
	}
	p := filepath.Join(t.TempDir(), "big.log")
	if err := os.WriteFile(p, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestAnalyzeFrameCap(t *testing.T) {
	for _, tc := range []struct {
		lines, frames int
		truncated     bool
	}{
		{9999, 9999, false},
		{10000, 10000, true}, // reaching the cap is truncation even when the file ends there
		{10001, 10000, true},
	} {
		in := writeFrames(t, tc.lines, "")
		out := filepath.Join(t.TempDir(), "o.json")
		if rc, _, stderr := analyze(t, "stats", "--input", in, "--output", out); rc != 0 {
			t.Fatalf("%d lines: rc = %d stderr = %q", tc.lines, rc, stderr)
		}
		doc := evidence(t, out)
		sum := obj(doc["summary"])
		if int(sum["frame_count"].(float64)) != tc.frames || sum["truncated"] != tc.truncated || doc["truncated"] != tc.truncated {
			t.Errorf("%d lines: summary = %v truncated = %v, want %d frames truncated=%v", tc.lines, sum, doc["truncated"], tc.frames, tc.truncated)
		}
		if int(sum["line_count"].(float64)) != tc.frames {
			t.Errorf("%d lines: line_count = %v, want %d (counting stops at the cap)", tc.lines, sum["line_count"], tc.frames)
		}
	}
}

func TestAnalyzeReadCap(t *testing.T) {
	// A comment line pads the file to just over 10 MiB; the single frame after it is beyond the read cap.
	pad := "# " + strings.Repeat("x", 10*1024*1024) + "\n"
	in := writeFrames(t, 1, pad)
	raw, _ := os.ReadFile(in)
	out := filepath.Join(t.TempDir(), "o.json")
	if rc, _, stderr := analyze(t, "stats", "--input", in, "--output", out); rc != 0 {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	doc := evidence(t, out)
	h := sha256.Sum256(raw)
	if got := obj(doc["input"])["sha256"]; got != hex.EncodeToString(h[:]) {
		t.Errorf("sha256 = %v, want the hash of the whole file (not of the capped prefix)", got)
	}
	sum := obj(doc["summary"])
	if sum["frame_count"] != float64(0) || sum["truncated"] != true {
		t.Errorf("summary = %v, want 0 frames and truncated", sum)
	}
	// exactly at the cap: not truncated, and the frame is read
	exact := "# " + strings.Repeat("x", 10*1024*1024-len("# \n")-len("0.0 len=2 aa 00\n")) + "\n"
	in = writeFrames(t, 1, exact)
	if st, _ := os.Stat(in); st.Size() != 10*1024*1024 {
		t.Fatalf("fixture size = %d, want exactly the cap", st.Size())
	}
	out = filepath.Join(t.TempDir(), "o2.json")
	if rc, _, stderr := analyze(t, "stats", "--input", in, "--output", out); rc != 0 {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	sum = obj(evidence(t, out)["summary"])
	if sum["frame_count"] != float64(1) || sum["truncated"] != false {
		t.Errorf("at-cap summary = %v, want 1 frame and not truncated", sum)
	}
}

func TestAnalyzeUsage(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o.json")
	good := "testdata/frames/basic.log"
	for name, args := range map[string][]string{
		"no command":          {},
		"unknown command":     {"bogus"},
		"option first":        {"--input", good, "stats"},
		"missing input":       {"stats", "--output", out},
		"missing output":      {"stats", "--input", good},
		"missing diff b":      {"diff", "--input-a", good, "--output", out},
		"unknown option":      {"stats", "--input", good, "--output", out, "--bogus", "x"},
		"positional":          {"stats", "--input", good, "--output", out, "extra"},
		"value missing":       {"stats", "--input", good, "--output"},
		"value is an option":  {"stats", "--input", "--output", out},
		"ambiguous prefix":    {"diff", "--input", good, "--output", out},
		"checksum no input":   {"checksum", "--output", out},
		"flag not for stats":  {"stats", "--input", good, "--output", out, "--allow-live-probe"},
		"empty prefix option": {"stats", "--", good, out},
	} {
		rc, stdout, stderr := analyze(t, args...)
		if rc != 2 || stdout != "" || !strings.Contains(stderr, "error: ") || !strings.Contains(stderr, "usage: serial-frame-analyze") {
			t.Errorf("%s: rc = %d stdout = %q stderr = %q, want exit 2 with usage and error", name, rc, stdout, stderr)
		}
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("evidence written after a usage error")
	}
	for _, args := range [][]string{{"-h"}, {"--help"}, {"stats", "-h"}, {"diff", "--help"}, {"checksum", "--input", good, "-h"}} {
		rc, stdout, stderr := analyze(t, args...)
		if rc != 0 || !strings.HasPrefix(stdout, "usage: serial-frame-analyze") || stderr != "" {
			t.Errorf("%v: rc = %d stdout = %q stderr = %q, want help on stdout", args, rc, stdout, stderr)
		}
	}
	// the error names every missing option, in definition order
	_, _, stderr := analyze(t, "diff")
	if !strings.HasSuffix(stderr, "error: the following arguments are required: --input-a, --input-b, --output\n") {
		t.Errorf("stderr = %q", stderr)
	}
}

func TestAnalyzeArgumentForms(t *testing.T) {
	dir := t.TempDir()
	good := "testdata/frames/basic.log"
	for i, args := range [][]string{
		{"stats", "--input=" + good, "--output=" + filepath.Join(dir, "a.json")},
		{"stats", "--inp", good, "--out", filepath.Join(dir, "b.json")},
		{"stats", "--input", "-", "--output", filepath.Join(dir, "c.json")}, // "-" is a value, not an option
	} {
		rc, _, stderr := analyze(t, args...)
		wantRC := 0
		if i == 2 {
			wantRC = 2 // the file named "-" does not exist: a value, so an I/O error rather than a usage error
		}
		if rc != wantRC {
			t.Errorf("%v: rc = %d stderr = %q, want %d", args, rc, stderr, wantRC)
		}
	}
	// a value that holds a space starts with "-" and is still a value: the failure is an I/O error, not usage
	rc, _, stderr := analyze(t, "stats", "--input", "-x y.log", "--output", filepath.Join(dir, "d.json"))
	if rc != 2 || !strings.HasPrefix(stderr, "serial-frame-analyze: -x y.log: No such file or directory") {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
}

func TestAnalyzeStdoutEmptyOnSuccess(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o.json")
	rc, stdout, stderr := analyze(t, "stats", "--input", "testdata/frames/basic.log", "--output", out)
	if rc != 0 || stdout != "" || stderr != "" {
		t.Errorf("rc = %d stdout = %q stderr = %q, want silent success", rc, stdout, stderr)
	}
	if b, _ := os.ReadFile(out); !bytes.HasSuffix(b, []byte("}\n")) {
		t.Errorf("evidence does not end with a closing brace and newline: %q", b)
	}
}

// A zero-byte log is not malformed: the run completes with no frames and empty results (pre-port T17).
func TestAnalyzeZeroByteInput(t *testing.T) {
	dir := t.TempDir()
	in, out := filepath.Join(dir, "zero.log"), filepath.Join(dir, "o.json")
	if err := os.WriteFile(in, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if rc, stdout, stderr := analyze(t, "stats", "--input", in, "--output", out); rc != 0 || stdout != "" || stderr != "" {
		t.Fatalf("rc = %d stdout = %q stderr = %q", rc, stdout, stderr)
	}
	doc := evidence(t, out)
	input, sum, res := obj(doc["input"]), obj(doc["summary"]), obj(doc["results"])
	if doc["status"] != "complete" || doc["truncated"] != false || doc["errors"] != nil {
		t.Errorf("status = %v truncated = %v errors = %v", doc["status"], doc["truncated"], doc["errors"])
	}
	if input["sha256"] != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" || input["line_count"] != 0.0 || input["frame_count"] != 0.0 {
		t.Errorf("input = %v", input)
	}
	if sum["frame_count"] != 0.0 || sum["distinct_lengths"] != 0.0 || sum["line_count"] != 0.0 {
		t.Errorf("summary = %v", sum)
	}
	if len(arr(res["length_histogram"])) != 0 || res["most_common_length"] != nil || len(arr(res["variability"])) != 0 {
		t.Errorf("results = %v", res)
	}
}

// One frame line whose hex column holds a non-hex token is unrecognized, so a log with nothing else fails (pre-port T14).
func TestAnalyzeNonHexOnlyLine(t *testing.T) {
	dir := t.TempDir()
	in, out := filepath.Join(dir, "zz.log"), filepath.Join(dir, "o.json")
	if err := os.WriteFile(in, []byte("len=3 81 00 zz\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if rc, _, stderr := analyze(t, "stats", "--input", in, "--output", out); rc != 1 {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	doc := evidence(t, out)
	errs := arr(doc["errors"])
	if doc["status"] != "failed" || doc["line_count"] != 1.0 || doc["skipped_line_count"] != 1.0 || len(errs) != 1 ||
		errs[0] != "line 1: unrecognized format: 'len=3 81 00 zz'" {
		t.Errorf("evidence = %v", doc)
	}
	if _, ok := doc["summary"]; ok {
		t.Error("a failed run carries a summary")
	}
}
