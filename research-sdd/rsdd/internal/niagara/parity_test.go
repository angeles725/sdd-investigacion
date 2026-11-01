package niagara

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// Differential parity: the frozen legacy script (testdata/legacy/bog_nav.py, byte-identical to bog_nav.py at the
// base commit) and the Go command run on the same inputs in the same sandbox path, and stdout, stderr, exit code
// and every file the run left behind (name, mode, content) must be byte-equal. The only differences allowed are
// the ones in declared below, each with the reason it cannot match; a declaration that no longer diverges fails.

type outcome struct {
	code    int
	stdout  string
	stderr  string
	effects string // sorted listing of the sandbox after the run, with the content of regular files
}

type pcase struct {
	name  string
	setup func(t *testing.T, dir string) []string
}

// declared divergences, keyed by case name. normalise is applied to the effects of BOTH sides.
var declared = map[string]struct {
	reason    string
	normalise func(string) string
}{
	"stored_claims_more_than_the_file_holds": {"CPython >= 3.13.x refuses a member whose compressed size overlaps the next header (\"Overlapped entries\") before reading; older ones, and Go, reach the bare EOF the read would hit", entryErrorText},
	"truncated_deflate_forged_csize":         {"CPython >= 3.13.x refuses a member whose compressed size overlaps the next header (\"Overlapped entries\") before reading; older ones, and Go, reach the bare EOF the read would hit", entryErrorText},
	"corrupt_deflate.bog":                    {"the text after 'Error -3 while decompressing data: ' is zlib's internal reason; Go's inflater words its own", zlibReason},
}

var zlibRE = regexp.MustCompile(`(Error -\d+ while decompressing data: )[^"]*`)

var entryErrRE = regexp.MustCompile(`"ZIP entry read error: [^"]*"`)

func entryErrorText(s string) string {
	return entryErrRE.ReplaceAllString(s, `"ZIP entry read error: <reason>"`)
}

func zlibReason(s string) string { return zlibRE.ReplaceAllString(s, "${1}<inflater reason>") }

func python(t *testing.T) string {
	t.Helper()
	p, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("parity: python3 not found in PATH; the Go port is NOT proven against the legacy script in this run")
	}
	return p
}

func legacyScript(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("testdata", "legacy", "bog_nav.py"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("parity: frozen legacy script missing at %s (%v): a moved package must update the path, not skip", p, err)
	}
	return p
}

func snapshot(t *testing.T, dir string) string {
	t.Helper()
	var lines []string
	err := filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		switch {
		case fi.Mode()&os.ModeSymlink != 0:
			tgt, _ := os.Readlink(p)
			lines = append(lines, fmt.Sprintf("%s symlink -> %s", rel, tgt))
		case fi.Mode().IsRegular():
			b, _ := os.ReadFile(p)
			if strings.HasSuffix(rel, ".json") {
				lines = append(lines, fmt.Sprintf("%s %v\n%s", rel, fi.Mode().Perm(), b))
			} else {
				lines = append(lines, fmt.Sprintf("%s %v %d bytes", rel, fi.Mode().Perm(), len(b)))
			}
		default:
			lines = append(lines, fmt.Sprintf("%s %v", rel, fi.Mode()))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(lines)
	return strings.Join(lines, "\n")
}

func fresh(t *testing.T, dir string) {
	t.Helper()
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
}

func runLegacy(t *testing.T, py, script, dir string, args []string) outcome {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, py, append([]string{"-I", script}, args...)...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "COLUMNS=80", "PYTHONDONTWRITEBYTECODE=1", "LC_ALL=C.UTF-8")
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("legacy run failed to start: %v", err)
	}
	return outcome{code, out.String(), errb.String(), snapshot(t, dir)}
}

func runGo(t *testing.T, dir string, args []string) outcome {
	t.Helper()
	code, out, errs := run(args...)
	return outcome{code, out, errs, snapshot(t, dir)}
}

func fileCase(name string, data []byte) pcase {
	return pcase{name, func(t *testing.T, dir string) []string {
		in := filepath.Join(dir, "in.bog")
		if err := os.WriteFile(in, data, 0o600); err != nil {
			t.Fatal(err)
		}
		return []string{"--input", in, "--output", filepath.Join(dir, "out.json")}
	}}
}

func repeatTags(n int, format string) string {
	var sb strings.Builder
	sb.WriteString("<root>\n")
	for i := 0; i < n; i++ {
		fmt.Fprintf(&sb, format, i, i)
	}
	return sb.String()
}

func u(v uint32) *uint32 { return &v }

