//go:build linux && !nodiff

package formats

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// The frozen legacy zip_metadata.py / zip_stored.py (testdata/zip/legacy) are the oracle: testdata/zip/parity_driver.py runs their real
// parsers over a batch of cases in one process. These tests assert that the golden files under testdata/zip/golden still equal what the
// oracle answers (RSDD_UPDATE_GOLDEN=1 rewrites them); the *Golden tests in zipgolden_linux_test.go replay them through the Go code
// and stay inside the -tags nodiff build.

// zipLegacyDir holds the retired zip_metadata.py / zip_stored.py themselves; zipToolbelt still holds analysis_manifest.py and
// lib/, which the frozen legacy tools import.
const zipLegacyDir = "testdata/zip/legacy"

// runPy runs the legacy driver; a missing python3 FAILS the test (a skipped parity test proves nothing).
func runPy(t testing.TB, op string, cases any) []pyResult {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	ld, err := filepath.Abs(zipLegacyDir)
	if err != nil {
		t.Fatal(err)
	}
	in, err := json.Marshal(cases)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(py, "-I", "testdata/zip/parity_driver.py", ld, op)
	var out, stderr bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("driver %s failed: %v\n%s", op, err, stderr.String())
	}
	var rs []pyResult
	dec := json.NewDecoder(bytes.NewReader(out.Bytes()))
	dec.UseNumber()
	if err := dec.Decode(&rs); err != nil {
		t.Fatalf("driver output: %v", err)
	}
	if want := reflect.ValueOf(cases).Len(); len(rs) != want {
		t.Fatalf("driver returned %d results for %d cases", len(rs), want)
	}
	return rs
}

// checkZipGolden asserts that the golden file equals got, or rewrites it under RSDD_UPDATE_GOLDEN=1. The file holds one JSON
// element per line, so a regenerated golden diffs readably.
func checkZipGolden[T any](t testing.TB, name string, got []T) {
	t.Helper()
	var sb strings.Builder
	sb.WriteString("[\n")
	for i, g := range got {
		b, err := json.Marshal(g)
		if err != nil {
			t.Fatal(err)
		}
		sb.Write(b)
		if i < len(got)-1 {
			sb.WriteString(",")
		}
		sb.WriteString("\n")
	}
	sb.WriteString("]\n")
	path := zipGoldDir + name + ".json"
	if os.Getenv("RSDD_UPDATE_GOLDEN") == "1" {
		if err := os.MkdirAll(zipGoldDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(sb.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want := loadZipGolden[T](t, name)
	if !reflect.DeepEqual(want, got) {
		for i := range want {
			if i >= len(got) || !reflect.DeepEqual(want[i], got[i]) {
				var g any
				if i < len(got) {
					g = got[i]
				}
				t.Fatalf("golden %s differs from the oracle at element %d (golden holds %d, oracle gave %d)\n golden: %+v\n oracle: %+v\n(regenerate with RSDD_UPDATE_GOLDEN=1)", name, i, len(want), len(got), want[i], g)
			}
		}
		t.Fatalf("golden %s holds %d elements, the oracle gave %d (regenerate with RSDD_UPDATE_GOLDEN=1)", name, len(want), len(got))
	}
}

func TestZipInventoryParity(t *testing.T) {
	t.Parallel()
	cases := inventoryCases(t)
	want := runPy(t, "inventory", cases)
	got := make([]zipGoldRes, len(cases))
	for i, c := range cases {
		got[i] = goldOf(invLabel(c), want[i])
	}
	checkZipGolden(t, "inventory", got)
}

func TestZipStoredInspectParity(t *testing.T) {
	t.Parallel()
	cases := storedInspectCases(t)
	want := runPy(t, "stored_inspect", cases)
	got := make([]zipGoldRes, len(cases))
	for i, c := range cases {
		got[i] = goldOf(storedLabel(c), want[i])
	}
	checkZipGolden(t, "stored_inspect", got)
}

// TestZipNFCParity compares Go's NFC with the oracle's on every input the oracle's Unicode assigns (CI's
// Python may be older or newer than the one that froze the golden: the comparison is on the intersection).
// The golden is checked against the oracle only when both left the same inputs unassigned; TestZipNFCGolden
// replays it through the Go code in the nodiff build either way.
func TestZipNFCParity(t *testing.T) {
	t.Parallel()
	inputs := nfcInputs()
	want := runPy(t, "nfc", inputs)
	var skip [][2]int
	var d zipDigest
	for i, in := range inputs {
		if want[i].Cn {
			if n := len(skip); n > 0 && skip[n-1][1] == i-1 {
				skip[n-1][1] = i
			} else {
				skip = append(skip, [2]int{i, i})
			}
			continue
		}
		py := want[i].Value.(string)
		if got := zipNFC(in); got != py {
			t.Errorf("input %d %+q: Go NFC %+q, oracle %+q", i, in, got, py)
		}
		d.add(py)
	}
	got := zipNFCGold{Inputs: len(inputs), Skip: skip, Digest: d.sum()}
	if os.Getenv("RSDD_UPDATE_GOLDEN") == "1" {
		checkZipGolden(t, "nfc", []zipNFCGold{got})
		return
	}
	if g := loadZipGolden[zipNFCGold](t, "nfc")[0]; !slices.Equal(g.Skip, got.Skip) {
		t.Logf("the oracle's Unicode differs from the golden's (%d vs %d unassigned ranges): golden not compared", len(got.Skip), len(g.Skip))
		return
	}
	checkZipGolden(t, "nfc", []zipNFCGold{got})
}

func TestZipDecodeParity(t *testing.T) {
	t.Parallel()
	cases, _ := decodeCases()
	want := runPy(t, "decode", cases)
	var d zipDigest
	for i := range cases {
		d.add(want[i].Value.(string))
	}
	checkZipGolden(t, "decode", []zipDigestGold{{Inputs: len(cases), Digest: d.sum()}})
}

func TestPyIntParity(t *testing.T) {
	t.Parallel()
	want := runPy(t, "pyint", pyIntInputs)
	got := make([]zipPyIntGold, len(pyIntInputs))
	for i, in := range pyIntInputs {
		got[i] = zipPyIntGold{Input: in, OK: want[i].OK}
		if want[i].OK {
			got[i].Value = want[i].Value.(json.Number).String()
		}
	}
	checkZipGolden(t, "pyint", got)
}

func TestPyPathParity(t *testing.T) {
	t.Parallel()
	want := runPy(t, "path", pyPathInputs)
	got := make([]zipPathGold, len(pyPathInputs))
	for i, in := range pyPathInputs {
		got[i] = zipPathGold{Input: in, Name: want[i].Name, Parent: want[i].Parent}
	}
	checkZipGolden(t, "path", got)
}
