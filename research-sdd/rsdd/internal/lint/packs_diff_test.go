//go:build !nodiff

package lint

import (
	"fmt"
	"math/rand"
	"path/filepath"
	"strings"
	"testing"
)

// Differential: `rsdd lint block --pack ...` (Go) against the frozen pre-port Python (lint-block.sh + lint_block.py +
// the four packs under testdata/legacy). stdout, stderr and the exit code must match byte for byte.

var packConfigs = [][]string{
	{"--pack", "jvm"},
	{"--pack", "multi-version"},
	{"--pack", "native-binary"},
	{"--pack", "child-gap"},
	{"--pack", "jvm,multi-version", "--pack=native-binary", "--pack", "child-gap"},
	{"--pack", "child-gap", "--pack", "native-binary", "--pack", "jvm"},
}

func withPack(cfg []string, rest ...string) []string {
	return append(append([]string(nil), cfg...), rest...)
}

// Every fixture of the corpus (the core ones and the pack ones), every pack configuration, FAIL and --audit.
func TestLintPackDifferentialFixtures(t *testing.T) {
	t.Parallel()
	fx := fixtures(t)
	files := fixtureFiles(t, fx)
	for _, cfg := range packConfigs {
		same(t, "fail "+strings.Join(cfg, " "), fx, withPack(cfg, files...)...)
		same(t, "audit "+strings.Join(cfg, " "), fx, withPack(cfg, append([]string{"--audit"}, files...)...)...)
	}
}

// Each pack fixture on its own: the per-file SUMMARY (counters, typed zeros) is part of the comparison.
func TestLintPackDifferentialSingleFixtures(t *testing.T) {
	t.Parallel()
	fx := fixtures(t)
	all := packConfigs[4]
	for _, f := range fixtureFiles(t, fx) {
		if !strings.HasPrefix(f, "pack-") {
			continue
		}
		same(t, "all packs "+f, fx, withPack(all, f)...)
		same(t, "audit all packs "+f, fx, withPack(all, "--audit", f)...)
		for _, cfg := range packConfigs[:4] {
			same(t, strings.Join(cfg, " ")+" "+f, fx, withPack(cfg, f)...)
		}
	}
}

func TestLintPackDifferentialCorpora(t *testing.T) {
	t.Parallel()
	fx := fixtures(t)
	all := packConfigs[4]
	for _, d := range []string{"corpus", "corpus-empty", "corpus-nomatch", "corpus-unclassified", "corpus/", "nested-nope"} {
		same(t, "audit "+d, fx, withPack(all, "--audit", d)...)
		same(t, "fail "+d, fx, withPack(all, d)...)
	}
	same(t, "dir+file+absent", fx, withPack(all, "--audit", "corpus", "pack-r4.md", "absent.md")...)
	same(t, "empty+absent", fx, withPack(all, "--audit", "empty.md", "absent.md")...)
	same(t, "fail empty", fx, withPack(all, "empty.md", "pack-jvm.md")...)
	same(t, "blank only", fx, withPack(all, "--audit", "blank.md")...)
	same(t, "-- terminator", fx, withPack(all, "--audit", "--", "pack-r9.md")...)
}

func TestLintPackDifferentialLoader(t *testing.T) {
	t.Parallel()
	fx := fixtures(t)
	for _, args := range [][]string{
		{"--pack", "nosuch", "pack-jvm.md"}, {"--pack", "Bad_Name", "pack-jvm.md"}, {"--pack", "../x", "pack-jvm.md"},
		{"--pack", "-x", "pack-jvm.md"}, {"--pack", "", "pack-jvm.md"}, {"--pack", ",", "pack-jvm.md"}, {"--pack", ",,", "pack-jvm.md"},
		{"--pack=,", "pack-jvm.md"}, {"--pack=", "pack-jvm.md"}, {"--pack=-x", "pack-jvm.md"}, {"pack-jvm.md", "--pack"},
		{"--pack", "jvm,nosuch", "pack-jvm.md"}, {"--pack", "a b", "pack-jvm.md"}, {"--pack", "jvm\n", "pack-jvm.md"},
		{"--pack", "jvm\n\n", "pack-jvm.md"}, {"--pack", "\njvm", "pack-jvm.md"}, {"--pack", "JVM", "pack-jvm.md"}, {"--pack", "-", "pack-jvm.md"},
		{"--audit", "--pack", "nosuch", "corpus-empty"}, {"--pack", "J", "--pack", "nosuch", "pack-jvm.md"}, {"--pack", "nosuch", "--pack", "J", "pack-jvm.md"},
		{"--pack", "jvm", "--pack", ",", "pack-jvm.md"}, {"--pack", "jvm", "--pack", "nosuch", "absent.md"}, {"--pack", "jvm", "--bogus", "pack-jvm.md"},
		{"--pack", "0", "pack-jvm.md"}, {"--pack", "a-", "pack-jvm.md"}, {"--pack", "-a", "pack-jvm.md"}, {"--pack", "a--b", "pack-jvm.md"},
		{"--pack", "jvm", "-h"}, {"--pack", "nosuch", "-h"}, {"--pack"}, {"--pack", "jvm"}, {"--audit", "--pack", "jvm"},
		{"--pack", "jvm", "absent.md"}, {"--pack", "jvm", "--audit", "absent.md"},
	} {
		same(t, "loader", fx, args...)
	}
}

