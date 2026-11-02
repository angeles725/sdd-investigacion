package carve

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"testing/iotest"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// patterned is n bytes that differ from one position to the next, so a range read from the wrong offset never
// compares equal.
func patterned(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(i*7 + i>>8 + i>>16)
	}
	return b
}

// makeStage lays out what a worker leaves behind: input.bin, one file per range under carves/ (only when there
// is a range or withCarvesDir), and the canonical report, all 0400 files in 0700 directories owned by the caller.
func makeStage(t *testing.T, input []byte, items []candidate, withCarvesDir bool) (string, map[string]any) {
	t.Helper()
	stage := filepath.Join(t.TempDir(), "stage")
	for _, d := range []string{stage, filepath.Join(stage, "carves")} {
		if d != stage && !withCarvesDir && len(items) == 0 {
			continue
		}
		if err := os.Mkdir(d, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	put := func(rel string, data []byte) {
		if err := os.WriteFile(filepath.Join(stage, rel), data, 0o400); err != nil {
			t.Fatal(err)
		}
	}
	put("input.bin", input)
	records := []any{}
	for _, it := range items {
		data := input[it.start:it.end]
		sum := sha256.Sum256(data)
		rec := carveRecord{it.kind, it.start, it.end - it.start, carvePath(it.start, it.kind), "sha256:" + hex.EncodeToString(sum[:])}
		put(rec.Path, data)
		records = append(records, rec.object())
	}
	canonical, err := jsonout.Canonical(map[string]any{"carves": records})
	if err != nil {
		t.Fatal(err)
	}
	put(schema+".json", canonical)
	report, err := decodeReport(canonical)
	if err != nil {
		t.Fatal(err)
	}
	return stage, report
}

func euid() uint64 { return uint64(os.Geteuid()) }

func TestValidateTreeAcceptsEveryRecordSizeAndChunkShape(t *testing.T) {
	input := patterned(3<<20 + 100)
	for _, tc := range []struct {
		name string
		item candidate
	}{
		{"one byte", candidate{0, 1, kindSquashFS}},
		{"a partial chunk at an offset", candidate{9, 9 + 100, kindUImage}},
		{"exactly one chunk", candidate{3, 3 + 1<<20, kindUImage}},
		{"exactly two chunks at an offset", candidate{5, 5 + 2<<20, kindSquashFS}},
		{"two chunks and a tail", candidate{7, 7 + 2<<20 + 11, kindSquashFS}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stage, report := makeStage(t, input, []candidate{tc.item}, true)
			if err := validateTree(stage, report, euid()); err != nil {
				t.Fatalf("validateTree: %v", err)
			}
			if _, err := os.Lstat(filepath.Join(stage, "input.bin")); !os.IsNotExist(err) {
				t.Errorf("the staged input must be removed after validation, Lstat err = %v", err)
			}
		})
	}
}

func TestValidateTreeNeedsTheCarvesDirectoryToBeSynced(t *testing.T) {
	stage, report := makeStage(t, patterned(100), nil, false)
	if err := validateTree(stage, report, euid()); err == nil {
		t.Error("a tree without carves/ passed: the directory sync has to fail and be reported")
	}
}

func TestVerifyCarveRefusesWhatIsNotTheInputRange(t *testing.T) {
	input := patterned(1000)
	good := candidate{10, 510, kindUImage}
	stage, report := makeStage(t, input, []candidate{good}, true)
	records, err := carveRecords(report)
	if err != nil || len(records) != 1 {
		t.Fatal(records, err)
	}
	rec := records[0]
	if err := verifyCarve(stage, rec); err != nil {
		t.Fatalf("control: %v", err)
	}

	wrongSize := rec
	wrongSize.Size++
	wrongSum := rec
	wrongSum.SHA256 = "sha256:" + strings.Repeat("0", 64)
	for name, bad := range map[string]carveRecord{"size": wrongSize, "digest": wrongSum} {
		if err := verifyCarve(stage, bad); err == nil || err.Error() != "carve identity mismatch" {
			t.Errorf("wrong %s: err = %v, want carve identity mismatch", name, err)
		}
	}

	moved := rec
	moved.Offset++
	if err := verifyCarve(stage, moved); err == nil || err.Error() != "carve source range mismatch" {
		t.Errorf("a record pointing at another offset: err = %v, want carve source range mismatch", err)
	}

	missing := rec
	missing.Path = "carves/absent.bin"
	if err := verifyCarve(stage, missing); err == nil {
		t.Error("a missing carve file passed")
	}
	if err := os.Chmod(stage, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(stage, "input.bin")); err != nil {
		t.Fatal(err)
	}
	if err := verifyCarve(stage, rec); err == nil {
		t.Error("a missing staged input passed")
	}
}

func TestVerifyCarveRefusesATamperedCarve(t *testing.T) {
	stage, report := makeStage(t, patterned(1000), []candidate{{10, 510, kindUImage}}, true)
	records, _ := carveRecords(report)
	path := filepath.Join(stage, records[0].Path)
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	b[200] ^= 0xff
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := verifyCarve(stage, records[0]); err == nil || err.Error() != "carve source range mismatch" {
		t.Errorf("err = %v, want carve source range mismatch", err)
	}
}

func TestWriteExclusiveReportsACopyFailureAndRefusesAnExistingFile(t *testing.T) {
	dir := t.TempDir()
	boom := errors.New("boom")
	if err := writeExclusive(filepath.Join(dir, "a"), iotest.ErrReader(boom), nil); !errors.Is(err, boom) {
		t.Errorf("a failing source: err = %v, want boom", err)
	}
	var tee strings.Builder
	if err := writeExclusive(filepath.Join(dir, "b"), strings.NewReader("data"), &tee); err != nil || tee.String() != "data" {
		t.Errorf("tee: err = %v, tee = %q", err, tee.String())
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "b")); string(b) != "data" {
		t.Errorf("file = %q", b)
	}
	if fi, _ := os.Stat(filepath.Join(dir, "b")); fi.Mode().Perm() != 0o400 {
		t.Errorf("mode = %v, want 0400", fi.Mode().Perm())
	}
	if err := writeExclusive(filepath.Join(dir, "b"), strings.NewReader("again"), nil); !errors.Is(err, os.ErrExist) {
		t.Errorf("an existing file: err = %v, want exists", err)
	}
}