func parityCases(t *testing.T) []pcase {
	t.Helper()
	var cases []pcase
	fx := suite(t)
	names := make([]string, 0, len(fx))
	for n := range fx {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		b, err := os.ReadFile(fx[n])
		if err != nil {
			t.Fatal(err)
		}
		cases = append(cases, fileCase(n, b))
	}
	for _, g := range []string{"plaintext", "edge"} {
		b, err := os.ReadFile(filepath.Join("testdata", "golden", g+".bog"))
		if err != nil {
			t.Fatal(err)
		}
		cases = append(cases, fileCase("golden_"+g, b))
	}
	zipCase := func(name string, data []byte) { cases = append(cases, fileCase(name, data)) }
	zipCase("flipped_deflate", bogtest.FlippedDeflate())
	zipCase("stored", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte(bogtest.ValidXML), Method: bogtest.Stored}))
	zipCase("forged_small_size", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte(bogtest.ValidXML), Size: u(10)}))
	zipCase("forged_big_size", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte(bogtest.ValidXML), Size: u(1 << 20)}))
	zipCase("duplicate_names", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<p n='Old' h='1' t='b:X'/>")}, bogtest.Entry{Name: "file.xml", Data: []byte("<p n='New' h='1' t='b:X'/>")}))
	zipCase("nested_suffix", bogtest.Zip(bogtest.Entry{Name: "readme", Data: []byte("x")}, bogtest.Entry{Name: "dir/file.xml", Data: []byte(bogtest.ValidXML)}))
	zipCase("exact_beats_suffix", bogtest.Zip(bogtest.Entry{Name: "x/file.xml", Data: []byte("<p n='S' h='1' t='b:X'/>")}, bogtest.Entry{Name: "file.xml", Data: []byte("<p n='E' h='1' t='b:X'/>")}))
	zipCase("no_file_xml", bogtest.Zip(bogtest.Entry{Name: "other.xml", Data: []byte("<a/>")}))
	zipCase("zip_no_entries", bogtest.Zip())
	zipCase("pk_garbage", []byte("PK\x03\x04 not a real archive at all"))
	zipCase("pk_three_bytes", []byte("PK<"))
	zipCase("strong_encryption_flag", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Flags: 0x40}))
	zipCase("patched_data_flag", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Flags: 0x20}))
	zipCase("data_descriptor_flag", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte(bogtest.ValidXML), Flags: 0x08}))
	zipCase("empty_file_xml", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: nil}))
	zipCase("zero_byte_input", nil)
	zipCase("whitespace_then_xml", []byte("  \n\t\r\n"+bogtest.ValidXML))
	zipCase("bom_then_xml", append([]byte("\xEF\xBB\xBF"), bogtest.ValidXML...))
	zipCase("invalid_utf8_names", []byte("<p n='bad\xff\xe2\x82x' h='1' t='b:X\xed\xa0\x80'/>\n<p n='ok' h='2' t='\xc3'/>"))
	zipCase("line_separators", []byte("<p n='A' h='1' t='b:X'>\r<p n='B' h='2' t='b:X'/>\x0b<p n='C' h='3' t='b:X'/>\xc2\x85<p n='D' h='4' t='b:X'/>\xe2\x80\xa8<p n='E' h='5' t='b:X'/>\x1c<p n='F' h='6' t='b:X'/>\r\n</p>"))
	zipCase("unicode_word_boundaries", []byte("<p \xc3\xa9n='Z' n='A' h='1' t='b:X'/>\n<p\xc3\xa9 n='B' h='2' t='b:X'/>\n<p n=\"C\" h='3\" t='b:X'/>\n<p n='D' h=\"4\" t='' m='\xe2\x80\x83a=b\x1cc=d'/>"))
	zipCase("unicode_space_in_prefixes", []byte("<p n='A' h='1' t='a:X' m='a=one\xc2\xa0b=two\xe2\x80\x83c=three\xe3\x80\x80d=four\x1de=five'/>\n<p n='B' h='2' t='b:X'/><p n='C' h='3' t='e:X'/>"))
	zipCase("empty_attributes", []byte("<p n='' h='' t=''/>\n<p n='' h='' t=''/>"))
	zipCase("link_edges", []byte("<p n='C' h='1' t='b:X'>\n<p n='L1' t='b:Link'>\n<p n='sourceOrd' v='h:'/>\n</p>\n<p n='L2' t='b:Link'>\n<p n='sourceOrd' v='h:1'/>\n<p n='sourceSlotName' v=''/>\n<p n='targetSlotName' v='t'/>\n</p>\n<p n='L3' t='b:Link'>\n<p n='x' t='b:Y'>\n</p>\n<p n='sourceOrd' v='h:1'/>\n</p>\n</p>"))
	zipCase("same_line_tags", []byte("<p n='A' h='1' t='b:X'><p n='B' h='2' t='b:X'><p n='C' h='3' t='b:X'/></p></p>"))
	zipCase("deep_nesting", []byte(strings.Repeat("<p n='n' h='1' t='b:X'>\n", 3000)+strings.Repeat("</p>\n", 3000)))
	zipCase("zip_name_with_nul", bogtest.Zip(bogtest.Entry{Name: "file.xml\x00junk", Data: []byte(bogtest.ValidXML)}))
	zipCase("equal_paths_at_scale", []byte(repeatTags(300, "<p n='same' h='%[1]d' t='x:T'/>\n<p n='o%[1]d' h='x%[2]d' t='x:T'/>\n")))
	zipCase("unbalanced_closers", []byte("</p></p></a></a>\n<p n='A' h='1' t='b:X'/>"))
	zipCase("component_cap", []byte(repeatTags(maxComponents+1, "<p n='c%06d' h='%d' t='b:X'/>\n")))
	zipCase("component_cap_exact", []byte(repeatTags(maxComponents, "<p n='c%06d' h='%d' t='b:X'/>\n")))
	zipCase("duplicate_handles_sorting", []byte("<p n='b' h='1' t='x:A'/>\n<p n='a' h='2' t='x:A'/>\n<p n='b' h='3' t='x:B'/>\n<p n='Z' h='4' t='x:A'/>\n<p n='b' h='2' t='x:C'/>"))
	var links strings.Builder
	links.WriteString("<p n='C' h='1' t='b:X'>\n")
	for i := 0; i < maxLinks+1; i++ {
		fmt.Fprintf(&links, "<p n='L%d' t='b:Link'>\n<p n='sourceOrd' v='h:1'/>\n</p>\n", i)
	}
	zipCase("link_cap", []byte(links.String()))
	var exact strings.Builder
	exact.WriteString("<p n='C' h='1' t='b:X'>\n")
	for i := 0; i < maxLinks; i++ {
		fmt.Fprintf(&exact, "<p n='L%d' t='b:Link'>\n<p n='sourceOrd' v='h:1'/>\n</p>\n", i)
	}
	zipCase("link_cap_exact", []byte(exact.String()))
	zipCase("truncated_deflate", bogtest.TruncatedDeflate())
	zipCase("truncated_deflate_forged_csize", bogtest.TruncatedDeflateForgedCSize())
	zipCase("stored_claims_more_than_the_file_holds", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Method: bogtest.Stored, Size: u(1 << 20), CSize: u(1 << 20)}))
	zipCase("stored_compressed_size_below_size", bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte(bogtest.ValidXML), Method: bogtest.Stored, CSize: u(30)}))

	cases = append(cases,
		pcase{"absent_input", func(t *testing.T, dir string) []string {
			return []string{"--input", filepath.Join(dir, "nope.bog"), "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"empty_path_input", func(t *testing.T, dir string) []string {
			return []string{"--input", "", "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"directory_input", func(t *testing.T, dir string) []string {
			return []string{"--input", dir, "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"path_through_a_file", func(t *testing.T, dir string) []string {
			in := filepath.Join(dir, "f")
			_ = os.WriteFile(in, []byte("<a/>"), 0o600)
			return []string{"--input", filepath.Join(in, "x"), "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"symlink_input", func(t *testing.T, dir string) []string {
			real := filepath.Join(dir, "real.bog")
			_ = os.WriteFile(real, []byte(bogtest.ValidXML), 0o600)
			link := filepath.Join(dir, "link.bog")
			if err := os.Symlink(real, link); err != nil {
				t.Fatal(err)
			}
			return []string{"--input", link, "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"fifo_input", func(t *testing.T, dir string) []string {
			fifo := filepath.Join(dir, "in.fifo")
			if err := syscall.Mkfifo(fifo, 0o600); err != nil {
				t.Fatal(err)
			}
			return []string{"--input", fifo, "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"output_exists", func(t *testing.T, dir string) []string {
			in := filepath.Join(dir, "in.bog")
			_ = os.WriteFile(in, []byte(bogtest.ValidXML), 0o600)
			_ = os.WriteFile(filepath.Join(dir, "out.json"), []byte("existing\n"), 0o600)
			return []string{"--input", in, "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"output_is_symlink", func(t *testing.T, dir string) []string {
			in := filepath.Join(dir, "in.bog")
			_ = os.WriteFile(in, []byte(bogtest.ValidXML), 0o600)
			victim := filepath.Join(dir, "victim.txt")
			_ = os.WriteFile(victim, []byte("victim\n"), 0o600)
			if err := os.Symlink(victim, filepath.Join(dir, "out.json")); err != nil {
				t.Fatal(err)
			}
			return []string{"--input", in, "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"output_is_dangling_symlink", func(t *testing.T, dir string) []string {
			in := filepath.Join(dir, "in.bog")
			_ = os.WriteFile(in, []byte(bogtest.ValidXML), 0o600)
			if err := os.Symlink(filepath.Join(dir, "gone"), filepath.Join(dir, "out.json")); err != nil {
				t.Fatal(err)
			}
			return []string{"--input", in, "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"output_directory_missing", func(t *testing.T, dir string) []string {
			in := filepath.Join(dir, "in.bog")
			_ = os.WriteFile(in, []byte(bogtest.ValidXML), 0o600)
			return []string{"--input", in, "--output", filepath.Join(dir, "no", "such", "out.json")}
		}},
		pcase{"output_is_directory", func(t *testing.T, dir string) []string {
			in := filepath.Join(dir, "in.bog")
			_ = os.WriteFile(in, []byte(bogtest.ValidXML), 0o600)
			_ = os.Mkdir(filepath.Join(dir, "out.json"), 0o700)
			return []string{"--input", in, "--output", filepath.Join(dir, "out.json")}
		}},
		pcase{"input_equals_output", func(t *testing.T, dir string) []string {
			in := filepath.Join(dir, "in.bog")
			_ = os.WriteFile(in, []byte(bogtest.ValidXML), 0o600)
			return []string{"--input", in, "--output", in}
		}},
		pcase{"option_equals_form", func(t *testing.T, dir string) []string {
			in := filepath.Join(dir, "in.bog")
			_ = os.WriteFile(in, []byte(bogtest.ValidXML), 0o600)
			return []string{"--input=" + in, "--out=" + filepath.Join(dir, "out.json")}
		}},
	)
	for _, ac := range argparseTable() {
		args := ac.args
		cases = append(cases, pcase{"args: " + ac.name, func(t *testing.T, dir string) []string { return args }})
	}
	return cases
}

// legacySHA256 pins the oracle: it is bog_nav.py at origin/main b2ac8ecc (before the port). The oracle moves
// only with a recorded reason, never silently.
const legacySHA256 = "e91507936210817ad80f477c52d94937e9f972145c9837de347001cbe212ae95"

func TestLegacyOracleIsFrozen(t *testing.T) {
	b, err := os.ReadFile(legacyScript(t))
	if err != nil {
		t.Fatal(err)
	}
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) != legacySHA256 {
		t.Errorf("testdata/legacy/bog_nav.py sha256 = %x, want %s: the parity oracle changed", sum, legacySHA256)
	}
}

func TestParityWithLegacyScript(t *testing.T) {
	py := python(t)
	script := legacyScript(t)
	dir := t.TempDir()
	cases := parityCases(t)
	used := map[string]bool{}
	equal, diverged := 0, 0
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fresh(t, dir)
			legacy := runLegacy(t, py, script, dir, c.setup(t, dir))
			fresh(t, dir)
			args := c.setup(t, dir)
			got := runGo(t, dir, args)
			if d, ok := declared[c.name]; ok {
				used[c.name] = true
				if legacy.effects == got.effects {
					t.Errorf("declared divergence %q is stale: both sides already agree (%s)", c.name, d.reason)
				}
				legacy.effects, got.effects = d.normalise(legacy.effects), d.normalise(got.effects)
			}
			if legacy != got {
				t.Errorf("legacy and Go differ for %q\n legacy: code=%d stdout=%q stderr=%q\n    go:  code=%d stdout=%q stderr=%q\n legacy effects:\n%s\n go effects:\n%s",
					args, legacy.code, legacy.stdout, legacy.stderr, got.code, got.stdout, got.stderr, short(legacy.effects), short(got.effects))
			}
		})
	}
	for name, d := range declared {
		if !used[name] {
			t.Errorf("declared divergence %q (%s) matches no case", name, d.reason)
			continue
		}
		diverged++
	}
	equal = len(cases) - diverged
	t.Logf("parity: %d cases against the frozen legacy script: %d byte-equal, %d equal after a declared normalisation", len(cases), equal, diverged)
}

func short(s string) string {
	if len(s) > 1500 {
		return s[:1500] + "..."
	}
	return s
}
