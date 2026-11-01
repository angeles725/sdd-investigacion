package niagara

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// evidence runs bog-nav on input and returns the exit code, stderr and the decoded evidence (nil when no file
// was written).
func evidence(t *testing.T, input string) (code int, stderr string, doc map[string]any, outPath string) {
	t.Helper()
	outPath = filepath.Join(t.TempDir(), "out.json")
	code, stdout, stderr := run("--input", input, "--output", outPath)
	if stdout != "" {
		t.Errorf("stdout = %q, want empty: the evidence goes to --output", stdout)
	}
	raw, err := os.ReadFile(outPath)
	if err != nil {
		return code, stderr, nil, outPath
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, raw)
	}
	return code, stderr, doc, outPath
}

func suite(t *testing.T) map[string]string {
	t.Helper()
	fx, err := bogtest.Suite(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return fx
}

func get(t *testing.T, doc map[string]any, keys ...string) any {
	t.Helper()
	var cur any = doc
	for _, k := range keys {
		m, ok := cur.(map[string]any)
		if !ok {
			t.Fatalf("%v: %v is not an object", keys, cur)
		}
		cur = m[k]
	}
	return cur
}

func paths(t *testing.T, doc map[string]any) map[string]map[string]any {
	t.Helper()
	out := map[string]map[string]any{}
	for _, c := range doc["components"].([]any) {
		m := c.(map[string]any)
		out[m["path"].(string)] = m
	}
	return out
}

// T1: absent input exits 2 and writes nothing.
func TestAbsentInputExits2WithoutOutput(t *testing.T) {
	dir := t.TempDir()
	code, stdout, stderr := run("--input", filepath.Join(dir, "no-such-file.bog"), "--output", filepath.Join(dir, "o.json"))
	if code != 2 || stdout != "" || !strings.HasSuffix(stderr, "no-such-file.bog: No such file or directory\n") {
		t.Errorf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if _, err := os.Stat(filepath.Join(dir, "o.json")); err == nil {
		t.Error("an output file was created for an absent input")
	}
}

// T2: a symlink input is refused (O_NOFOLLOW).
func TestSymlinkInputRefused(t *testing.T) {
	fx := suite(t)
	link := filepath.Join(t.TempDir(), "sym.bog")
	if err := os.Symlink(fx["valid.bog"], link); err != nil {
		t.Fatal(err)
	}
	code, stderr, doc, _ := evidence(t, link)
	if code != 2 || doc != nil || !strings.HasSuffix(stderr, "sym.bog: is a symbolic link (rejected)\n") {
		t.Errorf("code=%d doc=%v stderr=%q", code, doc, stderr)
	}
}

// T3: a valid ZIP bog is complete, counted, and never leaks a slot value.
func TestValidZipBog(t *testing.T) {
	fx := suite(t)
	code, stderr, doc, outPath := evidence(t, fx["valid.bog"])
	if code != 0 || stderr != "" {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	if doc["schema"] != "bog-nav.v1" || doc["status"] != "complete" || get(t, doc, "input", "format") != "zip-xml" {
		t.Errorf("schema/status/format = %v %v %v", doc["schema"], doc["status"], get(t, doc, "input", "format"))
	}
	if get(t, doc, "summary", "components") != 3.0 || get(t, doc, "summary", "links") != 1.0 {
		t.Errorf("summary = %v", doc["summary"])
	}
	if _, ok := get(t, doc, "summary", "prefixes").(map[string]any)["b"]; !ok {
		t.Errorf("prefix b missing: %v", doc["summary"])
	}
	raw, _ := os.ReadFile(outPath)
	if strings.Contains(string(raw), "PLAINSECRET") {
		t.Error("a secret slot value appears in the emitted JSON")
	}
	if fi, err := os.Stat(outPath); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("output mode = %v, %v; want 0600", fi.Mode().Perm(), err)
	}
}

// T4: bare XML.
func TestPlaintextBog(t *testing.T) {
	fx := suite(t)
	code, _, doc, _ := evidence(t, fx["plaintext.bog"])
	if code != 0 || doc["status"] != "complete" || get(t, doc, "input", "format") != "plaintext-xml" || get(t, doc, "summary", "components") != 3.0 {
		t.Errorf("code=%d doc=%v", code, doc)
	}
}

// T5: an empty graph is complete with zero components, and proves the instrument looked.
func TestEmptyBogIsCompleteNotAbsent(t *testing.T) {
	fx := suite(t)
	code, _, doc, _ := evidence(t, fx["empty.bog"])
	if code != 0 || doc["status"] != "complete" || doc["schema"] != "bog-nav.v1" ||
		get(t, doc, "summary", "components") != 0.0 || get(t, doc, "summary", "links") != 0.0 {
		t.Errorf("code=%d doc=%v", code, doc)
	}
}

// T6: neither ZIP nor XML is a failed evidence document, exit 1.
func TestBinaryBogFails(t *testing.T) {
	fx := suite(t)
	code, _, doc, _ := evidence(t, fx["binary.bog"])
	if code != 1 || doc["status"] != "failed" || len(doc["errors"].([]any)) == 0 || get(t, doc, "input", "format") != "unknown" {
		t.Errorf("code=%d doc=%v", code, doc)
	}
}

// T7: a symlink at --output is refused and its target is untouched.
func TestOutputSymlinkRefused(t *testing.T) {
	fx := suite(t)
	dir := t.TempDir()
	victim := filepath.Join(dir, "victim.txt")
	if err := os.WriteFile(victim, []byte("victim-content\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "out_sym.json")
	if err := os.Symlink(victim, link); err != nil {
		t.Fatal(err)
	}
	code, _, stderr := run("--input", fx["valid.bog"], "--output", link)
	got, _ := os.ReadFile(victim)
	if code != 2 || string(got) != "victim-content\n" || !strings.Contains(stderr, "output "+link+": File exists") {
		t.Errorf("code=%d victim=%q stderr=%q", code, got, stderr)
	}
}

// T8: an existing output is never overwritten.
func TestExistingOutputRefused(t *testing.T) {
	fx := suite(t)
	pre := filepath.Join(t.TempDir(), "pre_existing.json")
	if err := os.WriteFile(pre, []byte("existing\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	code, _, _ := run("--input", fx["valid.bog"], "--output", pre)
	got, _ := os.ReadFile(pre)
	if code != 2 || string(got) != "existing\n" {
		t.Errorf("code=%d content=%q", code, got)
	}
}

func TestOutputInMissingDirectoryExits2(t *testing.T) {
	fx := suite(t)
	code, _, stderr := run("--input", fx["valid.bog"], "--output", filepath.Join(t.TempDir(), "no", "such", "o.json"))
	if code != 2 || !strings.HasSuffix(stderr, "No such file or directory\n") || !strings.Contains(stderr, "bog-nav: output ") {
		t.Errorf("code=%d stderr=%q", code, stderr)
	}
}

// T9: value assertions on the known tree and link resolution.
func TestValidBogValues(t *testing.T) {
	fx := suite(t)
	_, _, doc, _ := evidence(t, fx["valid.bog"])
	comps := paths(t, doc)
	for _, p := range []string{"Station", "Station/Services", "Station/Logic"} {
		if _, ok := comps[p]; !ok {
			t.Errorf("component %q missing; have %v", p, comps)
		}
	}
	if comps["Station"]["type"] != "b:Station" || comps["Station"]["module"] != "baja" || comps["Station/Logic"]["module"] != "control" {
		t.Errorf("Station = %v, Logic = %v", comps["Station"], comps["Station/Logic"])
	}
	links := doc["links"].([]any)
	if len(links) != 1 {
		t.Fatalf("links = %v", links)
	}
	lk := links[0].(map[string]any)
	if lk["src_resolved"] != true || lk["source"] != "Station/Services.out" || lk["target"] != "Station/Logic.in10" || lk["link_name"] != "Link" {
		t.Errorf("link = %v", lk)
	}
}

// T10: the input hash is the sha256 of the file and the size its length.
func TestInputMetadata(t *testing.T) {
	fx := suite(t)
	_, _, doc, _ := evidence(t, fx["valid.bog"])
	b, _ := os.ReadFile(fx["valid.bog"])
	sum := sha256.Sum256(b)
	if get(t, doc, "input", "sha256") != hex.EncodeToString(sum[:]) || get(t, doc, "input", "size_bytes") != float64(len(b)) {
		t.Errorf("input = %v, want sha %x size %d", doc["input"], sum, len(b))
	}
}

// T11: a member that inflates past 32 MiB fails with truncated:true; the read is length-bounded.
func TestZipBombIsBounded(t *testing.T) {
	if testing.Short() {
		t.Skip("builds a 32 MiB member")
	}
	fx := suite(t)
	code, _, doc, _ := evidence(t, fx["bomb.bog"])
	if code != 1 || doc["status"] != "failed" || doc["truncated"] != true || len(doc["errors"].([]any)) == 0 {
		t.Errorf("code=%d status=%v truncated=%v errors=%v", code, doc["status"], doc["truncated"], doc["errors"])
	}
}

// T12-T15: every entry-level read failure is a typed failed document, never a crash without JSON.
func TestCorruptZipEntriesAreTypedFailures(t *testing.T) {
	fx := suite(t)
	tests := []struct{ name, fixture, msg string }{
		{"T12 corrupt deflate", "corrupt_deflate.bog", "ZIP entry read error: Error -3 while decompressing data: "},
		{"T13 CRC mismatch", "crc_mismatch.bog", "ZIP entry read error: Bad CRC-32 for file 'file.xml'"},
		{"T14 encrypted entry", "encrypted.bog", "ZIP entry read error: File 'file.xml' is encrypted, password required for extraction"},
		{"T15 unsupported method", "method99.bog", "ZIP entry read error: That compression method is not supported"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, _, doc, _ := evidence(t, fx[tt.fixture])
			if code != 1 || doc == nil || doc["status"] != "failed" || get(t, doc, "input", "format") != "zip-xml" {
				t.Fatalf("code=%d doc=%v", code, doc)
			}
			errs := doc["errors"].([]any)
			if len(errs) != 1 || !strings.HasPrefix(errs[0].(string), tt.msg) {
				t.Errorf("errors = %v, want prefix %q", errs, tt.msg)
			}
			if doc["truncated"] != false || get(t, doc, "summary", "components") != 0.0 {
				t.Errorf("truncated=%v summary=%v", doc["truncated"], doc["summary"])
			}
		})
	}
}

// T16: self-closing components with a handle are recorded.
func TestSelfClosingComponentsRecorded(t *testing.T) {
	fx := suite(t)
	code, _, doc, _ := evidence(t, fx["self_closing_mix.bog"])
	if code != 0 || get(t, doc, "summary", "components") != 7.0 {
		t.Fatalf("code=%d summary=%v", code, doc["summary"])
	}
	comps := paths(t, doc)
	for _, p := range []string{"Station/A/Leaf1", "Station/A/Leaf2", "Station/A/Container2/Leaf3", "Station/B"} {
		if _, ok := comps[p]; !ok {
			t.Errorf("%q missing; have %v", p, comps)
		}
	}
}

// T17: </a> must pop the action frame so later siblings keep their path.
func TestActionElementStackBalance(t *testing.T) {
	fx := suite(t)
	_, _, doc, _ := evidence(t, fx["nested_a.bog"])
	comps := paths(t, doc)
	if _, ok := comps["Station/B"]; !ok {
		t.Errorf("Station/B missing; have %v", comps)
	}
	if _, ok := comps["B"]; ok {
		t.Error("orphaned path B: the stack lost the Station frame")
	}
}

// T18: a FIFO input is refused without blocking.
func TestFifoInputDoesNotHang(t *testing.T) {
	fifo := filepath.Join(t.TempDir(), "input.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan int, 1)
	var stderr string
	go func() {
		code, _, e := run("--input", fifo, "--output", filepath.Join(t.TempDir(), "o.json"))
		stderr = e
		done <- code
	}()
	select {
	case code := <-done:
		if code != 2 || !strings.HasSuffix(stderr, "not a regular file (rejected)\n") {
			t.Errorf("code=%d stderr=%q", code, stderr)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("bog-nav hung on a FIFO without a writer")
	}
}

func TestDirectoryInputRefused(t *testing.T) {
	dir := t.TempDir()
	code, _, stderr := run("--input", dir, "--output", filepath.Join(t.TempDir(), "o.json"))
	if code != 2 || !strings.HasSuffix(stderr, dir+": not a regular file (rejected)\n") {
		t.Errorf("code=%d stderr=%q", code, stderr)
	}
}

// The caps are visible: truncation keeps status complete and exit 0 but flags it (the anti-silent-zero rule).
func TestComponentCapTruncatesVisibly(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("<root>\n")
	for i := 0; i < maxComponents+1; i++ {
		fmt.Fprintf(&sb, "<p n='c%06d' h='%d' t='b:X'/>\n", i, i)
	}
	p := filepath.Join(t.TempDir(), "big.bog")
	if err := os.WriteFile(p, []byte(sb.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	code, _, doc, _ := evidence(t, p)
	errs := doc["errors"].([]any)
	if code != 0 || doc["status"] != "complete" || doc["truncated"] != true ||
		len(errs) != 1 || errs[0] != "component list truncated at 50000 entries" ||
		get(t, doc, "summary", "components") != float64(maxComponents) {
		t.Errorf("code=%d status=%v truncated=%v errors=%v components=%v", code, doc["status"], doc["truncated"], errs, get(t, doc, "summary", "components"))
	}
	last := doc["components"].([]any)[maxComponents-1].(map[string]any)["path"]
	if last != fmt.Sprintf("c%06d", maxComponents-1) {
		t.Errorf("the cap must keep the first %d paths in sorted order, last kept = %v", maxComponents, last)
	}
}

func TestLinkCapTruncatesVisibly(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("<p n='C' h='1' t='b:X'>\n")
	for i := 0; i < maxLinks+1; i++ {
		fmt.Fprintf(&sb, "<p n='L%d' t='b:Link'>\n<p n='sourceOrd' v='h:1'/>\n</p>\n", i)
	}
	sb.WriteString("</p>\n")
	p := filepath.Join(t.TempDir(), "links.bog")
	if err := os.WriteFile(p, []byte(sb.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	code, _, doc, _ := evidence(t, p)
	errs := doc["errors"].([]any)
	if code != 0 || doc["status"] != "complete" || doc["truncated"] != true ||
		len(errs) != 1 || errs[0] != "link list truncated at 20000 entries" || get(t, doc, "summary", "links") != float64(maxLinks) {
		t.Errorf("code=%d status=%v truncated=%v errors=%v links=%v", code, doc["status"], doc["truncated"], errs, get(t, doc, "summary", "links"))
	}
}

func TestLinkRowPlaceholders(t *testing.T) {
	const xml = `<p n='C' h='1' t='b:X'>
<p n='NoSlots' t='b:Link'>
<p n='sourceOrd' v='h:99'/>
</p>
<p n='NoSource' t='b:Link'>
<p n='sourceSlotName' v='out'/>
</p>
<p n='EmptyHandle' t='b:Link'>
<p n='sourceOrd' v='h:'/>
</p>
</p>`
	p := filepath.Join(t.TempDir(), "links.bog")
	if err := os.WriteFile(p, []byte(xml), 0o600); err != nil {
		t.Fatal(err)
	}
	_, _, doc, _ := evidence(t, p)
	want := []map[string]any{
		{"link_name": "NoSlots", "source": "h:99.None", "src_resolved": false, "target": "C.None"},
		{"link_name": "NoSource", "source": "?.out", "src_resolved": false, "target": "C.None"},
		{"link_name": "EmptyHandle", "source": "?.None", "src_resolved": false, "target": "C.None"},
	}
	got := doc["links"].([]any)
	if len(got) != len(want) {
		t.Fatalf("links = %v", got)
	}
	for i, w := range want {
		row := got[i].(map[string]any)
		for k, v := range w {
			if row[k] != v {
				t.Errorf("link %d field %s = %v, want %v", i, k, row[k], v)
			}
		}
	}
}

func TestComponentsAreSortedByPathStably(t *testing.T) {
	const xml = "<p n='b' h='1' t='x:A'/>\n<p n='a' h='2' t='x:A'/>\n<p n='b' h='3' t='x:B'/>\n<p n='Z' h='4' t='x:A'/>"
	p := filepath.Join(t.TempDir(), "sort.bog")
	if err := os.WriteFile(p, []byte(xml), 0o600); err != nil {
		t.Fatal(err)
	}
	_, _, doc, _ := evidence(t, p)
	var got []string
	for _, c := range doc["components"].([]any) {
		m := c.(map[string]any)
		got = append(got, m["path"].(string)+"#"+m["handle"].(string))
	}
	want := "Z#4,a#2,b#1,b#3"
	if strings.Join(got, ",") != want {
		t.Errorf("order = %v, want %s (code-point order, equal paths in handle-map order)", got, want)
	}
}

// The evidence for a plaintext bog is byte-identical to what the legacy Python wrote for the same bytes. The
// golden files were produced by the frozen bog_nav.py (testdata/legacy) and are re-derived by the differential
// test, so they cannot drift from the oracle.
func TestGoldenEvidenceMatchesLegacyBytes(t *testing.T) {
	for _, name := range []string{"plaintext", "edge"} {
		t.Run(name, func(t *testing.T) {
			input := filepath.Join(t.TempDir(), name+".bog")
			src, err := os.ReadFile(filepath.Join("testdata", "golden", name+".bog"))
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(input, src, 0o600); err != nil {
				t.Fatal(err)
			}
			out := filepath.Join(t.TempDir(), "o.json")
			code, _, _ := run("--input", input, "--output", out)
			got, _ := os.ReadFile(out)
			want, err := os.ReadFile(filepath.Join("testdata", "golden", name+".json"))
			if err != nil {
				t.Fatal(err)
			}
			if code != 0 || string(got) != string(want) {
				t.Errorf("code=%d\n got:\n%s\nwant:\n%s", code, got, want)
			}
		})
	}
}

// Equal paths must keep handle-map order however many there are: a non-stable sort reorders a long run of
// equal keys (small inputs are insertion-sorted and would hide it).
func TestEqualPathsKeepHandleOrderAtScale(t *testing.T) {
	var sb strings.Builder
	var want []string
	for i := 0; i < 200; i++ {
		fmt.Fprintf(&sb, "<p n='same' h='%d' t='x:T'/>\n<p n='other%d' h='x%d' t='x:T'/>\n", i, i%3, i)
		want = append(want, fmt.Sprint(i))
	}
	p := filepath.Join(t.TempDir(), "stable.bog")
	if err := os.WriteFile(p, []byte(sb.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	_, _, doc, _ := evidence(t, p)
	var got []string
	for _, c := range doc["components"].([]any) {
		m := c.(map[string]any)
		if m["path"] == "same" {
			got = append(got, m["handle"].(string))
		}
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("components with an equal path were reordered: %v", got)
	}
}

// A list exactly at its cap is complete, not truncated: the boundary is inclusive.
func TestCapsAreInclusive(t *testing.T) {
	var comps strings.Builder
	for i := 0; i < maxComponents; i++ {
		fmt.Fprintf(&comps, "<p n='c%06d' h='%d' t='b:X'/>\n", i, i)
	}
	var links strings.Builder
	links.WriteString("<p n='C' h='1' t='b:X'>\n")
	for i := 0; i < maxLinks; i++ {
		fmt.Fprintf(&links, "<p n='L%d' t='b:Link'>\n<p n='sourceOrd' v='h:1'/>\n</p>\n", i)
	}
	for name, xml := range map[string]string{"components": comps.String(), "links": links.String()} {
		p := filepath.Join(t.TempDir(), name+".bog")
		if err := os.WriteFile(p, []byte(xml), 0o600); err != nil {
			t.Fatal(err)
		}
		code, _, doc, _ := evidence(t, p)
		if code != 0 || doc["truncated"] != false || len(doc["errors"].([]any)) != 0 {
			t.Errorf("%s at exactly the cap: code=%d truncated=%v errors=%v", name, code, doc["truncated"], doc["errors"])
		}
	}
}
