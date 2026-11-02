//go:build !noparity

package classfile

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Differential tests against the frozen Python helper (java/testdata/legacy/corroborate_java.py classfile-facts). Every input of the
// unit tests, plus a seeded fuzz corpus of damaged archives and class files, is run through both the helper
// and Run, and the exit code, stdout and (when the helper warned about its environment) stderr must agree.
// The helper is imported once per interpreter and driven in-process, so a batch costs one Python start; a few
// inputs are also run through the real command line to prove the driver is faithful.
//
// Interpreters: python3.12 (the one CI runs) and python3 when they differ; RSDD_CLASSFACTS_PYTHONS overrides
// with a colon-separated list. Inputs listed in divergentOn313 are version-dependent behaviours of Python's
// zipfile (strictness of is_zipfile, the order of equal offsets) and are only compared on interpreters older
// than 3.13, where the Go port follows the 3.12 semantics.

// helperPath is the frozen copy of the legacy helper (corroborate_java.py was retired when rsdd corroborate java
// replaced it); the oracle is no longer the live toolbelt script.
const helperPath = "../java/testdata/legacy/corroborate_java.py"

const driver = `
import base64, contextlib, io, json, os, sys
toolbelt, spec = sys.argv[1], sys.argv[2]
sys.path.insert(0, toolbelt)
import corroborate_java as cj
cases = json.load(open(spec))
import zipfile

def same_rule(path):
    """False when this interpreter's is_zipfile disagrees with the 3.12 rule the port follows (an end record exists)."""
    try:
        with open(path, "rb") as fp:
            legacy = bool(zipfile._EndRecData(fp))
    except (OSError, zipfile.BadZipFile):
        legacy = False
    return legacy == zipfile.is_zipfile(path)

results = []
for c in cases:
    for k in [k for k in os.environb if k.startswith(b"RSDD_CLASSFACTS_")]:
        del os.environb[k]
    for k, v in c["env"].items():
        os.environb[k.encode()] = base64.b64decode(v)
    cj._WARNED.clear()
    out, err = io.StringIO(), io.StringIO()
    crash = ""
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cj.main(["classfile-facts", c["path"]])
    except BaseException as exc:
        rc, crash = 1, type(exc).__name__
    results.append({"out": out.getvalue(), "err": err.getvalue(), "rc": rc, "crash": crash, "same_archive_rule": same_rule(c["path"])})
json.dump(results, open(spec + ".out", "w"))
print(sys.version_info[0], sys.version_info[1])
`

type pcase struct {
	name  string
	input []byte
	env   env
}

var envRaws = []string{"abc", "0", "00", "-1", "+5", " 5", "5 ", "5\n", "1.5", "0x10", "1_000", "\U00000663", "it's", `a"b`, `it's "x"`,
	"tab\there", "cr\rhere", `back\slash`, "\x01\x7f", "\xff", "caf\xc3\xa9", "\xc2\xa0", "\U0000200b", "\U0001f600", "\U000e0001", "7", "007", "123456789012345678901234567890",
	"18446744073709551615", "18446744073709551616", "\xed\xa0\x80", "a\U00002028b", "\x80abc\xfe", "\U0000feff", "\U00000378", "\U00010000"}

