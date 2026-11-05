//go:build unix && !nodiff

package secretscan

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/parity"
)

// The differential: the frozen scan-secrets.sh (testdata/legacy: the bytes of the script before the port; the live
// one is a shim now) runs beside the Go engine in the same world over every case in allCases. Stdout, stderr and the
// exit code must be equal, except for a divergence the case declares (and the declaration must still diverge).
// A missing bash or git FAILS: a skipped differential proves nothing. The oracle reads the local grep, awk and sort,
// so the world runs under LC_ALL=C.

var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden/cases.json: the legacy output, or the Go output for a declared divergence")

func (w *world) runLegacy(t testing.TB) obs {
	t.Helper()
	src, err := os.ReadFile("testdata/legacy/scan-secrets.sh")
	if err != nil {
		t.Fatal(err)
	}
	tb := filepath.Join(w.scratch, "toolbelt")
	if err := os.MkdirAll(tb, 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(tb, "scan-secrets.sh")
	if err := os.WriteFile(script, src, 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", append([]string{script}, w.argv()...)...)
	cmd.Dir, cmd.Env = w.scratch, w.env
	if w.c.stdin {
		cmd.Stdin = bytes.NewReader(w.listBytes())
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err = cmd.Run()
	code := 0
	var ee *exec.ExitError
	switch {
	case errors.As(err, &ee):
		code = ee.ExitCode()
	case err != nil:
		t.Fatalf("legacy script did not run: %v", err)
	}
	return obs{w.norm(out.String()), w.norm(errb.String()), code}
}

func requireTools(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"bash", "git", "grep", "awk"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatalf("the differential needs %s on PATH: %v", tool, err)
		}
	}
}

func asObserved(o obs) parity.Observed {
	return parity.Observed{Stdout: []byte(o.stdout), Stderr: []byte(o.stderr), Exit: o.exit}
}

func TestDifferentialAgainstLegacy(t *testing.T) {
	requireTools(t)
	cases := allCases()
	golden := map[string]goldenEntry{}
	var mu = make(chan struct{}, 1)
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t, c)
			raw := w.runGo(t)
			legacy, got := canon(w.c, w.runLegacy(t)), canon(w.c, raw)
			var declared []parity.Intended
			for _, d := range c.intended {
				if d.reason == "" {
					t.Fatalf("declared divergence %q has no reason", d.field)
				}
				declared = append(declared, parity.Intended{Field: d.field, Reason: d.reason})
			}
			if _, problems := parity.Judge(asObserved(legacy), asObserved(got), declared); len(problems) > 0 {
				for _, p := range problems {
					t.Error(p)
				}
			}
			frozen := legacy
			if len(c.intended) > 0 || w.c.unordered {
				frozen = raw // a declared divergence, or an order the legacy script leaves to readdir: pin the engine's output
			}
			mu <- struct{}{}
			golden[c.name] = goldenEntry{frozen.stdout, frozen.stderr, frozen.exit}
			<-mu
		})
	}
	if *updateGolden {
		b, err := json.MarshalIndent(golden, "", " ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goldenPath, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
