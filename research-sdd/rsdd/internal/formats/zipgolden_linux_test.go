//go:build linux

package formats

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"unicode"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// The zip parity tests (zipparity_linux_test.go, zipcmd_linux_test.go) compare the Go code with the frozen Python oracle and are
// excluded from `make teeth` (-tags nodiff). What the oracle answered is frozen under testdata/zip/golden: the oracle tests assert
// that each golden file still equals what the oracle says, and the *Golden tests here replay the same inputs through the Go code
// and compare with the golden file, so the mutation run keeps the teeth the oracle used to provide.

const zipGoldDir = "testdata/zip/golden/"

func loadZipGolden[T any](t testing.TB, name string) []T {
	t.Helper()
	b, err := os.ReadFile(zipGoldDir + name + ".json")
	if err != nil {
		t.Fatalf("golden %s: %v (regenerate with RSDD_UPDATE_GOLDEN=1 go test ./internal/formats/ -run Parity)", name, err)
	}
	var v []T
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatalf("golden %s: %v", name, err)
	}
	return v
}

func zipSha256Hex(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

// pyResult is one verdict of the legacy driver.
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

// zipGoldRes is a frozen verdict: the canonical output is kept as its digest.
type zipGoldRes struct {
	Label string
	OK    bool
	Msg   string
	Canon string
	Meta  string
}

func goldOf(label string, r pyResult) zipGoldRes {
	g := zipGoldRes{Label: label, OK: r.OK, Msg: r.Msg, Meta: r.Meta}
	if r.OK {
		g.Canon = zipSha256Hex([]byte(r.Canon))
	}
	return g
}

func compareGold(t *testing.T, want, got zipGoldRes) {
	t.Helper()
	if want.Label != got.Label {
		t.Fatalf("golden case order drifted: %q vs %q", want.Label, got.Label)
	}
	if want.OK != got.OK {
		t.Errorf("%s: golden ok=%v (%s), Go ok=%v (%s)", want.Label, want.OK, want.Msg, got.OK, got.Msg)
		return
	}
	if want.Msg != got.Msg {
		t.Errorf("%s: message differs\n golden: %q\n Go:     %q", want.Label, want.Msg, got.Msg)
	}
	if want.Canon != got.Canon {
		t.Errorf("%s: canonical output digest differs: golden %s Go %s", want.Label, want.Canon, got.Canon)
	}
	if want.Meta != got.Meta {
		t.Errorf("%s: metadata digest differs: golden %s Go %s", want.Label, want.Meta, got.Meta)
	}
}

// ---------------------------------------------------------------- inventory

type invCase struct {
	Path       string `json:"path"`
	MaxCD      int64  `json:"max_cd"`
	MaxEntries int64  `json:"max_entries"`
	MaxField   int64  `json:"max_field"`
	MaxReport  int64  `json:"max_report"`
}

var defaultInv = invCase{MaxCD: 16 << 20, MaxEntries: 10000, MaxField: 65536, MaxReport: 16 << 20}

func invLabel(c invCase) string {
	return fmt.Sprintf("%s cd=%d entries=%d field=%d report=%d", filepath.Base(c.Path), c.MaxCD, c.MaxEntries, c.MaxField, c.MaxReport)
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

func sortedValues(m map[string]string) []string {
	var out []string
	for _, p := range m {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// inventoryCases builds the deterministic corpus of the inventory comparison.
func inventoryCases(t testing.TB) []invCase {
	t.Helper()
	dir := t.TempDir()
	fixtures := metaFixtures()
	paths := sortedValues(writeFixtures(t, dir, fixtures))
	paths = append(paths, sortedValues(writeFixtures(t, dir, storedFixtures()))...)
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
	return cases
}

// goInventory is zm.inventory over the Go reader, rendered like the driver renders the oracle.
func goInventory(t testing.TB, c invCase) zipGoldRes {
	t.Helper()
	g := zipGoldRes{Label: invLabel(c)}
	f, st, err := zipOpenInput(c.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	d, err := ReadZipDirectory(f, st.Size, ZipCaps{MaxCentralDirectory: c.MaxCD, MaxEntries: c.MaxEntries, MaxField: c.MaxField}, zipReportGuard(c.MaxReport))
	if err != nil {
		g.Msg = err.Error()
		return g
	}
	canon, err := jsonout.CanonicalUnicode(zipParsed(d))
	if err != nil {
		t.Fatal(err)
	}
	meta, err := d.Metadata(f)
	if err != nil {
		t.Fatal(err)
	}
	g.OK, g.Canon, g.Meta = true, zipSha256Hex(canon), zipSha256Hex(meta)
	return g
}

func TestZipInventoryGolden(t *testing.T) {
	t.Parallel()
	want := loadZipGolden[zipGoldRes](t, "inventory")
	cases := inventoryCases(t)
	if len(want) != len(cases) {
		t.Fatalf("golden holds %d cases, the corpus builds %d", len(want), len(cases))
	}
	ok := 0
	for i, c := range cases {
		compareGold(t, want[i], goInventory(t, c))
		if want[i].OK {
			ok++
		}
	}
	if ok < 20 || ok == len(cases) {
		t.Fatalf("the corpus must mix accepted and rejected archives; accepted %d of %d", ok, len(cases))
	}
}

// ---------------------------------------------------------------- stored inspect

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

func storedLabel(c storedCase) string {
	return fmt.Sprintf("%s meta=%d entries=%d path=%d depth=%d entry=%d total=%d report=%d", filepath.Base(c.Path), c.MaxMetadata, c.MaxEntries, c.MaxPath, c.MaxDepth, c.MaxEntry, c.MaxTotal, c.MaxReport)
}

func storedInspectCases(t testing.TB) []storedCase {
	t.Helper()
	dir := t.TempDir()
	fixtures := storedFixtures()
	paths := sortedValues(writeFixtures(t, dir, fixtures))
	paths = append(paths, sortedValues(writeFixtures(t, dir, metaFixtures()))...)
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
	nested := filepath.Join(dir, "nested.zip")
	for _, depth := range []int64{4, 3} { // the four-component path is accepted at the cap and refused one below it
		c := defaultStored
		c.Path, c.MaxDepth = nested, depth
		cases = append(cases, c)
	}
	return cases
}

func goStoredInspect(t testing.TB, c storedCase) zipGoldRes {
	t.Helper()
	g := zipGoldRes{Label: storedLabel(c)}
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
		g.Msg = err.Error()
		return g
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
	g.OK, g.Canon = true, zipSha256Hex(canon)
	return g
}

func TestZipStoredInspectGolden(t *testing.T) {
	t.Parallel()
	want := loadZipGolden[zipGoldRes](t, "stored_inspect")
	cases := storedInspectCases(t)
	if len(want) != len(cases) {
		t.Fatalf("golden holds %d cases, the corpus builds %d", len(want), len(cases))
	}
	ok := 0
	for i, c := range cases {
		compareGold(t, want[i], goStoredInspect(t, c))
		if want[i].OK {
			ok++
		}
	}
	if ok < 5 || ok == len(cases) {
		t.Fatalf("the corpus must mix accepted and rejected archives; accepted %d of %d", ok, len(cases))
	}
}

// ---------------------------------------------------------------- NFC, decode, pyint, path

// zipDigest is the digest of a sequence of strings, each terminated by NUL.
type zipDigest struct{ parts []string }

func (d *zipDigest) add(s string) { d.parts = append(d.parts, s) }
func (d *zipDigest) sum() string {
	h := sha256.New()
	for _, p := range d.parts {
		h.Write([]byte(p))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

// zipNFCGold freezes the oracle's NFC of every input: the inputs the oracle's Unicode left unassigned are listed as inclusive
// index ranges and left out of the digest.
type zipNFCGold struct {
	Inputs int
	Skip   [][2]int
	Digest string
}

func nfcInputs() []string {
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
	return inputs
}

func inSkip(skip [][2]int, i int) bool {
	for _, r := range skip {
		if i >= r[0] && i <= r[1] {
			return true
		}
	}
	return false
}

func TestZipNFCGolden(t *testing.T) {
	t.Parallel()
	g := loadZipGolden[zipNFCGold](t, "nfc")[0]
	inputs := nfcInputs()
	if g.Inputs != len(inputs) {
		t.Fatalf("golden covers %d inputs, the corpus builds %d", g.Inputs, len(inputs))
	}
	var d zipDigest
	skipped := 0
	for i, in := range inputs {
		if inSkip(g.Skip, i) {
			skipped++
			continue
		}
		d.add(zipNFC(in))
	}
	if skipped > len(inputs)/2 {
		t.Fatalf("%d of %d NFC inputs are skipped as unassigned; the golden is too old to judge the tables", skipped, len(inputs))
	}
	if d.sum() != g.Digest {
		t.Fatalf("NFC digest differs from the golden: %s vs %s", d.sum(), g.Digest)
	}
}

type zipDecodeCase struct {
	Hex string `json:"hex"`
	Enc string `json:"enc"`
}

func decodeCases() ([]zipDecodeCase, [][]byte) {
	var cases []zipDecodeCase
	var raws [][]byte
	add := func(b []byte, enc string) {
		cases = append(cases, zipDecodeCase{hex.EncodeToString(b), enc})
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
	return cases, raws
}

type zipDigestGold struct {
	Inputs int
	Digest string
}

func TestZipDecodeGolden(t *testing.T) {
	t.Parallel()
	g := loadZipGolden[zipDigestGold](t, "decode")[0]
	cases, raws := decodeCases()
	if g.Inputs != len(cases) {
		t.Fatalf("golden covers %d inputs, the corpus builds %d", g.Inputs, len(cases))
	}
	var d zipDigest
	for i, c := range cases {
		if c.Enc == "cp437" {
			d.add(zipDecodeCP437(raws[i]))
		} else {
			d.add(zipDecodeUTF8Replace(raws[i]))
		}
	}
	if d.sum() != g.Digest {
		t.Fatalf("decode digest differs from the golden: %s vs %s", d.sum(), g.Digest)
	}
	for _, r := range zipCP437 {
		if r == unicode.ReplacementChar {
			t.Fatal("the cp437 table must not contain U+FFFD")
		}
	}
}

var pyIntInputs = []string{"1", "0", "-1", "+5", " 7 ", "1_000", "1__0", "_1", "1_", "0x10", "1e3", "", " ", "--1", "+-1", "٣", "12a", "9223372036854775807", "9223372036854775808", "-9223372036854775808", "007"}

type zipPyIntGold struct {
	Input string
	OK    bool
	Value string
}

func TestPyIntGolden(t *testing.T) {
	t.Parallel()
	want := loadZipGolden[zipPyIntGold](t, "pyint")
	if len(want) != len(pyIntInputs) {
		t.Fatalf("golden holds %d inputs, the corpus has %d", len(want), len(pyIntInputs))
	}
	for i, in := range pyIntInputs {
		w := want[i]
		v, err := pyInt(in)
		if !w.OK {
			if err == nil {
				t.Errorf("pyInt(%q) = %d, oracle rejects", in, v)
			}
			continue
		}
		oracle, perr := strconv.ParseInt(w.Value, 10, 64)
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

var pyPathInputs = []string{"a", "a/b", "/a/b", "a/b/", "a//b", "./a", "a/./b", "a/..", "..", ".", "", "/", "//", "/a", "a/b/c.zip", "x/../y", "./", "a/b/.."}

type zipPathGold struct {
	Input, Name, Parent string
}

func TestPyPathGolden(t *testing.T) {
	t.Parallel()
	want := loadZipGolden[zipPathGold](t, "path")
	if len(want) != len(pyPathInputs) {
		t.Fatalf("golden holds %d inputs, the corpus has %d", len(want), len(pyPathInputs))
	}
	for i, in := range pyPathInputs {
		if got := pyName(in); got != want[i].Name {
			t.Errorf("pyName(%q) = %q, oracle %q", in, got, want[i].Name)
		}
		if got := pyParent(in); got != want[i].Parent {
			t.Errorf("pyParent(%q) = %q, oracle %q", in, got, want[i].Parent)
		}
	}
}

// ---------------------------------------------------------------- command comparison

type zipTreeGold struct {
	Name string
	Mode string
	Sha  string // digest of a regular file's bytes; empty for the manifest, whose stamp differs per launch, and for non-files
}

// zipCmdGold is what one command run produced: the exit code, the stderr of a refusal, and for a success the published tree and
// the manifest fields that describe WHAT was produced.
type zipCmdGold struct {
	Label  string
	Code   int
	Stderr string
	Tree   []zipTreeGold
	Facts  map[string]string
}

var manifestFactKeys = []string{"schema_version", "input", "stdout", "stderr", "outputs", "findings", "limitations", "errors", "completeness", "isolation_profile"}

func treeGold(t testing.TB, root, inDir string) []zipTreeGold {
	t.Helper()
	tree := readTree(t, root)
	var out []zipTreeGold
	for _, n := range treeNames(tree) {
		e := tree[n]
		g := zipTreeGold{Name: n, Mode: e.mode.String()}
		if e.mode.IsRegular() && n != "analysis-manifest.v1.json" {
			g.Sha = zipSha256Hex([]byte(strings.ReplaceAll(e.data, inDir, "<in>")))
		}
		out = append(out, g)
	}
	return out
}

// manifestFacts renders the manifest fields that describe WHAT was produced. A report that embeds the input path has a size and a
// digest that depend on where the test ran, so the manifest entries naming such a file lose those two keys (the file itself is
// frozen, with the path normalized, in the tree digest).
func manifestFacts(t testing.TB, tree, inDir string) map[string]string {
	t.Helper()
	m := manifestOf(t, tree)
	var scrub func(v any)
	scrub = func(v any) {
		switch x := v.(type) {
		case map[string]any:
			if p, ok := x["path"].(string); ok {
				if b, err := os.ReadFile(filepath.Join(tree, p)); err == nil && strings.Contains(string(b), inDir) {
					delete(x, "sha256")
					delete(x, "size")
				}
			}
			for _, c := range x {
				scrub(c)
			}
		case []any:
			for _, c := range x {
				scrub(c)
			}
		}
	}
	facts := map[string]string{}
	for _, k := range manifestFactKeys {
		scrub(m[k])
		b, _ := json.Marshal(m[k])
		facts[k] = strings.ReplaceAll(string(b), inDir, "<in>")
	}
	return facts
}

func checkRunStamp(t testing.TB, tree string) {
	t.Helper()
	run := manifestOf(t, tree)["run"].(map[string]any)
	if run["started_at"] != "2026-01-02T03:04:05.678901Z" || run["ended_at"] != run["started_at"] {
		t.Errorf("manifest run stamp = %v, want the injected clock", run)
	}
}

func zipMetaCases(map[string]string) []cmdCase {
	return []cmdCase{
		{name: "empty.zip"}, {name: "mixed.zip"}, {name: "comment.zip"}, {name: "prefix.zip"}, {name: "utf8.zip"},
		{name: "truncated.zip"}, {name: "malformed.zip"}, {name: "multi.zip"}, {name: "zip64.zip"},
		{name: "mixed.zip", extra: []string{"--max-central-directory-bytes", "10"}},
		{name: "mixed.zip", extra: []string{"--max-entries", "2"}},
		{name: "mixed.zip", extra: []string{"--max-input-bytes", "4"}},
		{name: "mixed.zip", extra: []string{"--max-field-bytes", "3"}},
		{name: "mixed.zip", extra: []string{"--max-report-bytes", "100"}},
		{name: "mixed.zip", extra: []string{"--max-report-bytes", "0"}},
		{name: "mixed.zip", extra: []string{"--max-entries", "-3"}},
	}
}

func zipStoredCases(paths map[string]string) []cmdCase {
	var cases []cmdCase
	for name := range paths {
		cases = append(cases, cmdCase{name: name})
	}
	sort.Slice(cases, func(i, j int) bool { return cases[i].name < cases[j].name })
	for _, c := range [][]string{
		{"--max-input-bytes", "4"}, {"--max-entries", "1"}, {"--max-path-bytes", "3"}, {"--max-depth", "1"}, {"--max-entry-bytes", "4"},
		{"--max-total-bytes", "6"}, {"--max-report-bytes", "100"}, {"--max-metadata-bytes", "10"}, {"--max-depth", "0"},
	} {
		cases = append(cases, cmdCase{name: "good.zip", extra: c})
	}
	// nested/ holds a four-component path: the depth cap is inclusive.
	cases = append(cases, cmdCase{name: "nested.zip", extra: []string{"--max-depth", "4"}}, cmdCase{name: "nested.zip", extra: []string{"--max-depth", "3"}})
	return cases
}

func (c cmdCase) label() string { return c.name + " " + strings.Join(c.extra, " ") }

// goCmdCase runs one case through the Go command and returns what it produced and the output directory.
func goCmdCase(t testing.TB, kind string, paths map[string]string, c cmdCase, work, inDir string, i int) (zipCmdGold, string) {
	t.Helper()
	mo := filepath.Join(work, "go-"+itoa(i))
	var code int
	var gout, gerr string
	if kind == "meta" {
		code, gout, gerr = runGo(t, ZipMetadata, work, metaArgs(t, paths[c.name], mo, c.extra...)...)
	} else {
		code, gout, gerr = runGo(t, ZipStored, work, storedArgs(t, paths[c.name], mo, c.extra...)...)
	}
	if gout != "" {
		t.Errorf("%s: stdout must stay empty, got %q", c.label(), gout)
	}
	g := zipCmdGold{Label: c.label(), Code: code}
	if code != 0 {
		g.Stderr = strings.ReplaceAll(gerr, inDir, "<in>")
		assertNoLeftovers(t, work, "go-"+itoa(i))
		return g, mo
	}
	g.Tree = treeGold(t, mo, inDir)
	g.Facts = manifestFacts(t, mo, inDir)
	return g, mo
}

func replayCommandGolden(t *testing.T, kind, golden string, fixtures func() map[string][]byte, cases func(map[string]string) []cmdCase) {
	want := loadZipGolden[zipCmdGold](t, golden)
	work, in := t.TempDir(), t.TempDir()
	paths := writeFixtures(t, in, fixtures())
	cs := cases(paths)
	if len(want) != len(cs) {
		t.Fatalf("golden holds %d cases, the corpus builds %d", len(want), len(cs))
	}
	var accepted atomic.Int32
	t.Run("cases", func(t *testing.T) {
		for i, c := range cs {
			i, c := i, c
			t.Run(c.label(), func(t *testing.T) {
				t.Parallel()
				w := want[i]
				if w.Label != c.label() {
					t.Fatalf("golden case order drifted: %q vs %q", w.Label, c.label())
				}
				got, mo := goCmdCase(t, kind, paths, c, work, in, i)
				if got.Code != w.Code {
					t.Errorf("%s: golden exit %d (%s), Go exit %d (%s)", w.Label, w.Code, strings.TrimSpace(w.Stderr), got.Code, strings.TrimSpace(got.Stderr))
					return
				}
				if w.Code != 0 {
					// A legacy rejection that surfaced through the manifest tool names a subprocess; compare the others.
					if !strings.Contains(w.Stderr, "Command '[") && w.Stderr != got.Stderr {
						t.Errorf("%s: stderr differs\n golden: %q\n Go:     %q", w.Label, w.Stderr, got.Stderr)
					}
					return
				}
				accepted.Add(1)
				if !reflect.DeepEqual(w.Tree, got.Tree) {
					t.Errorf("%s: published tree differs\n golden: %+v\n Go:     %+v", w.Label, w.Tree, got.Tree)
				}
				for _, k := range manifestFactKeys {
					if w.Facts[k] != got.Facts[k] {
						t.Errorf("%s: manifest field %q differs\n golden: %s\n Go:     %s", w.Label, k, w.Facts[k], got.Facts[k])
					}
				}
				checkRunStamp(t, mo)
				verifyInProcess(t, mo)
			})
		}
	})
	if accepted.Load() < 5 {
		t.Fatalf("only %d archives were accepted; the comparison proves nothing", accepted.Load())
	}
}

func TestZipMetadataCommandGolden(t *testing.T) {
	replayCommandGolden(t, "meta", "meta_cmd", metaFixtures, zipMetaCases)
}

func TestZipStoredCommandGolden(t *testing.T) {
	replayCommandGolden(t, "stored", "stored_cmd", storedFixtures, zipStoredCases)
}