func parityCases() []pcase {
	var out []pcase
	for _, c := range lineCases() {
		out = append(out, pcase{"line/" + c.name, c.input, c.env})
	}
	for _, c := range eocdCases() {
		out = append(out, pcase{"eocd/" + c.name, c.input, nil})
	}
	for _, c := range nameCases() {
		out = append(out, pcase{"names/" + c.name, buildZip(c.entries, zopts{}), nil})
	}
	for _, c := range readCases() {
		out = append(out, pcase{"read/" + c.name, buildZip(append([]zent{c.target}, c.filler...), c.opts), nil})
	}
	for _, raw := range envRaws {
		out = append(out, pcase{"env/" + fmt.Sprintf("%q", raw), buildZip(twoClasses(), zopts{}), env{envMaxEntries: raw, envMaxExpanded: raw, envMaxClass: raw}})
	}
	n := len(c65)
	for _, c := range []struct {
		name string
		tail []byte
		back int
		mut  func(e *zent)
	}{
		{"stored covered", c65, n, func(e *zent) { e.csize, e.usize, e.crc = uint32(n)+100, uint32(n), crc32.ChecksumIEEE(c65) }},
		{"stored not covered", c65, n, func(e *zent) { e.csize, e.usize, e.crc = uint32(n)+100, uint32(n)+1, crc32.ChecksumIEEE(c65) }},
		{"stored last byte", c65, 1, func(e *zent) { e.csize, e.usize, e.crc = 1, 1, crc32.ChecksumIEEE(c65[n-1:]) }},
		{"stored at the end, one byte declared", c65, 0, func(e *zent) { e.csize, e.usize, e.crc = 1, 0, 0 }},
		{"stored at the end, nothing declared", c65, 0, func(e *zent) { e.csize, e.usize, e.crc = 0, 0, 0 }},
		{"deflated covered", storedBlock(c65), n + 5, func(e *zent) {
			e.method, e.csize, e.usize, e.crc = 8, uint32(n)+500, uint32(n), crc32.ChecksumIEEE(c65)
		}},
		{"deflated short", storedBlock(c65), n + 5, func(e *zent) {
			e.method, e.csize, e.usize, e.crc = 8, uint32(n)+500, uint32(n)+1, crc32.ChecksumIEEE(c65)
		}},
		{"deflated prefix", storedBlock(c65), n + 5, func(e *zent) {
			e.method, e.csize, e.usize, e.crc = 8, uint32(n)+500, 10, crc32.ChecksumIEEE(c65[:10])
		}},
		{"deflated whole stream read", storedBlock(c65), n + 5, func(e *zent) {
			e.method, e.csize, e.usize, e.crc = 8, uint32(n)+5, uint32(n)+1, crc32.ChecksumIEEE(c65)
		}},
	} {
		out = append(out, pcase{"tail/" + c.name, atTail(c.tail, c.back, c.mut), nil})
	}
	dup := twoClasses()
	dup[1].hoffAdd = -(30 + len(dup[0].name) + len(dup[0].comp))
	out = append(out, pcase{"read/two entries at one offset", buildZip(dup, zopts{}), nil})
	return append(append(out, fuzzCases()...), fieldFuzzCases()...)
}

// fieldFuzzCases damages one header field at a time, with the values that tend to break readers: zero, one,
// all ones, the original plus or minus one, and a random value.
func fieldFuzzCases() []pcase {
	rng := rand.New(rand.NewSource(77))
	big := buildClass(classOpts{major: 61, lvt: true, extraPool: [][]byte{utf8Const(strings.Repeat("abcdefgh0123", 900))}})
	bases := [][]byte{
		buildZip(twoClasses(), zopts{}),
		buildZip(append(twoClasses(), ent("q/Big.class", big, 8), ent("q/Stored.class", big[:300], 0)), zopts{comment: []byte("hi")}),
		buildZip(twoClasses(), zopts{zip64: true}),
	}
	type field struct {
		sig  string
		off  int
		size int
	}
	fields := []field{{"PK\x01\x02", 6, 1}, {"PK\x01\x02", 8, 2}, {"PK\x01\x02", 10, 2}, {"PK\x01\x02", 16, 4}, {"PK\x01\x02", 20, 4}, {"PK\x01\x02", 24, 4},
		{"PK\x01\x02", 28, 2}, {"PK\x01\x02", 30, 2}, {"PK\x01\x02", 32, 2}, {"PK\x01\x02", 42, 4},
		{"PK\x03\x04", 6, 2}, {"PK\x03\x04", 8, 2}, {"PK\x03\x04", 14, 4}, {"PK\x03\x04", 18, 4}, {"PK\x03\x04", 22, 4}, {"PK\x03\x04", 26, 2}, {"PK\x03\x04", 28, 2},
		{"PK\x05\x06", 8, 2}, {"PK\x05\x06", 10, 2}, {"PK\x05\x06", 12, 4}, {"PK\x05\x06", 16, 4}, {"PK\x05\x06", 20, 2},
		{"PK\x06\x07", 4, 4}, {"PK\x06\x07", 8, 8}, {"PK\x06\x07", 16, 4}, {"PK\x06\x06", 4, 8}, {"PK\x06\x06", 40, 8}, {"PK\x06\x06", 48, 8}}
	var out []pcase
	for i := 0; i < 1800; i++ {
		b := append([]byte(nil), bases[rng.Intn(len(bases))]...)
		f := fields[rng.Intn(len(fields))]
		// Pick one occurrence of the signature.
		var at []int
		for from := 0; ; {
			i := bytes.Index(b[from:], []byte(f.sig))
			if i < 0 {
				break
			}
			at = append(at, from+i)
			from += i + 1
		}
		if len(at) == 0 || at[0]+f.off+f.size > len(b) {
			continue
		}
		pos := at[rng.Intn(len(at))] + f.off
		if pos+f.size > len(b) {
			continue
		}
		var orig uint64
		for k := f.size - 1; k >= 0; k-- {
			orig = orig<<8 | uint64(b[pos+k])
		}
		var v uint64
		switch rng.Intn(6) {
		case 0:
			v = 0
		case 1:
			v = 1
		case 2:
			v = ^uint64(0)
		case 3:
			v = orig + 1
		case 4:
			v = orig - 1
		default:
			v = rng.Uint64()
		}
		for k := 0; k < f.size; k++ {
			b[pos+k] = byte(v >> (8 * k))
		}
		out = append(out, pcase{fmt.Sprintf("field/%04d-%s+%d=%#x", i, fmt.Sprintf("%x", f.sig[2:]), f.off, v), b, nil})
	}
	return out
}

