package palette

// Contract states of palette-lexicon.v1 and the test that pins each (mutation-check one mutant per row):
//
//	absent / symlink / non-directory input, exit 2, no JSON ..... TestInputRejections
//	empty module, exit 0, artifacts_scanned 0 ................... TestFixtureGolden/empty-module
//	byte-exact document (key order, indent 2, newline) .......... TestFixtureGolden (all fixtures)
//	malformed XML, exit 1, status:failed JSON written ........... TestFixtureGolden/bad-palette-module
//	per-file duplicates, relpath keys, BOM, nesting ............. TestFixtureGolden (multi, same-basename, bom, nested)
//	Python str semantics (splitlines, isspace, U+FFFD) .......... TestFixtureGolden/edge-module, TestPyText
//	artifact without data, symlink artifact skipped ............. TestNoDataAndSymlinkArtifact
//	symlink .lexicon not counted ................................ TestSymlinkLexiconIgnored
//	read caps and truncation errors ............................. TestReadCaps
//	unreadable dir / file surfaces in errors[] .................. TestUnreadableSurfaces
//	output: new file only, no symlink, no overwrite ............. TestOutputRefusals
//	secrets: values never emitted ............................... TestSecretsNotEmitted
//	usage errors, argparse prefix matching ...................... TestUsage

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// run executes the command with cwd as the working directory and returns exit code, stdout and stderr.
func run(t *testing.T, cwd string, args ...string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	code := Run(args, cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Cwd: cwd})
	return code, out.String(), errb.String()
}

func scanInto(t *testing.T, module string) (int, map[string]any, []byte) {
	t.Helper()
	dir := t.TempDir()
	outPath := filepath.Join(dir, "out.json")
	code, _, stderr := run(t, dir, "--input", mustAbs(t, module), "--output", outPath)
	raw, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("no output written (exit %d, stderr %q): %v", code, stderr, err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("output is not JSON: %v", err)
	}
	return code, doc, raw
}

// The parse-error detail text is the XML library's own wording (expat vs encoding/xml); everything around it is
// contract. Goldens carry the placeholder.
var detail = regexp.MustCompile(`(parse error: ).*"`)

func mask(b []byte) []byte { return detail.ReplaceAll(b, []byte(`${1}<detail>"`)) }

func TestFixtureGolden(t *testing.T) {
	cases := []struct {
		name string
		exit int
	}{
		{"valid-module", 0}, {"empty-module", 0}, {"dup-keys-module", 0}, {"bad-palette-module", 1},
		{"multi-lexicon-module", 0}, {"bom-lexicon-module", 0}, {"same-basename-module", 0},
		{"nested-lexicon-module", 0}, {"edge-module", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			code, _, got := scanInto(t, filepath.Join("testdata", "modules", c.name))
			if code != c.exit {
				t.Errorf("exit = %d, want %d", code, c.exit)
			}
			want, err := os.ReadFile(filepath.Join("testdata", "golden", c.name+".json"))
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(mask(got), mask(want)) {
				t.Errorf("document differs from golden %s.json:\n got: %s\nwant: %s", c.name, mask(got), mask(want))
			}
		})
	}
}

func TestInputRejections(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, "file.txt"), "x")
	abs, _ := filepath.Abs(filepath.Join("testdata", "modules", "valid-module"))
	if err := os.Symlink(abs, filepath.Join(dir, "abslink")); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ name, input, stderr string }{
		{"absent", "nope", "palette-lexicon-agents: input not found: 'nope'\n"},
		{"symlink", "abslink", "palette-lexicon-agents: input is a symbolic link (rejected): 'abslink'\n"},
		{"symlink trailing slash", "abslink//", "palette-lexicon-agents: input is a symbolic link (rejected): 'abslink'\n"},
		{"not a directory", "file.txt", "palette-lexicon-agents: input is not a directory: 'file.txt'\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			outPath := filepath.Join(t.TempDir(), "out.json")
			code, stdout, stderr := run(t, dir, "--input", c.input, "--output", outPath)
			if code != 2 || stdout != "" || stderr != c.stderr {
				t.Errorf("got exit %d stdout %q stderr %q", code, stdout, stderr)
			}
			if _, err := os.Stat(outPath); err == nil {
				t.Error("JSON was produced for a rejected input")
			}
		})
	}
}

