//go:build linux

package formats

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"unicode"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// The legacy zip_metadata.py / zip_stored.py are the oracle: testdata/zip/parity_driver.py runs their real
// parsers over a batch of cases in one process and the Go reader must agree on every verdict, every message
// and every byte of the canonical output.

const zipToolbelt = "../../../toolbelt"

type pyResult struct {
	OK     bool   `json:"ok"`
	Msg    string `json:"msg"`
	Canon  string `json:"canon"`
	Meta   string `json:"meta_sha256"`
	Value  any    `json:"value"`
	Cn     bool   `json:"cn"`
	Class_ string `json:"class"`
	Name   string `json:"name"`
	Parent string `json:"parent"`
}

// runPy runs the legacy driver; a missing python3 FAILS the test (a skipped parity test proves nothing).
func runPy(t testing.TB, op string, cases any) []pyResult {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	tb, err := filepath.Abs(zipToolbelt)
	if err != nil {
		t.Fatal(err)
	}
	in, err := json.Marshal(cases)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(py, "-I", "testdata/zip/parity_driver.py", tb, op)
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

type invCase struct {
	Path       string `json:"path"`
	MaxCD      int64  `json:"max_cd"`
	MaxEntries int64  `json:"max_entries"`
	MaxField   int64  `json:"max_field"`
	MaxReport  int64  `json:"max_report"`
}

var defaultInv = invCase{MaxCD: 16 << 20, MaxEntries: 10000, MaxField: 65536, MaxReport: 16 << 20}

// goInventory is zm.inventory over the Go reader, rendered like the driver renders the oracle.
func goInventory(t testing.TB, c invCase) pyResult {
	t.Helper()
	f, st, err := zipOpenInput(c.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	d, err := ReadZipDirectory(f, st.Size, ZipCaps{MaxCentralDirectory: c.MaxCD, MaxEntries: c.MaxEntries, MaxField: c.MaxField}, zipReportGuard(c.MaxReport))
	if err != nil {
		return pyResult{Msg: err.Error()}
	}
	canon, err := jsonout.CanonicalUnicode(zipParsed(d))
	if err != nil {
		t.Fatal(err)
	}
	meta, err := d.Metadata(f)
	if err != nil {
		t.Fatal(err)
	}
	return pyResult{OK: true, Canon: string(canon), Meta: sha256Hex(meta)}
}

func compareResults(t *testing.T, label string, want, got pyResult) {
	t.Helper()
	if want.OK != got.OK {
		t.Errorf("%s: oracle ok=%v (%s), Go ok=%v (%s)", label, want.OK, want.Msg, got.OK, got.Msg)
		return
	}
	if !want.OK {
		if want.Msg != got.Msg {
			t.Errorf("%s: message differs\n oracle: %q\n Go:     %q", label, want.Msg, got.Msg)
		}
		return
	}
	if want.Canon != got.Canon {
		t.Errorf("%s: canonical output differs\n oracle: %s\n Go:     %s", label, want.Canon, got.Canon)
	}
	if want.Meta != got.Meta {
		t.Errorf("%s: metadata digest differs: oracle %s Go %s", label, want.Meta, got.Meta)
	}
}

// mutants is every single-byte corruption of base (three replacement values per offset), written to dir.
func mutants(t testing.TB, dir, tag string, base []byte) []string {
	t.Helper()
	var paths []string
	for off := range base {
		for k, v := range []byte{0x00, 0xff, base[off] ^ 0x01} {
			if v == base[off] {
				continue
			}
			m := append([]byte(nil), base...)
			m[off] = v
			p := filepath.Join(dir, fmt.Sprintf("%s-%03d-%d.zip", tag, off, k))
			if err := os.WriteFile(p, m, 0o600); err != nil {
				t.Fatal(err)
			}
			paths = append(paths, p)
		}
	}
	return paths
}

func TestZipInventoryParity(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	var paths []string
	fixtures := metaFixtures()
	for name, p := range writeFixtures(t, dir, fixtures) {
		_ = name
		paths = append(paths, p)
	}
	for name, p := range writeFixtures(t, dir, storedFixtures()) {
		_ = name
		paths = append(paths, p)
	}
	paths = append(paths, mutants(t, dir, "mixed", fixtures["mixed.zip"])...)
	paths = append(paths, mutants(t, dir, "utf8", fixtures["utf8.zip"])...)
	paths = append(paths, mutants(t, dir, "prefix", fixtures["prefix.zip"])...)
	var cases []invCase
	for _, p := range paths {
		c := defaultInv
		c.Path = p
		cases = append(cases, c)
	}
	mixed := filepath.Join(dir, "mixed.zip")
	cases = append(cases, []invCase{
		{Path: mixed, MaxCD: 10, MaxEntries: 10000, MaxField: 65536, MaxReport: 16 << 20},
		{Path: mixed, MaxCD: 16 << 20, MaxEntries: 2, MaxField: 65536, MaxReport: 16 << 20},
		{Path: mixed, MaxCD: 16 << 20, MaxEntries: 10000, MaxField: 3, MaxReport: 16 << 20},
		{Path: mixed, MaxCD: 16 << 20, MaxEntries: 10000, MaxField: 65536, MaxReport: 100},
		{Path: mixed, MaxCD: 16 << 20, MaxEntries: 10000, MaxField: 65536, MaxReport: 1500},
		{Path: filepath.Join(dir, "comment.zip"), MaxCD: 16 << 20, MaxEntries: 10000, MaxField: 5, MaxReport: 16 << 20},
	}...)
	want := runPy(t, "inventory", cases)
	okCount := 0
	for i, c := range cases {
		got := goInventory(t, c)
		compareResults(t, fmt.Sprintf("%s %+v", filepath.Base(c.Path), c), want[i], got)
		if want[i].OK {
			okCount++
		}
	}
	if okCount < 20 || okCount == len(cases) {
		t.Fatalf("the corpus must mix accepted and rejected archives; accepted %d of %d", okCount, len(cases))
	}
}

type storedCase struct {
	Path        string `json:"path"`
	MaxMetadata int64  `json:"max_metadata"`
	MaxEntries  int64  `json:"max_entries"`
	MaxPath     int64  `json:"max_path"`
	MaxDepth    int64  `json:"max_depth"`
	MaxEntry    int64  `json:"max_entry"`
	MaxTotal    int64  `json:"max_total"`
	MaxReport   int64  `json:"max_report"`
}

var defaultStored = storedCase{MaxMetadata: 16 << 20, MaxEntries: 10000, MaxPath: 4096, MaxDepth: 64, MaxEntry: 1 << 30, MaxTotal: 1 << 30, MaxReport: 16 << 20}

func goStoredInspect(t testing.TB, c storedCase) pyResult {
	t.Helper()
	f, st, err := zipOpenInput(c.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	_, recs, err := inspectStored(f, st.Size, storedLimits{
		maxMetadata: c.MaxMetadata, maxEntries: c.MaxEntries, maxPath: c.MaxPath, maxDepth: c.MaxDepth,
		maxEntry: c.MaxEntry, maxTotal: c.MaxTotal, maxReport: c.MaxReport,
	})
	if err != nil {
		return pyResult{Msg: err.Error()}
	}
	out := make([]any, len(recs))
	for i, r := range recs {
		typ := "file"
		if r.dir {
			typ = "directory"
		}
		out[i] = map[string]any{"path": r.path, "type": typ, "size": r.entry.Uncompressed, "crc32": fmt.Sprintf("%08x", r.entry.CRC32), "payload_offset": r.local.DataOffset}
	}
	canon, err := jsonout.CanonicalUnicode(out)
	if err != nil {
		t.Fatal(err)
	}
	return pyResult{OK: true, Canon: string(canon)}
}

func TestZipStoredInspectParity(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	fixtures := storedFixtures()
	var paths []string
	for _, p := range writeFixtures(t, dir, fixtures) {
		paths = append(paths, p)
	}
	for name, p := range writeFixtures(t, dir, metaFixtures()) {
		_ = name
		paths = append(paths, p)
	}
	paths = append(paths, mutants(t, dir, "good", fixtures["good.zip"])...)
	paths = append(paths, mutants(t, dir, "nested", fixtures["nested"])...)
	var cases []storedCase
	for _, p := range paths {
		c := defaultStored
		c.Path = p
		cases = append(cases, c)
	}
	good := filepath.Join(dir, "good.zip")
	for _, mod := range []func(*storedCase){
		func(c *storedCase) { c.MaxEntries = 1 },
		func(c *storedCase) { c.MaxPath = 3 },
		func(c *storedCase) { c.MaxDepth = 1 },
		func(c *storedCase) { c.MaxEntry = 4 },
		func(c *storedCase) { c.MaxTotal = 6 },
		func(c *storedCase) { c.MaxReport = 100 },
		func(c *storedCase) { c.MaxMetadata = 10 },
	} {
		c := defaultStored
		c.Path = good
		mod(&c)
		cases = append(cases, c)
	}
	want := runPy(t, "stored_inspect", cases)
	okCount := 0
	for i, c := range cases {
		got := goStoredInspect(t, c)
		compareResults(t, fmt.Sprintf("%s %+v", filepath.Base(c.Path), c), want[i], got)
		if want[i].OK {
			okCount++
		}
	}
	if okCount < 5 || okCount == len(cases) {
		t.Fatalf("the corpus must mix accepted and rejected archives; accepted %d of %d", okCount, len(cases))
	}
}

func TestZipNFCParity(t *testing.T) {
	t.Parallel()
	var inputs []string
	add := func(r rune) {
		if !(r >= 0xD800 && r <= 0xDFFF) {
			inputs = append(inputs, string(r))
		}
	}
	for r := rune(1); r < 0x32000; r++ {
		add(r)
	}
	for r := rune(0xE0000); r < 0xE0200; r++ {
		add(r)
	}
	// Sequences drawn from the characters that decompose, compose or reorder, plus Hangul jamo and ASCII.
	pool := []rune{'a', 'e', 'o', 'A', 0x300, 0x301, 0x302, 0x308, 0x323, 0x327, 0x345, 0x3099, 0x1100, 0x1161, 0x11A8, 0xAC00, 0xAC01, 0x1E0B, 0x1E0D, 0x212B, 0x2126, 0x0344, 0x0F73, 0x0F71, 0x0F72}
	rng := rand.New(rand.NewPCG(7, 11))
	for i := 0; i < 20000; i++ {
		n := 1 + rng.IntN(6)
		var sb strings.Builder
		for j := 0; j < n; j++ {
			sb.WriteRune(pool[rng.IntN(len(pool))])
		}
		inputs = append(inputs, sb.String())
	}
	want := runPy(t, "nfc", inputs)
	skipped := 0
	for i, in := range inputs {
		if want[i].Cn {
			skipped++
			continue
		}
		if got := zipNFC(in); got != want[i].Value.(string) {
			t.Fatalf("NFC(%+q) = %+q, oracle %+q", in, got, want[i].Value)
		}
	}
	if skipped > len(inputs)/2 {
		t.Fatalf("%d of %d NFC inputs were skipped as unassigned in the oracle's Unicode; the oracle is too old to judge the tables", skipped, len(inputs))
	}
}

func TestZipDecodeParity(t *testing.T) {
	t.Parallel()
	type dc struct {
		Hex string `json:"hex"`
		Enc string `json:"enc"`
	}
	var cases []dc
	var raws [][]byte
	add := func(b []byte, enc string) {
		cases = append(cases, dc{hex.EncodeToString(b), enc})
		raws = append(raws, b)
	}
	all := make([]byte, 256)
	for i := range all {
		all[i] = byte(i)
	}
	add(all, "cp437")
	for _, s := range []string{
		"\xe2\x82", "\xe2\x82\xac", "\xf0\x9f\x98", "\xf0\x80\x80", "\xed\xa0\x80", "\xc0\xaf", "\xf4\x90\x80\x80", "\x80\x80", "a\xffb", "\xe2a", "\xf0\x9f\x98a",
		"\xe0\x80", "\xe0\xa0", "\xf8\x88\x80\x80\x80", "\xc2", "\xf1\x80\x80", "\xed\x9f\xbf", "\xf4\x8f\xbf\xbf",
	} {
		add([]byte(s), "utf-8")
	}
	rng := rand.New(rand.NewPCG(3, 5))
	for i := 0; i < 5000; i++ {
		b := make([]byte, rng.IntN(10))
		for j := range b {
			b[j] = []byte{0x41, 0x80, 0xbf, 0xc2, 0xe0, 0xed, 0xf0, 0xf4, 0xff, 0xa0, 0x9f, 0x90}[rng.IntN(12)]
		}
		add(b, "utf-8")
	}
	want := runPy(t, "decode", cases)
	for i, c := range cases {
		var got string
		if c.Enc == "cp437" {
			got = zipDecodeCP437(raws[i])
		} else {
			got = zipDecodeUTF8Replace(raws[i])
		}
		if got != want[i].Value.(string) {
			t.Fatalf("%s decode of %x = %+q, oracle %+q", c.Enc, raws[i], got, want[i].Value)
		}
	}
	for _, r := range zipCP437 {
		if r == unicode.ReplacementChar {
			t.Fatal("the cp437 table must not contain U+FFFD")
		}
	}
}

func TestPyIntParity(t *testing.T) {
	t.Parallel()
	inputs := []string{"1", "0", "-1", "+5", " 7 ", "1_000", "1__0", "_1", "1_", "0x10", "1e3", "", " ", "--1", "+-1", "\u0663", "12a", "9223372036854775807", "9223372036854775808", "-9223372036854775808", "007"}
	want := runPy(t, "pyint", inputs)
	for i, in := range inputs {
		v, err := pyInt(in)
		if !want[i].OK {
			if err == nil {
				t.Errorf("pyInt(%q) = %d, oracle rejects", in, v)
			}
			continue
		}
		oracle, perr := strconv.ParseInt(want[i].Value.(json.Number).String(), 10, 64)
		if perr != nil {
			// Beyond int64 Python's bignum is accepted; the Go flag rejects it (documented difference).
			if err == nil {
				t.Errorf("pyInt(%q) must reject a value beyond int64", in)
			}
			continue
		}
		if err != nil || v != oracle {
			t.Errorf("pyInt(%q) = %d, %v; oracle %d", in, v, err, oracle)
		}
	}
}

func TestPyPathParity(t *testing.T) {
	t.Parallel()
	inputs := []string{"a", "a/b", "/a/b", "a/b/", "a//b", "./a", "a/./b", "a/..", "..", ".", "", "/", "//", "/a", "a/b/c.zip", "x/../y", "./", "a/b/.."}
	want := runPy(t, "path", inputs)
	for i, in := range inputs {
		if got := pyName(in); got != want[i].Name {
			t.Errorf("pyName(%q) = %q, oracle %q", in, got, want[i].Name)
		}
		if got := pyParent(in); got != want[i].Parent {
			t.Errorf("pyParent(%q) = %q, oracle %q", in, got, want[i].Parent)
		}
	}
}

func sha256Hex(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
