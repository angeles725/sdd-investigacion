//go:build unix && !nodiff

package console

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// updateGolden rewrites testdata/recorded/scenarios.json from the frozen legacy script:
//
//	go test ./internal/serial/console -run TestDifferential -update-golden
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/recorded/scenarios.json from the legacy script")

// TestDifferential runs every scenario in two identical worlds, the frozen serial-console.sh (testdata/legacy) in
// one and the Go command in the other, and requires the same stdout, stderr, exit code and file tree, byte for
// byte (timestamps and the world directory aside). The legacy answers are recorded so replay_test.go can check
// the Go command where there is no bash oracle (-tags nodiff). A missing bash FAILS: a skipped differential
// proves nothing.
func TestDifferential(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", "serial-console.sh")
	recorded := map[string]ran{}
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			if sc.needsUser && os.Geteuid() == 0 {
				t.Skip("root ignores the permission bits this scenario relies on")
			}
			if strings.Contains(strings.Join(sc.env, " "), "UTF-8") && !hasUTF8Locale() {
				t.Skip("the host has no C.UTF-8 locale, so the legacy tools would answer in C")
			}
			wl, wg := newWorld(t), newWorld(t)
			sc.prepare(wl)
			sc.prepare(wg)
			legacy := wl.norm(wl.legacyRun(stage+"/serial-console.sh", sc), sc, true)
			got := wg.norm(wg.goRun(sc), sc, false)
			recorded[sc.name] = legacy
			want := legacy
			if sc.intended != nil {
				want = *sc.intended
				want.Tree = legacy.Tree
				if got == legacy {
					t.Errorf("intended divergence did not diverge: the Go command still equals the legacy script")
				}
			}
			if got != want {
				t.Errorf("legacy and Go differ\n--- want\nrc=%d\nstdout=%q\nstderr=%q\ntree:\n%s\n--- go\nrc=%d\nstdout=%q\nstderr=%q\ntree:\n%s",
					want.RC, want.Out, want.Err, want.Tree, got.RC, got.Out, got.Err, got.Tree)
			}
		})
	}
	if *updateGolden {
		b, err := json.MarshalIndent(recorded, "", " ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goldenFile, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// legacyRun runs the frozen script under bash in this world.
func (w *world) legacyRun(script string, sc *scenario) ran {
	w.t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		w.t.Fatalf("the differential needs bash: %v", err)
	}
	c := exec.Command(bash, append([]string{script}, w.subAll(sc.args)...)...)
	c.Dir, c.Env = w.dir, w.environ(sc.env)
	c.Stdin = strings.NewReader(sc.stdin)
	var o, e bytes.Buffer
	c.Stdout, c.Stderr = &o, &e
	rc := 0
	if err := c.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			w.t.Fatalf("cannot run the legacy script: %v", err)
		}
		rc = ee.ExitCode()
	}
	return ran{o.String(), e.String(), rc, w.tree()}
}

func hasUTF8Locale() bool {
	out, err := exec.Command("locale", "-a").Output()
	if err != nil {
		return false
	}
	s := strings.ToLower(string(out))
	return strings.Contains(s, "c.utf8") || strings.Contains(s, "c.utf-8")
}