func TestNoDataAndSymlinkArtifact(t *testing.T) {
	mod := t.TempDir()
	mustMkdir(t, filepath.Join(mod, "bare", "extracted"))
	mustMkdir(t, filepath.Join(mod, "noext"))
	if err := os.Symlink(mustAbs(t, "testdata/modules/valid-module/alarm-rt"), filepath.Join(mod, "evil")); err != nil {
		t.Fatal(err)
	}
	code, doc, _ := scanInto(t, mod)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	arts := doc["artifacts"].([]any)
	if len(arts) != 1 {
		t.Fatalf("artifacts = %v, want only 'bare' (no-extracted dir and symlink dir are skipped)", arts)
	}
	a := arts[0].(map[string]any)
	if a["artifact"] != "bare" || a["palette_present"] != false || a["module_xml_present"] != false ||
		a["lexicon_files_seen"].(float64) != 0 || a["keys_examined"].(float64) != 0 {
		t.Errorf("no-data artifact = %v", a)
	}
	if doc["summary"].(map[string]any)["artifacts_scanned"].(float64) != 1 {
		t.Errorf("summary = %v", doc["summary"])
	}
}

func TestSymlinkLexiconIgnored(t *testing.T) {
	mod := t.TempDir()
	ext := filepath.Join(mod, "a", "extracted")
	mustMkdir(t, filepath.Join(ext, "sub"))
	mustWrite(t, filepath.Join(ext, "real.lexicon"), "k=1\n")
	outside := filepath.Join(t.TempDir(), "outside.lexicon")
	mustWrite(t, outside, "x=1\ny=2\n")
	if err := os.Symlink(outside, filepath.Join(ext, "link.lexicon")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), filepath.Join(ext, "linkdir")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(ext, "missing"), filepath.Join(ext, "dangling.lexicon")); err != nil {
		t.Fatal(err)
	}
	_, doc, _ := scanInto(t, mod)
	a := doc["artifacts"].([]any)[0].(map[string]any)
	if a["lexicon_files_seen"].(float64) != 1 || a["keys_examined"].(float64) != 1 {
		t.Errorf("symlinked lexicons were counted: %v", a)
	}
}

func TestSymlinkedMetaInfoEscapesRejected(t *testing.T) {
	mod := t.TempDir()
	ext := filepath.Join(mod, "a", "extracted")
	mustMkdir(t, ext)
	outside := t.TempDir()
	mustWrite(t, filepath.Join(outside, "module.xml"), `<module><type name="T"><agent/></type></module>`)
	if err := os.Symlink(outside, filepath.Join(ext, "META-INF")); err != nil {
		t.Fatal(err)
	}
	_, doc, _ := scanInto(t, mod)
	a := doc["artifacts"].([]any)[0].(map[string]any)
	if a["module_xml_present"] != false || a["agents_count"].(float64) != 0 {
		t.Errorf("containment guard read through a symlinked directory: %v", a)
	}
}