func fuzzCases() []pcase {
	rng := rand.New(rand.NewSource(20260501))
	bases := map[string][]byte{
		"jar":       buildZip(twoClasses(), zopts{}),
		"jar64":     buildZip(twoClasses(), zopts{zip64: true, prepend: []byte("prefix")}),
		"jarcomm":   buildZip(append(twoClasses(), ent("p/data.txt", []byte("hello hello hello"), 8), ent("q/Z.class", c52[:len(c52)-5], 0)), zopts{comment: []byte("a comment")}),
		"class":     c52,
		"class-big": buildClass(classOpts{major: 61, lvt: true, extraPool: [][]byte{{5, 1, 2, 3, 4, 5, 6, 7, 8}, utf8Const("hello world")}, poolSlots: 1, ifaces: 2}),
	}
	names := []string{"jar", "jar64", "jarcomm", "class", "class-big"}
	var out []pcase
	for i := 0; i < 700; i++ {
		kind := names[rng.Intn(len(names))]
		b := append([]byte(nil), bases[kind]...)
		switch op := rng.Intn(5); op {
		case 0, 1: // flip 1-3 bytes
			for n := 1 + rng.Intn(3); n > 0; n-- {
				b[rng.Intn(len(b))] ^= byte(1 + rng.Intn(255))
			}
		case 2: // truncate
			b = b[:rng.Intn(len(b))]
		case 3: // zero a range
			from := rng.Intn(len(b))
			for j := from; j < len(b) && j < from+1+rng.Intn(12); j++ {
				b[j] = 0
			}
		case 4: // set a byte to an extreme value
			b[rng.Intn(len(b))] = []byte{0, 0xff, 0x7f, 0x80}[rng.Intn(4)]
		}
		out = append(out, pcase{fmt.Sprintf("fuzz/%03d-%s", i, kind), b, nil})
	}
	return out
}

// divergentOn313 names inputs whose Python result depends on the interpreter's zipfile version.
func divergentOn313(name string) bool {
	return strings.Contains(name, "two entries at one offset") || strings.Contains(name, "65536 trailing bytes")
}

type pyResult struct {
	Out   string `json:"out"`
	Err   string `json:"err"`
	Rc    int    `json:"rc"`
	Crash string `json:"crash"`
	Same  bool   `json:"same_archive_rule"`
}

func pythons(t *testing.T) []string {
	var found []string
	list := []string{"python3.12", "python3"}
	if v := os.Getenv("RSDD_CLASSFACTS_PYTHONS"); v != "" {
		list = strings.Split(v, ":")
	}
	seen := map[string]bool{}
	for _, name := range list {
		p, err := exec.LookPath(name)
		if err != nil {
			continue
		}
		if seen[p] {
			continue
		}
		seen[p] = true
		found = append(found, p)
	}
	if len(found) == 0 {
		if os.Getenv("RSDD_PARITY_REQUIRE") == "1" {
			t.Fatal("no python3 on PATH and RSDD_PARITY_REQUIRE=1")
		}
		t.Skip("no python3 on PATH: the differential tests need the legacy helper's interpreter")
	}
	return found
}

