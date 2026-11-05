//go:build !nodiff

package writercheck

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
//	go test ./internal/maint/writercheck -run TestWriterCheckDifferential -update-golden
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden/scenarios.json from the legacy script")

const legacyName = "kit-writer-check.sh"

// legacy runs the frozen bash script (staged below dir) in the clone's world.
func legacy(k *kase, stage string, sc scenario) ran {
	r := kitworld.RunBash(k.t, k.root, append(append([]string(nil), k.env...), k.envFor(sc)...), stage+"/"+legacyName, sc.args(k)...)
	return ran{r.Out, r.Err, r.RC}
}

func init() {
	// The binding header of a clone as the legacy script prints it (what a log written by it starts with).
	headerOf = func(k *kase, worktree bool) string {
		stage := kitworld.Stage(k.t, "testdata/legacy", legacyName)
		args := []string{"--repo", k.dir, "--base", "base", "--print-binding"}
		if worktree {
			args = append(args, "--worktree")
		}
		r := kitworld.RunBash(k.t, k.root, k.env, stage+"/"+legacyName, args...)
		if r.RC != 0 {
			k.t.Fatalf("legacy --print-binding: rc %d: %s", r.RC, r.Err)
		}
		return strings.TrimSuffix(r.Out, "\n")
	}
}

// The differential test: every scenario builds two identical clones, runs the frozen legacy script (testdata/legacy)
// on one and the Go command on the other, and the two must agree on exit code, stdout and stderr, byte for byte.
// Under -tags nodiff (the mutation run, which has no bash oracle) the same scenarios replay against the goldens this
// test records (golden_test.go).
func TestWriterCheckDifferential(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", legacyName)
	golden := map[string]goldenCase{}
	for _, sc := range allScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			kl, kg := newKase(t), newKase(t)
			sc.build(kl)
			sc.build(kg)
			l := legacy(kl, stage, sc)
			g := kg.goRun(kg.envFor(sc), sc.args(kg)...)
			if l.rc != sc.want || g.rc != sc.want {
				t.Fatalf("exit codes: legacy %d, go %d, scenario wants %d\nlegacy out=%q err=%q\ngo out=%q err=%q", l.rc, g.rc, sc.want, l.out, l.err, g.out, g.err)
			}
			for _, d := range [][3]string{{"stdout", kl.norm(l.out), kg.norm(g.out)}, {"stderr", kl.norm(l.err), kg.norm(g.err)}} {
				if d[1] != d[2] {
					t.Errorf("%s differ\n--- legacy\n%s\n--- go\n%s", d[0], d[1], d[2])
				}
			}
			if strings.TrimSpace(l.out+l.err) == "" {
				t.Errorf("the oracle printed nothing: the comparison would prove nothing")
			}
			golden[sc.name] = goldenCase{Out: kl.norm(l.out), Err: kl.norm(l.err), RC: l.rc}
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