func TestReadCaps(t *testing.T) {
	t.Run("palette over old 4 MiB cap still parses", func(t *testing.T) {
		mod := t.TempDir()
		ext := filepath.Join(mod, "a", "extracted")
		mustMkdir(t, ext)
		var sb strings.Builder
		sb.WriteString("<bajaObjectGraph>")
		for i := 0; i < 130000; i++ {
			sb.WriteString(`<p n="entry-number-` + "0123456789" + `" t="b:Type" m="i"/>`)
		}
		sb.WriteString("</bajaObjectGraph>")
		mustWrite(t, filepath.Join(ext, "module.palette"), sb.String())
		code, doc, _ := scanInto(t, mod)
		if code != 0 || doc["summary"].(map[string]any)["palette_entries"].(float64) != 130000 {
			t.Errorf("exit %d summary %v", code, doc["summary"])
		}
	})
	t.Run("palette over 16 MiB is truncated and fails", func(t *testing.T) {
		mod := t.TempDir()
		ext := filepath.Join(mod, "a", "extracted")
		mustMkdir(t, ext)
		mustWrite(t, filepath.Join(ext, "module.palette"), "<g>"+strings.Repeat(" ", maxPaletteBytes))
		code, doc, _ := scanInto(t, mod)
		errs := doc["errors"].([]any)
		if code != 1 || doc["status"] != "failed" || len(errs) != 2 ||
			errs[1] != "a/module.palette: truncated at 16777216 bytes — XML parse failed" {
			t.Errorf("exit %d status %v errors %v", code, doc["status"], errs)
		}
	})
	t.Run("lexicon over 4 MiB reports truncation, keeps partial count", func(t *testing.T) {
		mod := t.TempDir()
		ext := filepath.Join(mod, "a", "extracted")
		mustMkdir(t, ext)
		mustWrite(t, filepath.Join(ext, "big.lexicon"), strings.Repeat("k=v\n", maxLexiconBytes/4+10))
		code, doc, _ := scanInto(t, mod)
		errs := doc["errors"].([]any)
		keys := doc["summary"].(map[string]any)["keys_examined"].(float64)
		if code != 1 || len(errs) != 1 || errs[0] != "a/big.lexicon: truncated at 4194304 bytes" || keys != float64(maxLexiconBytes/4) {
			t.Errorf("exit %d errors %v keys %v", code, errs, keys)
		}
	})
	t.Run("module.xml over 1 MiB reports truncation", func(t *testing.T) {
		mod := t.TempDir()
		ext := filepath.Join(mod, "a", "extracted", "META-INF")
		mustMkdir(t, ext)
		mustWrite(t, filepath.Join(ext, "module.xml"), "<module>"+strings.Repeat("<!-- -->", maxModuleXMLBytes/8)+"</module><!--tail-->")
		code, doc, _ := scanInto(t, mod)
		errs := doc["errors"].([]any)
		if code != 1 || len(errs) == 0 || errs[len(errs)-1] != "a/META-INF/module.xml: truncated at 1048576 bytes" {
			t.Errorf("exit %d errors %v", code, errs)
		}
	})
	t.Run("artifact cap 500 sets truncated", func(t *testing.T) {
		mod := t.TempDir()
		for i := 0; i < maxArtifacts+3; i++ {
			mustMkdir(t, filepath.Join(mod, "art"+pad(i), "extracted"))
		}
		_, doc, _ := scanInto(t, mod)
		if doc["truncated"] != true || len(doc["artifacts"].([]any)) != maxArtifacts {
			t.Errorf("truncated=%v artifacts=%d", doc["truncated"], len(doc["artifacts"].([]any)))
		}
	})
}

func TestUnreadableSurfaces(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("chmod 000 is ineffective as root")
	}
	mod := t.TempDir()
	ext := filepath.Join(mod, "a", "extracted")
	mustMkdir(t, filepath.Join(ext, "locked"))
	mustWrite(t, filepath.Join(ext, "ok.lexicon"), "k=1\n")
	mustWrite(t, filepath.Join(ext, "denied.lexicon"), "k=1\n")
	mustWrite(t, filepath.Join(ext, "locked", "hidden.lexicon"), "k=1\n")
	if err := os.Chmod(filepath.Join(ext, "denied.lexicon"), 0); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(ext, "locked"), 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(ext, "locked"), 0o755) })
	code, doc, _ := scanInto(t, mod)
	// The directory walk finishes (and reports) before any lexicon file is read.
	want := []any{
		"a/locked: unreadable directory (os.walk onerror)",
		"a/denied.lexicon: lexicon file unreadable",
	}
	got := doc["errors"].([]any)
	if code != 1 || doc["status"] != "failed" || len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("exit %d errors %v, want %v", code, got, want)
	}
	if doc["summary"].(map[string]any)["keys_examined"].(float64) != 1 {
		t.Errorf("the readable lexicon was not processed: %v", doc["summary"])
	}
}