func TestParityWithPythonHelper(t *testing.T) {
	cases := parityCases()
	dir := t.TempDir()
	spec := make([]map[string]any, len(cases))
	paths := make([]string, len(cases))
	for i, c := range cases {
		paths[i] = filepath.Join(dir, fmt.Sprintf("in-%04d.bin", i))
		if err := os.WriteFile(paths[i], c.input, 0o644); err != nil {
			t.Fatal(err)
		}
		e := map[string]string{}
		for k, v := range c.env {
			e[k] = base64.StdEncoding.EncodeToString([]byte(v))
		}
		spec[i] = map[string]any{"path": paths[i], "env": e}
	}
	specJSON, _ := json.Marshal(spec)
	toolbelt := filepath.Dir(stagedHelper(t))
	driverPath := filepath.Join(dir, "driver.py")
	if err := os.WriteFile(driverPath, []byte(driver), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, py := range pythons(t) {
		t.Run(filepath.Base(py), func(t *testing.T) {
			specPath := filepath.Join(dir, filepath.Base(py)+".json")
			if err := os.WriteFile(specPath, specJSON, 0o644); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(py, "-I", "-B", driverPath, toolbelt, specPath)
			ver, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("driver: %v\n%s", err, ver)
			}
			var major, minor int
			fmt.Sscanf(strings.TrimSpace(string(ver[bytes.LastIndexByte(bytes.TrimSpace(ver), '\n')+1:])), "%d %d", &major, &minor)
			raw, err := os.ReadFile(specPath + ".out")
			if err != nil {
				t.Fatal(err)
			}
			var results []pyResult
			if err := json.Unmarshal(raw, &results); err != nil || len(results) != len(cases) {
				t.Fatalf("driver output: %v (%d results for %d cases)", err, len(results), len(cases))
			}
			t.Logf("python %d.%d: %d inputs", major, minor, len(cases))
			compared, bad, skipped := 0, 0, 0
			for i, c := range cases {
				newer := major > 3 || minor >= 13
				if newer && (divergentOn313(c.name) || !results[i].Same) {
					skipped++
					continue
				}
				if !newer && !results[i].Same {
					t.Errorf("%s: python %d.%d disagrees with the 3.12 archive rule", c.name, major, minor)
				}
				compared++
				out, errw, code := runPath(paths[i], c.env)
				want := results[i]
				var problems []string
				switch {
				case want.Crash != "":
					if code != 1 || out != "" {
						problems = append(problems, fmt.Sprintf("helper crashed (%s); go code=%d stdout=%q", want.Crash, code, out))
					}
				default:
					if code != want.Rc || out != want.Out {
						problems = append(problems, fmt.Sprintf("python rc=%d out=%q\n    go     rc=%d out=%q", want.Rc, want.Out, code, out))
					}
					if !strings.Contains(want.Err, "Warning") && errw != want.Err {
						problems = append(problems, fmt.Sprintf("python stderr=%q\n    go     stderr=%q", want.Err, errw))
					}
				}
				if len(problems) > 0 {
					bad++
					if bad <= 25 {
						t.Errorf("%s (%d bytes): %s", c.name, len(c.input), strings.Join(problems, "\n    "))
					}
				}
			}
			t.Logf("compared %d inputs, %d differ, %d skipped as version-dependent behaviour of this interpreter", compared, bad, skipped)
		})
	}
}

// The in-process driver must behave like the command line it stands for.
func TestParityDriverMatchesCommandLine(t *testing.T) {
	py := pythons(t)[0]
	helper := stagedHelper(t)
	dir := t.TempDir()
	for name, input := range map[string][]byte{"jar": buildZip(twoClasses(), zopts{}), "class": c52, "junk": []byte("junk"), "empty-jar": buildZip(nil, zopts{})} {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, input, 0o644); err != nil {
			t.Fatal(err)
		}
		var stdout, stderr bytes.Buffer
		cmd := exec.Command(py, "-I", "-B", helper, "classfile-facts", p)
		cmd.Stdout, cmd.Stderr = &stdout, &stderr
		if err := cmd.Run(); err != nil {
			t.Fatalf("%s: %v\n%s", name, err, stderr.String())
		}
		out, errw, code := runPath(p, nil)
		if code != 0 || out != stdout.String() || errw != stderr.String() {
			t.Errorf("%s: go %q/%q/%d, python CLI %q/%q", name, out, errw, code, stdout.String(), stderr.String())
		}
	}
	// The usage error and a missing file, through the real command line.
	var stderr bytes.Buffer
	cmd := exec.Command(py, "-I", "-B", helper, "classfile-facts")
	cmd.Stderr = &stderr
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 2 || !strings.HasPrefix(stderr.String(), "usage: corroborate_java.py classfile-facts") {
		t.Errorf("python usage: %v %q", err, stderr.String())
	}
}

// cp437High must be what the interpreter's codec says.
func TestCP437TableMatchesPython(t *testing.T) {
	py := pythons(t)[0]
	cmd := exec.Command(py, "-I", "-c", "import sys; sys.stdout.write(bytes(range(128, 256)).decode('cp437'))")
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != cp437High {
		t.Fatalf("cp437High differs from Python's cp437 codec")
	}
}

// stagedHelper copies the frozen helper into a fresh directory next to a `lib` link to the live toolbelt/lib (only
// the script is frozen; the helpers it imports stay on main) and returns the copy's path.
func stagedHelper(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(helperPath)
	if err != nil {
		t.Fatalf("the legacy helper is missing: %v", err)
	}
	lib, err := filepath.Abs("../../../../toolbelt/lib")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.Symlink(lib, filepath.Join(dir, "lib")); err != nil {
		t.Fatal(err)
	}
	helper := filepath.Join(dir, filepath.Base(helperPath))
	if err := os.WriteFile(helper, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return helper
}
