//go:build !nodiff && unix

package corrections

import (
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestDiscoveryMatchesLegacyDiscriminator: the block files the Go port consults are exactly what the frozen
// `find ... | block_file_filter | sort` of the script selected, decoys and depth limit included.
func TestDiscoveryMatchesLegacyDiscriminator(t *testing.T) {
	m := map[string]string{}
	for _, n := range []string{
		"tema3-block1.md", "tema3-block2.md", "pref-bloque5.md", "ab-block10-extra.md", "retros/sub-block3.md", "a/b/c-block4.md", "a/b/c/d-block5.md",
		"x-bloque3.md", "blocked-notes.md", "block12.md", "bloque4.md", "index.md", "CATALOG.md", "t-block1.template.md", "t-block1.md.bak",
		".git/g-block1.md", "a/.git/g-block2.md", "q-block7-Slug_9.md", "q-block7-sl.ug.md", "Q-BLOCK7.md", "z-block-3.md",
	} {
		m[n] = "x\n"
	}
	dir := corpus(t, m)
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("differential: bash not found: %v", err)
	}
	lib, _ := filepath.Abs(filepath.Join("testdata", "legacy", "lib", "block-files.sh"))
	cmd := exec.Command(bash, "-c", `. "$1" && find "$2" -maxdepth 3 -type f -name '*.md' -not -name '*.template.md' -not -path '*/.git/*' | block_file_filter | LC_ALL=C sort`, "_", lib, dir)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("legacy discovery: %v", err)
	}
	want := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	got, derrs := listBlocks(dir, os.ReadDir)
	if len(derrs) != 0 {
		t.Fatalf("discovery errors: %v", derrs)
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") || len(got) < 6 {
		t.Errorf("block files differ\n got: %v\nwant: %v", got, want)
	}
}

// TestGeneratorExercisesEveryOutcome guards the differential corpus against drifting into a narrow set of
// shapes: across the seeds every report line kind and every typed ambiguity must occur, so a rule that stopped
// being generated is a failure, not a silently green differential.
func TestGeneratorExercisesEveryOutcome(t *testing.T) {
	want := map[string]*regexp.Regexp{}
	for _, k := range []string{`^   FAIL   `, `^   WARN   B\d+ declares a correction of \[Block \d+\] but no block-\d+ file exists on disk`, `no block-\d+ file exists in its prefix '[^']+' and the number is ambiguous`,
		`AMBIG  .*the verb governs a non-block object`, `AMBIG  .*locator reference`, `AMBIG  .*reader-assumption`, `AMBIG  .*possessive 'corrigendum of`, `AMBIG  .*joined-list reference`,
		`AMBIG  .*bare B\d+ reference`, `AMBIG  .*joined to a leading bare`, `AMBIG  .*cross-focus qualifier`, `hint: the backticked token`, `of focus .* but no block-\d+ file exists in its prefix`,
		`note   \d+ correction verb\(s\) governed no`, `note   \d+ correction verb\(s\) were negated`, `note   \d+ correction verb\(s\) in a non-assertive form`, `ok-partial`} {
		want[k] = regexp.MustCompile(`(?m)` + k)
	}
	seen := map[string]bool{}
	for seed := 1; seed <= 40; seed++ {
		o := runGo(corpus(t, genCorpus(rand.New(rand.NewSource(int64(seed))))))
		for k, re := range want {
			if re.MatchString(o.stdout) {
				seen[k] = true
			}
		}
	}
	for k := range want {
		if !seen[k] {
			t.Errorf("no generated corpus produced /%s/", k)
		}
	}
}