func TestOutputRefusals(t *testing.T) {
	dir := t.TempDir()
	module := mustAbs(t, "testdata/modules/valid-module")
	victim := filepath.Join(dir, "victim.txt")
	mustWrite(t, victim, "victim-content")
	if err := os.Symlink(victim, filepath.Join(dir, "out-link.json")); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(dir, "existing.json"), "existing")
	cases := []struct{ name, out, stderr string }{
		{"symlink", "out-link.json", "palette-lexicon-agents: output out-link.json: File exists\n"},
		{"pre-existing", "existing.json", "palette-lexicon-agents: output existing.json: File exists\n"},
		{"missing parent", "no/such/out.json", "palette-lexicon-agents: output no/such/out.json: No such file or directory\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			code, _, stderr := run(t, dir, "--input", module, "--output", c.out)
			if code != 2 || stderr != c.stderr {
				t.Errorf("exit %d stderr %q, want 2 / %q", code, stderr, c.stderr)
			}
		})
	}
	if b, _ := os.ReadFile(victim); string(b) != "victim-content" {
		t.Errorf("victim was overwritten: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "existing.json")); string(b) != "existing" {
		t.Errorf("pre-existing output was overwritten: %q", b)
	}
	// A relative output path lands under the injected cwd, with mode 0600.
	code, _, stderr := run(t, dir, "--input", module, "--output", "fresh.json")
	fi, err := os.Stat(filepath.Join(dir, "fresh.json"))
	if code != 0 || err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("relative output: exit %d stderr %q err %v", code, stderr, err)
	}
}

func TestSecretsNotEmitted(t *testing.T) {
	mod := t.TempDir()
	ext := filepath.Join(mod, "a", "extracted")
	mustMkdir(t, ext)
	mustWrite(t, filepath.Join(ext, "s.lexicon"), "password=hunter2-SECRET\npassword=other-SECRET\n")
	_, _, raw := scanInto(t, mod)
	if bytes.Contains(raw, []byte("SECRET")) || !bytes.Contains(raw, []byte(`"password": 2`)) {
		t.Errorf("values leaked or key name missing:\n%s", raw)
	}
}

func TestUsage(t *testing.T) {
	module := mustAbs(t, "testdata/modules/empty-module")
	cases := []struct {
		name   string
		args   []string
		exit   int
		stderr string
	}{
		{"no args", nil, 2, "palette-lexicon-agents: error: the following arguments are required: --input, --output\n"},
		{"missing output", []string{"--input", module}, 2, "palette-lexicon-agents: error: the following arguments are required: --output\n"},
		{"unknown flag", []string{"--bogus"}, 2, "palette-lexicon-agents: error: unrecognized arguments: --bogus\n"},
		{"positional", []string{"--input", module, "--output", "x", "extra"}, 2, "palette-lexicon-agents: error: unrecognized arguments: extra\n"},
		{"flag without value", []string{"--input"}, 2, "palette-lexicon-agents: error: argument --input: expected one argument\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			code, _, stderr := run(t, t.TempDir(), c.args...)
			if code != c.exit || !strings.HasSuffix(stderr, c.stderr) || !strings.HasPrefix(stderr, "usage: palette-lexicon-agents [-h] --input MODULE_DIR --output JSON\n") {
				t.Errorf("exit %d stderr %q", code, stderr)
			}
		})
	}
	t.Run("help", func(t *testing.T) {
		code, stdout, _ := run(t, t.TempDir(), "-h")
		if code != 0 || !strings.HasPrefix(stdout, "usage: palette-lexicon-agents") {
			t.Errorf("exit %d stdout %q", code, stdout)
		}
	})
	t.Run("argparse prefix and = forms", func(t *testing.T) {
		dir := t.TempDir()
		code, _, stderr := run(t, dir, "--inp="+module, "--out", "o.json")
		if code != 0 {
			t.Errorf("exit %d stderr %q", code, stderr)
		}
	})
}

