//go:build !nodiff

package lint

import (
	"bytes"
	"encoding/json"
	"math/rand"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// Random-input differential: every rewritten regex / helper against the live frozen Python (testdata/legacy/oracle.py).

type oracleCall struct {
	Fn     string `json:"fn"`
	Inputs []any  `json:"inputs"`
}

func runOracle(t *testing.T, calls []oracleCall) [][]any {
	t.Helper()
	script, err := filepath.Abs("testdata/legacy/oracle.py")
	if err != nil {
		t.Fatal(err)
	}
	req, err := json.Marshal(map[string]any{"calls": calls})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("python3", "-I", script)
	cmd.Stdin = bytes.NewReader(req)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("oracle failed: %v\n%s", err, errb.String())
	}
	var resp struct {
		Results [][]any `json:"results"`
	}
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		t.Fatalf("oracle output: %v", err)
	}
	if len(resp.Results) != len(calls) {
		t.Fatalf("oracle returned %d result lists for %d calls", len(resp.Results), len(calls))
	}
	return resp.Results
}

var oracleVocab = []string{
	" ", "  ", "\u00a0", "\u3000", "\t", ",", ".", ";", "!", "?", "(", ")", "`", "``", "-", "/", "_", ":", "=", "[", "]", "*", "\u2014", "\u2013", "\u00e9", "\u0663", "\u00b2", "\u4e2d", "\u0130", "\u0131", "\u017f", "\u212a",
	"x", "A", "B", "G", "0", "1", "12", "4", "15", "5", "a", "e", "s", "I", "i", "k", "K", "n", "t", "o",
	"uses", "use", "adopted", "adoption", "rewritten", "replaces", "modernized", "migrated to", "lambda", "pattern-matching", "switch expression", "text block", "record pattern", "var keyword", "`var`", "sealed classes",
	"sealed hierarchy", "enhanced for", "for-each", "records / sealed", "javap", "bytecode", "docSource", "LocalVariableTable", "fail-open", "fails open", "bypass", "Bypass", "bypassed", "no-op", "ungated", "drops cx",
	"null Context", "getPermissions(null)", "permission", "security", "auth", "oauth2", "unauthorized", "Context", "cx", "policy", "policies", "Access", "Allow", "Block", "Block 4", "[Block 3]", "[Block 3", "action:", "Bypass action",
	"Service Auth", "dispatch:", "cited-absence:", "todo", "TODO", "tbd", "n/a", "none", "unknown", "?", "??", "abc", "abcd", "G7:", "B34-G6", "Gap", "see block", "block12.md", "dead constant", "constant is unused", "constants are dead",
	"shadow literal", "literal shadows", "duplicates its own constant", "constant duplicated", "hardcoded", "instead of", "the constant", "compile-time constant", "ldc", "JLS 4.12.4", "inline", "inlined constant", "javac",
	"N5-only", "new in N5", "added in N5", "introduced in N5", "absent from N4", "4.15", "4.150", "14.15", "3.4.15", "PowerB", "jar", "class", "classes", "module", "feature", "API", ".jar", ".class", "not", "never", "isn't",
	"only", "just", "whether", "whether or not", "Is the jar", "does", "did", "right", "no", "isn't it", ".dll", ".so", ".so.1", ".so.1.2", "a.dll", "lib.so.12", "x.exe", "a.dylib", "PE32", "PE32+", "ELF", "ELF64", "Mach-O", "PE binary",
	"PE header", "Authenticode", "[CERT]", "[CERT-hw]", "0x1000", "0xabc", "0x10", "VA", "RVA", "offset", "1234abcd", "deadbeef", "decade", "beef1", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde", "readelf", "objdump", "r2", "R2", "radare2", "`nm`", "nm", "strings", "`strings`", "`nm -D`", "debug/pe", "debug/elf", "gdb", "ilspy", "ilspycmd", "xxd",
	"child gaps", "Child gaps opened", "closed", "resolved", "not closed", "not yet closed", "No child gaps", "Closed child gaps", "12.5%", "2.5x", "3k", "5kB", "1,000", "4.15x", "2026-10-01", "1.2.3", "B12", "B12-G3", "\u00a7 12.3",
	"coverage-check:", "measured-by:", "`coverage-check:`", "->", "\u2192", "`code`", "foo", "grep foo", "TBD", "wip", "Open child gaps", "Child gaps (all closed)",
}

var oracleSeps = []string{" ", " ", " ", "", "", ". ", "; ", ", ", "\u00a0", "\n"}

func randText(r *rand.Rand, prefix string) string {
	var b strings.Builder
	b.WriteString(prefix)
	for i, n := 0, 1+r.Intn(8); i < n; i++ {
		b.WriteString(oracleVocab[r.Intn(len(oracleVocab))])
		b.WriteString(oracleSeps[r.Intn(len(oracleSeps))])
	}
	return strings.TrimSuffix(b.String(), "\n")
}

func TestLintPackOracleRandom(t *testing.T) {
	t.Parallel()
	r := rand.New(rand.NewSource(20261101))
	const n = 2500
	var names []string
	for k := range goOracle {
		names = append(names, k)
	}
	sort.Strings(names)
	var calls []oracleCall
	for _, fn := range names {
		c := oracleCall{Fn: fn}
		for i := 0; i < n; i++ {
			switch fn {
			case "cg.sentence_end":
				text := randText(r, "")
				rl := len([]rune(text))
				c.Inputs = append(c.Inputs, []any{text, r.Intn(rl + 2), r.Intn(rl + 3)})
			case "cg.judge":
				c.Inputs = append(c.Inputs, "- B1-G1 "+randText(r, ""))
			case "cg.bullet", "cg.label":
				c.Inputs = append(c.Inputs, randText(r, []string{"", "- ", "  * ", "+ (", "- B1-G1 ", "- (B2-G3)"}[r.Intn(6)]))
			default:
				c.Inputs = append(c.Inputs, randText(r, ""))
			}
		}
		calls = append(calls, c)
	}
	res := runOracle(t, calls)
	for ci, c := range calls {
		bad := 0
		for i, in := range c.Inputs {
			var s string
			if sv, ok := in.(string); ok {
				s = sv
			} else {
				b, _ := json.Marshal(in)
				s = string(b)
			}
			got := normJSON(t, goOracle[c.Fn](s))
			if !reflect.DeepEqual(got, res[ci][i]) {
				bad++
				if bad <= 5 {
					t.Errorf("%s(%q) = %v, Python says %v", c.Fn, s, got, res[ci][i])
				}
			}
		}
		if bad > 5 {
			t.Errorf("%s: %d of %d random inputs differ", c.Fn, bad, len(c.Inputs))
		}
	}
}
