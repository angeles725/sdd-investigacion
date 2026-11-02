//go:build linux && !nodiff

package adapter

import (
	"os/exec"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestNFKCUnicodeVersion(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required: %v", err)
	}
	out, err := exec.Command(py, "-I", "-c", "import unicodedata;print(unicodedata.unidata_version)").Output()
	if err != nil {
		t.Fatal(err)
	}
	got := strings.TrimSpace(string(out))
	if got != nfkcUnicodeVersion && pyOracle(t).older() {
		t.Logf("oracle has Unicode %s, tables are %s: only code points the oracle lacks may differ", got, nfkcUnicodeVersion)
		return
	}
	if got != nfkcUnicodeVersion {
		t.Fatalf("interpreter has Unicode %s, tables are %s: rerun testdata/gen_nfkc.py", got, nfkcUnicodeVersion)
	}
}

// Every code point: the port folds exactly the code points whose NFKC contains printable ASCII, to
// the same text unicodedata gives.
func TestParityNFKCFoldedCodePoints(t *testing.T) {
	var all []string
	for r := rune(0); r <= utf8.MaxRune; r++ {
		if r < 0xD800 || r > 0xDFFF {
			all = append(all, string(r))
		}
	}
	toolbeltAbs = mustAbs(t, toolbeltDir)
	// The oracle answers for every code point in one concurrent sweep (4 drivers), then the
	// comparison walks it in the original batches.
	oracle := runDriverParallel[string](t, "nfkc", all, 4)
	const batch = 1 << 17
	for lo := 0; lo < len(all); lo += batch {
		hi := min(lo+batch, len(all))
		rs := oracle[lo:hi]
		var bad []int
		for i, want := range rs {
			in := all[lo+i]
			if !strings.ContainsFunc(want, func(r rune) bool { return r >= 0x20 && r < 0x7f }) {
				want = in // not tabled: left as it is
			}
			if got := nfkc(in); got != want {
				bad = append(bad, i)
				rs[i] = want
			}
		}
		checkNFKCMismatches(t, all[lo:hi], bad, rs)
	}
}

// What the path checks do with the result is identical to Python's: a single compatibility code point,
// in front of, behind and inside path text, is accepted or refused with the same message.
func TestParityRelativePathEveryFoldedCodePoint(t *testing.T) {
	var cps []string
	for r := rune(0x80); r <= utf8.MaxRune; r++ {
		if (r < 0xD800 || r > 0xDFFF) && nfkc(string(r)) != string(r) {
			cps = append(cps, string(r))
		}
	}
	if pyOracle(t).older() {
		// Declared divergence: code points assigned after the oracle's Unicode version.
		var kept []string
		for i, un := range runDriver[bool](t, "unassigned", cps) {
			if !un {
				kept = append(kept, cps[i])
			}
		}
		cps = kept
	}
	var cases []vCase
	for _, c := range cps {
		for _, tmpl := range []string{"%s", "a/%s", "%s/b", "%s%s", "%s:x", "ab%s:", "x%2e%s"} {
			cases = append(cases, vCase{strings.ReplaceAll(strings.ReplaceAll(tmpl, "%%", "\x00"), "%s", c)})
		}
	}
	rs := runDriver[pyOut](t, "relative", cases)
	for i, c := range cases {
		got, err := relativePath(goValue(t, c.V), "ctx")
		if wantErr(t, "relative "+jsonString(c), rs[i], err) {
			var want string
			_ = unmarshalString(rs[i].Value, &want)
			if got != want {
				t.Errorf("relative %s: go %q python %q", jsonString(c), got, want)
			}
		}
	}
}

// checkNFKCMismatches fails on every mismatch, except that an older oracle may lack code points the
// tables know (declared divergence: Unicode version).
func checkNFKCMismatches(t *testing.T, inputs []string, bad []int, want []string) {
	t.Helper()
	if len(bad) == 0 {
		return
	}
	skip := make([]bool, len(bad))
	if pyOracle(t).older() {
		var sub []string
		for _, i := range bad {
			sub = append(sub, inputs[i])
		}
		skip = runDriver[bool](t, "unassigned", sub)
	}
	for k, i := range bad {
		if !skip[k] {
			t.Errorf("%+q: go %+q python %+q", inputs[i], nfkc(inputs[i]), want[i])
		}
	}
}