// ---- generated documents with pack vocabulary -------------------------------------------------------------------

var packVocab = []string{
	"The module adopts switch expressions throughout", "- the loader uses a lambda here", "| a | the code uses pattern-matching | javap |", "It rewrites the loop with enhanced for (javap shows it)", "We use `var` declarations",
	"This replaces a sealed envelope", "The var-length encoding is used", "sealed interfaces are adopted; see bytecode", "The filter fails open when the null Context is passed", "The Bypass action of the policy is Allow",
	"The check is bypassed. dispatch: Foo.bar resolves it", "ungated permission path (cited-absence: grep found none)", "> Gap 3: the security bypass is restated", "> Finding: the credential check is a no-op", "the dead constant is unused",
	"The hardcoded port instead of the constant", "the constant is unused (compile-time constant, javap)", "A shadow literal duplicates its own constant", "The jar is new in N5", "The class is absent from N4.", "The jar is not new in N5.",
	"Is the jar N5-only?", "The package is N5-only (4.15 baseline checked)", "Confirm whether the module is new in N5", "The feature was introduced in N5, but whether the API shipped earlier is open", "- API added in N5; PowerB too",
	"[CERT-hw] foo.dll is signed", "[CERT] libfoo.so.1 has 0x1000 and readelf plus objdump", "[CERT-live] PE32 binary " + strings.Repeat("ab", 32), "## 3.1 - [CERT] foo.dll is Authenticode-signed", "| x | [CERT-hw] ELF64 | VA 1234 `nm` strings |",
	"[CERT-doc] foo.dll is documented", "the javax.baja.sys package", "offset decade and r2 and R2", "## Child gaps opened", "## Closed child gaps", "### Child gaps (all closed)", "Child gaps opened", "**Child gaps opened**", "- Child gaps named:", "Child gaps\n---",
	"- B1-G1 gap 12. coverage-check: `grep x` -> 0 hits. measured-by: rg", "- B1-G2 gap. coverage-check: todo", "- B1-G3 12.5% of items. coverage-check: grep a -> b", "- (B1-G4) (medium) gap 4.15. coverage-check: q -> r.",
	"- B2-G1 gap", "  - coverage-check: grep a -> b", "  - measured-by: tool", "- B3-G1 text 3k. coverage-check: see odd/tasks/x.md for the state of T10", "- B3-G2 text. `coverage-check:` `x` found 3. measured-by: ",
	"## Evidence", "## Self-verify", "### Medium priority", "# Top", "<!-- lint-waive: R1 reason=ok -->", "<!-- lint-waive: R4 reason=ok -->", "<!-- lint-waive: R5 reason=ok -->", "<!-- lint-waive: R7 reason=ok -->",
	"<!-- lint-waive: R8 reason=ok -->", "<!-- lint-waive: R9 reason=ok -->", "<!-- lint-waive: R2 reason=ok -->", "<!-- lint-waive: R1 -->", "", "", "", "```", "~~~", "> ", "|---|---|",
}

func genPackDoc(r *rand.Rand) string {
	n := 3 + r.Intn(16)
	var b strings.Builder
	for i := 0; i < n; i++ {
		switch r.Intn(5) {
		case 0:
			b.WriteString(vocab[r.Intn(len(vocab))])
		case 1:
			b.WriteString(randText(r, []string{"", "- ", "> ", "| a | ", "## "}[r.Intn(5)]))
		default:
			b.WriteString(packVocab[r.Intn(len(packVocab))])
		}
		b.WriteByte('\n')
	}
	return b.String()
}

func TestLintPackDifferentialGeneratedDocuments(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	r := rand.New(rand.NewSource(20261102))
	var names []string
	for i := 0; i < 700; i++ {
		names = append(names, filepath.Base(write(t, dir, fmt.Sprintf("p%03d.md", i), genPackDoc(r))))
	}
	for _, cfg := range packConfigs {
		same(t, "generated audit "+strings.Join(cfg, " "), dir, withPack(cfg, append([]string{"--audit"}, names...)...)...)
	}
	same(t, "generated fail all", dir, withPack(packConfigs[4], names...)...)
	for _, f := range names[:25] {
		same(t, "generated single "+f, dir, withPack(packConfigs[4], f)...)
	}
}