func TestPyText(t *testing.T) {
	t.Run("decode replaces maximal ill-formed subparts", func(t *testing.T) {
		for in, want := range map[string]string{
			"a\xe2\x82b":   "a�b", // truncated 3-byte sequence is one replacement
			"\xc3\x28":     "�(",  // bad continuation
			"\xf0\x9f\x98": "�",   // truncated 4-byte sequence
			"\xff\xfe":     "��",  // never valid
			"\xed\xa0\x80": "���", // surrogate is three
			"\xe0\x80\x80": "���",
			"plain":        "plain",
		} {
			if got := pyDecode([]byte(in)); got != want {
				t.Errorf("pyDecode(%q) = %q, want %q", in, got, want)
			}
		}
	})
	t.Run("utf-8-sig drops exactly one BOM", func(t *testing.T) {
		if got := pyDecodeSig([]byte("\xef\xbb\xbf\xef\xbb\xbfk")); got != "\xef\xbb\xbfk" {
			t.Errorf("got %q", got)
		}
	})
	t.Run("splitlines separators", func(t *testing.T) {
		got := pySplitLines("a\r\nb\rc\x0bd\x0ce\x1cf\x1dg\x1eh\u0085i j k\n")
		if len(got) != 11 || got[0] != "a" || got[10] != "k" {
			t.Errorf("got %q", got)
		}
		if got := pySplitLines("x\n\ny"); len(got) != 3 || got[1] != "" {
			t.Errorf("blank line lost: %q", got)
		}
	})
	t.Run("lexicon rules", func(t *testing.T) {
		n, dups := parseLexicon("# c\n\n  a = 1 \na=2\n=x\nnoeq\n\x1fb\x1f=1\nb=1\n")
		if n != 4 || len(dups) != 2 || dups["a"] != 2 || dups["b"] != 2 {
			t.Errorf("n=%d dups=%v", n, dups)
		}
	})
	t.Run("repr", func(t *testing.T) {
		for in, want := range map[string]string{"a": "'a'", "it's": `"it's"`, `a"b'c`: `'a"b\'c'`, "x\ny": `'x\ny'`, "é": "'é'", "\x01": `'\x01'`} {
			if got := pyRepr(in); got != want {
				t.Errorf("pyRepr(%q) = %s, want %s", in, got, want)
			}
		}
	})
}

func TestXMLWellFormedness(t *testing.T) {
	bad := []string{"", "  ", "<a>", "<a></b>", "<a/><b/>", "text<a/>", "<a/>junk", `<a x="1" x="2"/>`, "<a", "not xml"}
	for _, in := range bad {
		if in == "" {
			if n, err := parsePalette(in); n != 0 || err != nil {
				t.Errorf("empty text must be a clean zero, got %d %v", n, err)
			}
			continue
		}
		if _, err := parsePalette(in); err == nil {
			t.Errorf("parsePalette(%q) accepted malformed XML", in)
		}
	}
	if n, err := parsePalette("\xef\xbb\xbf<?xml version=\"1.0\"?><!--c--><r n=\"1\"><p/><p t=\"x\"/><q n=\"z\"/></r><!--t-->\n"); n != 1 || err != nil {
		t.Errorf("valid palette: %d %v", n, err)
	}
	if n, _ := parsePalette(`<r xmlns="urn:x"><p n="1"/></r>`); n != 0 {
		t.Errorf("namespaced <p> must not match, got %d", n)
	}
}

func pad(i int) string { return strings.Repeat("0", 4-len(itoa(i))) + itoa(i) }

func itoa(i int) string {
	b, _ := json.Marshal(i)
	return string(b)
}

func mustWrite(t *testing.T, p, s string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustMkdir(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustAbs(t *testing.T, p string) string {
	t.Helper()
	a, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	return a
}
