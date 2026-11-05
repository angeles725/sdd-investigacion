//go:build !nodiff

package fetchdoc

import (
	"encoding/json"
	"flag"
	"os"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// updateGolden rewrites testdata/golden/scenarios.json from the frozen legacy script:
//
//	go test ./internal/sources/fetchdoc -run TestFetchDocDifferential -update-golden
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden/scenarios.json from the legacy script")

// The differential test: every scenario builds a world twice (same files, same PATH of stubs), runs the frozen
// legacy fetch-doc.sh (testdata/legacy) in one and the Go command in the other, and the two must agree on exit
// status, stdout, stderr and the resulting file tree (target directory and TMPDIR, dates normalised), byte for
// byte. Under -tags nodiff (the mutation run, which has no bash oracle) golden_test.go replays the same scenarios
// against the answers this test recorded.
func TestFetchDocDifferential(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", "fetch-doc.sh")
	golden := map[string]goldenCase{}
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			wl, wg := newWorld(t, sc.stubs...), newWorld(t, sc.stubs...)
			for _, w := range []*world{wl, wg} {
				w.setEnv(sc.env...)
				if sc.setup != nil {
					sc.setup(w)
				}
			}
			l := kitworld.RunBash(t, wl.dir, wl.environ(), stage+"/fetch-doc.sh", sc.args(wl)...)
			legacy := ran{out: l.Out, err: l.Err, rc: l.RC, tree: wl.snapshot()}
			got := wg.goRun(sc.args(wg)...)
			lc := goldenCase{Out: wl.norm(legacy.out), Err: wl.norm(legacy.err), RC: legacy.rc, Tree: legacy.tree}
			gc := goldenCase{Out: wg.norm(got.out), Err: wg.norm(got.err), RC: got.rc, Tree: got.tree}
			if lc != gc {
				t.Errorf("legacy and Go differ\n--- legacy\nrc=%d\nstdout=%q\nstderr=%q\ntree:\n%s\n--- go\nrc=%d\nstdout=%q\nstderr=%q\ntree:\n%s",
					lc.RC, lc.Out, lc.Err, lc.Tree, gc.RC, gc.Out, gc.Err, gc.Tree)
			}
			golden[sc.name] = lc
		})
	}
	if *updateGolden {
		b, err := json.MarshalIndent(golden, "", " ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goldenFile, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