func TestWorkerRefusesAnInputThatChangesWhileItCarves(t *testing.T) {
	stage := t.TempDir()
	input := firmwareImage()
	in := filepath.Join(stage, "input.bin")
	if err := os.WriteFile(in, input, 0o400); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(input)
	rec := `{"path":"input.bin","size":` + strconv.Itoa(len(input)) + `,"sha256":"sha256:` + hex.EncodeToString(sum[:]) + `"}`
	c := config{stage: stage, inputRecord: rec, maxCarves: 16, maxFiles: 17, maxOutput: 1 << 30, bwrapPath: "/usr/bin/bwrap", bwrapSHA: "sha256:x"}

	// Touch the input's inode after the carves and the report are written and before the final identity check, the
	// window a concurrent writer would hit. The hook makes that point deterministic (a polling goroutine lost the race
	// to a fast worker on CI).
	saved := beforeFinalStat
	t.Cleanup(func() { beforeFinalStat = saved })
	beforeFinalStat = func() {
		if err := os.Chmod(in, 0o600); err != nil {
			t.Error(err)
		}
	}
	err := runWorker(c, euid())
	if err == nil || err.Error() != "staged input changed while carving" {
		t.Errorf("err = %v, want staged input changed while carving", err)
	}
}

func TestVerifyCarveChecksEveryChunkNotOnlyTheFirst(t *testing.T) {
	stage, report := makeStage(t, patterned(3<<20), []candidate{{5, 5 + 2<<20, kindSquashFS}}, true)
	records, _ := carveRecords(report)
	path := filepath.Join(stage, records[0].Path)
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	b[1<<20+500] ^= 0xff // inside the second chunk
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := verifyCarve(stage, records[0]); err == nil || err.Error() != "carve source range mismatch" {
		t.Errorf("err = %v, want carve source range mismatch", err)
	}
}
