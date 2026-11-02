package java

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func sha(b []byte) string {
	s := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(s[:])
}

func TestSoleOversizedArtifactKeepsATruthfulBoundedPrefix(t *testing.T) {
	stage := t.TempDir()
	output := filepath.Join(stage, "output")
	body := append(make([]byte, 0, 4097), strings.Repeat("a", 4096)+"b"...)
	writeFile(t, filepath.Join(output, "sole.bin"), body)
	e := newEnv(newHarness(t).stdio(nil, nil))
	records, truncated, err := e.outputInventory(stage, output, 10, 4096)
	if err != nil {
		t.Fatal(err)
	}
	want := []outputRecord{{path: "sole.bin", size: 4096, sha256: sha(body[:4096])}}
	if !truncated || !reflect.DeepEqual(records, want) {
		t.Fatalf("records = %+v truncated=%v, want %+v", records, truncated, want)
	}
	if got, _ := os.ReadFile(filepath.Join(output, "sole.bin")); string(got) != string(body[:4096]) {
		t.Error("the file on disk must be exactly the recorded prefix")
	}
}

func TestInventoryOrdersByPathCutsAtTheFileCapAndDeletesTheRest(t *testing.T) {
	stage := t.TempDir()
	output := filepath.Join(stage, "output")
	for _, n := range []string{"b/z.java", "a.java", "b/a.java", "c.java"} {
		writeFile(t, filepath.Join(output, n), []byte("x"))
	}
	e := newEnv(newHarness(t).stdio(nil, nil))
	records, truncated, err := e.outputInventory(stage, output, 3, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, r := range records {
		got = append(got, r.path)
	}
	if !truncated || !reflect.DeepEqual(got, []string{"a.java", "b/a.java", "b/z.java"}) {
		t.Fatalf("records = %v truncated=%v", got, truncated)
	}
	if pathExists(filepath.Join(output, "c.java")) {
		t.Error("a file past the cap must be deleted, not merely unlisted")
	}
}

func TestInventoryWithinCapsIsNotTruncatedAndPrunesEmptyDirectories(t *testing.T) {
	stage := t.TempDir()
	output := filepath.Join(stage, "output")
	writeFile(t, filepath.Join(output, "p/q/A.java"), []byte("x"))
	if err := os.MkdirAll(filepath.Join(output, "empty/deeper"), 0o755); err != nil {
		t.Fatal(err)
	}
	e := newEnv(newHarness(t).stdio(nil, nil))
	records, truncated, err := e.outputInventory(stage, output, 10, 100)
	if err != nil || truncated || len(records) != 1 {
		t.Fatalf("records=%v truncated=%v err=%v", records, truncated, err)
	}
	if pathExists(filepath.Join(output, "empty")) || !pathExists(filepath.Join(output, "p/q/A.java")) || !pathExists(output) {
		t.Error("empty directories go, populated ones and the output root stay")
	}
}

func TestInventoryOfAMissingOutputIsEmptyNotAnError(t *testing.T) {
	stage := t.TempDir()
	e := newEnv(newHarness(t).stdio(nil, nil))
	records, truncated, err := e.outputInventory(stage, filepath.Join(stage, "none"), 10, 100)
	if err != nil || truncated || records == nil || len(records) != 0 {
		t.Fatalf("records=%v truncated=%v err=%v", records, truncated, err)
	}
}

func TestInventoryRefusesASymlinkAnywhereInTheOutput(t *testing.T) {
	stage := t.TempDir()
	output := filepath.Join(stage, "output")
	writeFile(t, filepath.Join(output, "ok.java"), []byte("x"))
	if err := os.Symlink("/etc/passwd", filepath.Join(output, "sub-link")); err != nil {
		t.Fatal(err)
	}
	e := newEnv(newHarness(t).stdio(nil, nil))
	if _, _, err := e.outputInventory(stage, output, 10, 100); err == nil || err.Error() != "adapter output symlink is forbidden" {
		t.Fatalf("err = %v", err)
	}
	if _, err := outputContainsBytes(output); err == nil {
		t.Error("outputContainsBytes must refuse a symlink too")
	}
}

func TestOutputContainsBytesIgnoresEmptyFiles(t *testing.T) {
	out := t.TempDir()
	writeFile(t, filepath.Join(out, "empty"), nil)
	if has, err := outputContainsBytes(out); err != nil || has {
		t.Fatalf("has=%v err=%v", has, err)
	}
	writeFile(t, filepath.Join(out, "d/full"), []byte("x"))
	if has, err := outputContainsBytes(out); err != nil || !has {
		t.Fatalf("has=%v err=%v", has, err)
	}
	if has, err := outputContainsBytes(filepath.Join(out, "gone")); err != nil || has {
		t.Fatalf("a missing output holds no bytes: has=%v err=%v", has, err)
	}
}

func TestNormalizeDiagnosticsReplacesRootsAndSharesOneBudget(t *testing.T) {
	stage := "/work/out.stage"
	engine := t.TempDir()
	writeFile(t, filepath.Join(engine, "stdout.raw.txt"), []byte("at "+stage+"/x and "+sandboxRoot+"/y\n"))
	writeFile(t, filepath.Join(engine, "stderr.raw.txt"), []byte("err "+stage+"\n"))
	remaining, truncated, err := normalizeDiagnostics(engine, stage, 1000)
	if err != nil || truncated {
		t.Fatalf("truncated=%v err=%v", truncated, err)
	}
	out, _ := os.ReadFile(filepath.Join(engine, "stdout.txt"))
	errb, _ := os.ReadFile(filepath.Join(engine, "stderr.txt"))
	if string(out) != "at <STAGING_ROOT>/x and <STAGING_ROOT>/y\n" || string(errb) != "err <STAGING_ROOT>\n" {
		t.Errorf("stdout=%q stderr=%q", out, errb)
	}
	if remaining != 1000-int64(len(out))-int64(len(errb)) {
		t.Errorf("remaining = %d: the budget is charged for the normalised bytes", remaining)
	}
	for _, n := range []string{"stdout.raw.txt", "stderr.raw.txt"} {
		if pathExists(filepath.Join(engine, n)) {
			t.Errorf("%s must be removed", n)
		}
	}
}

func TestNormalizeDiagnosticsCutsAtTheBudgetAndReportsIt(t *testing.T) {
	engine := t.TempDir()
	writeFile(t, filepath.Join(engine, "stdout.raw.txt"), []byte(strings.Repeat("o", 30)))
	writeFile(t, filepath.Join(engine, "stderr.raw.txt"), []byte(strings.Repeat("e", 30)))
	remaining, truncated, err := normalizeDiagnostics(engine, "/s", 40)
	if err != nil || !truncated || remaining != 0 {
		t.Fatalf("remaining=%d truncated=%v err=%v", remaining, truncated, err)
	}
	out, _ := os.ReadFile(filepath.Join(engine, "stdout.txt"))
	errb, _ := os.ReadFile(filepath.Join(engine, "stderr.txt"))
	if len(out) != 30 || len(errb) != 10 {
		t.Errorf("stdout %d bytes, stderr %d bytes; stdout keeps its bytes first and stderr gets the rest", len(out), len(errb))
	}
}

func TestNormalizeDiagnosticsWithNothingToReadStillWritesBothFiles(t *testing.T) {
	engine := t.TempDir()
	remaining, truncated, err := normalizeDiagnostics(engine, "/s", 100)
	if err != nil || truncated || remaining != 100 {
		t.Fatalf("remaining=%d truncated=%v err=%v", remaining, truncated, err)
	}
	for _, n := range []string{"stdout.txt", "stderr.txt"} {
		if fi, err := os.Stat(filepath.Join(engine, n)); err != nil || fi.Size() != 0 {
			t.Errorf("%s: %v, %v", n, fi, err)
		}
	}
}

func TestScanFilesStopsPastACapAndRefusesSymlinks(t *testing.T) {
	root := t.TempDir()
	for _, n := range []string{"a", "b", "c", "d/e"} {
		writeFile(t, filepath.Join(root, n), []byte("12345"))
	}
	if files, total, err := scanFiles(root, 10, 1000); err != nil || files != 4 || total != 20 {
		t.Errorf("files=%d total=%d err=%v", files, total, err)
	}
	if files, _, _ := scanFiles(root, 2, 1000); files != 3 {
		t.Errorf("past the file cap the scan stops at the first excess file, saw %d", files)
	}
	if _, total, _ := scanFiles(root, 10, 12); total != 15 {
		t.Errorf("past the byte cap the scan stops at the first excess byte count, saw %d", total)
	}
	if files, total, err := scanFiles(filepath.Join(root, "absent"), 1, 1); err != nil || files != 0 || total != 0 {
		t.Errorf("a missing root holds nothing: %d %d %v", files, total, err)
	}
	if err := os.Symlink("/etc/passwd", filepath.Join(root, "l")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := scanFiles(root, 10, 1000); err == nil || !strings.HasPrefix(err.Error(), "adapter emitted a symlink: ") {
		t.Errorf("err = %v", err)
	}
}
