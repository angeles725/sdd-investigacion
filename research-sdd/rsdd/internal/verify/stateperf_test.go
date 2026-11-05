//go:build unix

package verify

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// The pre-filters of kit issue #2645 may only drop lines their regexp could not match.
func TestMayContainFoldNeverDropsAMatch(t *testing.T) {
	t.Parallel()
	re := regexp.MustCompile(`(?i)gaps? closed|coverage metric`)
	for _, l := range []string{
		"", "plain", "Gaps CLOSED: 3", "gap closed", "COVERAGE METRIC: 1/2", "cloſed gaps cloſed", "gap cloSed",
		"gaps closeD", "Coverage Metric", "cobertura cerrada", "ñandú gaps closed", "gapsK closed", "gaps ĸlosed",
	} {
		if re.MatchString(l) && !mayContainFold(l, "closed", "coverage metric") {
			t.Errorf("mayContainFold dropped %q, which the regexp matches", l)
		}
	}
}

func TestCountBlocksPrefixFilterMatchesPlainFilter(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	for _, n := range []string{"a-block1.md", "a-bloque2-x.md", "b-block1.md", "ab-block3.md", "notes.md", "a-block.md", "xa-block9.md"} {
		if err := os.WriteFile(filepath.Join(dir, n), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, prefix := range []string{"", "a-", "b-", "z-", "a.", "(a|b)-"} {
		v := &verifier{fs: fsView{}}
		fast := v.countBlocks(dir, prefix)
		out, _ := kit.FilterBlockFiles(v.mdLines(dir), false, prefix)
		if want := fmt.Sprint(len(out)); fast != want {
			t.Errorf("prefix %q: filtered count %s, plain filter %s", prefix, fast, want)
		}
	}
}

// BenchmarkRunStateCorpus times `rsdd verify state` over a real corpus (kit issue #2645). It asserts nothing about
// time: the corpus is $RSDD_BENCH_STATE_DIR, else $HOME/niagara-research, and the benchmark skips when it is absent.
// Profile with: go test -run '^$' -bench RunStateCorpus -cpuprofile cpu.out ./internal/verify/
func BenchmarkRunStateCorpus(b *testing.B) {
	dir := os.Getenv("RSDD_BENCH_STATE_DIR")
	if dir == "" {
		dir = filepath.Join(os.Getenv("HOME"), "niagara-research")
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		b.Skipf("corpus %s is absent", dir)
	}
	toolbelt := kitroot.Path(b, "toolbelt")
	env := append(os.Environ(), "RSDD_TOOLBELT_DIR="+toolbelt)
	get := func(k string) string {
		for i := len(env) - 1; i >= 0; i-- {
			if v, ok := strings.CutPrefix(env[i], k+"="); ok {
				return v
			}
		}
		return ""
	}
	cwd, _ := os.Getwd()
	s := cli.Stdio{Out: io.Discard, Err: io.Discard, Env: get, Environ: func() []string { return env }, Clock: time.Now, Cwd: cwd}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		RunState([]string{dir}, s)
	}
}
