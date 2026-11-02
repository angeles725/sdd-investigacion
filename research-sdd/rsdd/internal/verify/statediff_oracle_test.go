//go:build unix && !nodiff

package verify

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The bash oracle half of the `rsdd verify state` differential. Everything that needs the frozen legacy script
// lives here, behind !nodiff, so the mutation run (TEETHTAGS=nodiff) does not re-execute bash per mutant; the
// Go-only half is replayed from testdata/state-goldens.json by TestStateGoldens (statecases_test.go).

// sdLegacy runs the frozen script in cwd.
func sdLegacy(t *testing.T, cwd string, args ...string) observed {
	t.Helper()
	cmd := exec.Command("bash", append([]string{filepath.Join(sdLegacyDir(t), "verify-state.sh")}, args...)...)
	cmd.Dir = cwd
	cmd.Env = sdEnviron(t.TempDir())
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("bash: %v", err)
		}
		rc = ee.ExitCode()
	}
	return observed{out.String(), errb.String(), rc}
}

// sdCompare runs both on the same arguments and reports any difference.
func sdCompare(t *testing.T, what, cwd string, args ...string) observed {
	t.Helper()
	want := sdNormalize(t, sdLegacy(t, cwd, args...))
	got := sdGo(t, cwd, true, args...)
	same(t, what, want, got)
	return want
}

// sdNormalize applies the intended differences to the legacy observation: bash names the script as it was
// invoked in its own error lines (the Go command prints "verify-state.sh"), and the "[: N: integer expression
// expected" errors of a test over an integer beyond int64 are not reproduced (the comparison is false in both).
func sdNormalize(t *testing.T, o observed) observed {
	t.Helper()
	script := filepath.Join(sdLegacyDir(t), "verify-state.sh")
	var keep []string
	for _, l := range strings.SplitAfter(o.stderr, "\n") {
		if strings.Contains(l, ": line ") && strings.HasSuffix(l, ": integer expression expected\n") {
			continue
		}
		keep = append(keep, strings.Replace(l, script+": line ", "verify-state.sh: line ", 1))
	}
	o.stderr = strings.Join(keep, "")
	return o
}

func TestDifferentialState(t *testing.T) {
	update := os.Getenv("RSDD_UPDATE_GOLDENS") != ""
	goldens := map[string]sdGolden{}
	if update {
		for k, v := range sdLoadGoldens(t) {
			goldens[k] = v
		}
	}
	frozen := map[string]sdGolden{}
	if !update {
		frozen = sdLoadGoldens(t)
	}
	ran := map[string]bool{}
	for _, c := range sdCases() {
		ran[c.name] = true
		t.Run(c.name, func(t *testing.T) {
			d, args := sdPrepare(t, c)
			want := sdCompare(t, c.name, d, args...)
			g := sdScrub(t, want, d)
			if update {
				goldens[c.name] = g
			} else if f, ok := frozen[c.name]; !ok || f != g {
				t.Errorf("%s: the oracle outcome differs from %s (regenerate with RSDD_UPDATE_GOLDENS=1):\nfrozen %+v\noracle %+v", c.name, sdGoldenFile, f, g)
			}
		})
	}
	if update {
		for k := range goldens {
			if !ran[k] {
				delete(goldens, k)
			}
		}
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		enc.SetIndent("", " ")
		if err := enc.Encode(goldens); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(sdGoldenFile, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
