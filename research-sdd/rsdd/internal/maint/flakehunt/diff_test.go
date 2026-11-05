//go:build !nodiff

package flakehunt

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// updateGolden rewrites testdata/golden/scenarios.json from the frozen legacy script:
//
//	go test ./internal/maint/flakehunt -run TestFlakeHuntDifferential -update-golden
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden/scenarios.json from the legacy script")

// The differential test: every scenario builds a world, runs the frozen legacy kit-flake-hunt.sh (testdata/legacy)
// in one copy and the Go command in another, and the two must agree on exit code, stdout, stderr and every file the
// run leaves behind (results.tsv, logs, issue bodies, the gh and run-all recordings), root-normalised. A scenario
// marked `diverges` compares the exit code only: its Go output is pinned by divergence_test.go. Under -tags nodiff
// (the mutation run, which has no bash oracle) the same scenarios replay against the goldens this test records.
func TestFlakeHuntDifferential(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", "kit-flake-hunt.sh")
	golden := map[string]snapshot{}
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			wl, args, cwd := sc.build(t)
			l := kitworld.RunBash(t, cwd, wl.env, stage+"/kit-flake-hunt.sh", args...)
			legacy := wl.snap(ran{l.Out, l.Err, l.RC})
			wg, gargs, gcwd := sc.build(t)
			wg.cwd = gcwd
			g := wg.snap(wg.goRun(gargs...))
			golden[sc.name] = legacy
			if legacy.RC != sc.want || g.RC != sc.want {
				t.Fatalf("exit codes: legacy %d, go %d, scenario wants %d\nlegacy out=%q err=%q\ngo out=%q err=%q", legacy.RC, g.RC, sc.want, legacy.Out, legacy.Err, g.Out, g.Err)
			}
			if sc.diverges {
				return
			}
			if legacy.Out != g.Out {
				t.Errorf("stdout differs\n--- legacy\n%s\n--- go\n%s", legacy.Out, g.Out)
			}
			if legacy.Err != g.Err {
				t.Errorf("stderr differs\n--- legacy\n%s\n--- go\n%s", legacy.Err, g.Err)
			}
			if !reflect.DeepEqual(legacy.Files, g.Files) {
				t.Errorf("files differ:\n%s", filesDiff(legacy.Files, g.Files))
			}
			if strings.TrimSpace(legacy.Out+legacy.Err) == "" {
				t.Errorf("the oracle printed nothing: the comparison would prove nothing")
			}
		})
	}
	if *updateGolden {
		if err := os.WriteFile(goldenFile, goldenJSON(t, golden), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// goldenJSON is one scenario per line, names sorted: a reviewable file, not a thousand lines of indentation.
func goldenJSON(t *testing.T, golden map[string]snapshot) []byte {
	t.Helper()
	names := make([]string, 0, len(golden))
	for n := range golden {
		names = append(names, n)
	}
	sort.Strings(names)
	var b bytes.Buffer
	b.WriteString("{\n")
	for i, n := range names {
		key, _ := json.Marshal(n)
		val, err := json.Marshal(golden[n])
		if err != nil {
			t.Fatal(err)
		}
		b.Write(key)
		b.WriteString(": ")
		b.Write(val)
		if i < len(names)-1 {
			b.WriteString(",")
		}
		b.WriteString("\n")
	}
	b.WriteString("}\n")
	return b.Bytes()
}
