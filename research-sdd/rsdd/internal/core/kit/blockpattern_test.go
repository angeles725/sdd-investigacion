package kit

import (
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// The slug class is the one pinned difference between lib/block-files.sh (C locale) and verify-block's awk
// (UTF-8 locale): the Unicode variants accept a letter outside ASCII in the slug, the C one does not.
func TestBlockFileNameUnicode(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want []string
	}{
		{"x-block12-notas.md", []string{"x-block12-notas.md", "x-", "block", "12", "-notas"}},
		{"bloque3.md", []string{"bloque3.md", "", "bloque", "3", ""}},
		{"a-bloque7-año.md", []string{"a-bloque7-año.md", "a-", "bloque", "7", "-año"}},
		{"x-block1-a b.md", nil},
		{"x-blockx.md", nil},
	} {
		if got := BlockFileNameUnicode.FindStringSubmatch(tc.in); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%q: %q, want %q", tc.in, got, tc.want)
		}
	}
	if !BlockPathUnicode.MatchString("dir/x-bloque2-año.md") || BlockPathUnicode.MatchString("dir/bloque2.md") {
		t.Error("BlockPathUnicode must need a prefix and take a Unicode slug")
	}
	if reBlock.MatchString("dir/x-bloque2-año.md") || !reBlock.MatchString("dir/x-bloque2-ano.md") {
		t.Error("the C-locale pattern must stay ASCII-only")
	}
}

// Guard (kit #2600): the block-file ERE and the SCRIPTS-MANIFEST row reader each have ONE definition, here in
// core/kit. A new non-test file spelling the block pattern, or a second row-reader marker, fails this test.
// Extend the allowlist only for a pattern with genuinely different semantics, and say why. The check is lexical
// (a renamed pattern would slip through), which is why it is a tripwire for the copy-paste case, not a proof.
// reBlockSpelling matches the kind alternation followed by regex syntax (a class, a quantifier, a group), so the
// human-readable `<prefix>-(block|bloque)<N>.md` in messages and comments does not trip the guard.
var reBlockSpelling = regexp.MustCompile(`\((?:\?:)?block\|bloque\)(\[|0\*|\\|\()`)

func TestSingleDefinitions(t *testing.T) {
	// Files that spell the kind alternation with their own semantics (prose scans, prefix strips, text lint),
	// not the block-file basename ERE. Shrink-only.
	other := map[string]bool{
		"core/kit/focusscan.go":         true, // claim/number scans over prose, not file names
		"corpus/archive_gates.go":       true, // the sed prefix strip of archive.sh
		"corpus/catalog/match.go":       true, // CATALOG matcher with a Python-class number
		"lint/rules.go":                 true, // lint rule R3 over text
		"verify/registry.go":            true, // unclassifiable-name detector and messages
		"verify/corrections/blocks.go":  true, // the <prefix>-blockN token of a FOCUSES.md cell (prose), not a file name
		"verify/corrections/extract.go": true, // [Block N] references and bracket tags in block text
		"core/kit/blockfiles.go":        true, // the one definition
	}
	root := "../.."
	seen := 0
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		seen++
		s := string(b)
		if reBlockSpelling.MatchString(s) && !other[rel] {
			t.Errorf("%s spells the block pattern: use core/kit (FilterBlockFiles, BlockFileNameUnicode, BlockPathUnicode)", rel)
		}
		if strings.Contains(s, "SM-ROW") && rel != "core/kit/scriptsmanifest.go" {
			t.Errorf("%s holds a SCRIPTS-MANIFEST row reader: use kit.ScriptsManifestRows", rel)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if seen < 50 {
		t.Fatalf("the guard walked only %d files: it did not look", seen)
	}
}
