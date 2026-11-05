//go:build !nodiff

package sizecheck

import (
	"encoding/json"
	"flag"
	"os"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// updateGolden rewrites testdata/golden/scenarios.json from the frozen legacy script:
//
//	go test ./internal/maint/sizecheck -run TestSizeCheckDifferential -update-golden
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden/scenarios.json from the legacy script")

// The differential test: every scenario builds a repository, runs the frozen legacy kit-size-check.sh
// (testdata/legacy) and run in it, and the two must agree on exit code, stdout and stderr, byte for byte. Under
// -tags nodiff (the mutation run, which has no bash oracle) the same scenarios replay against the goldens the oracle
// produced (golden_test.go).
func TestSizeCheckDifferential(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", "kit-size-check.sh")
	golden := map[string]goldenCase{}
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			rb := newRepo(t)
			sc.build(rb)
			l := kitworld.RunBash(t, rb.dir, rb.env, stage+"/kit-size-check.sh", sc.args...)
			rg := newRepo(t)
			sc.build(rg)
			g := rg.goRun(sc.args...)
			if l.RC != sc.want || g.rc != sc.want {
				t.Fatalf("exit codes: legacy %d, go %d, scenario wants %d\nlegacy out=%q err=%q\ngo out=%q err=%q", l.RC, g.rc, sc.want, l.Out, l.Err, g.out, g.err)
			}
			norm := func(s string, r *repo) string { return strings.ReplaceAll(s, r.dir, "<R>") }
			for _, d := range [][3]string{{"stdout", norm(l.Out, rb), norm(g.out, rg)}, {"stderr", norm(l.Err, rb), norm(g.err, rg)}} {
				if d[1] != d[2] {
					t.Errorf("%s differ\n--- legacy\n%s\n--- go\n%s", d[0], d[1], d[2])
				}
			}
			if strings.TrimSpace(l.Out) == "" {
				t.Errorf("the oracle printed nothing: the comparison would prove nothing")
			}
			golden[sc.name] = goldenCase{Out: norm(l.Out, rb), Err: norm(l.Err, rb), RC: l.RC}
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
