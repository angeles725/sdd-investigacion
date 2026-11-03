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

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/observed"
)

// The bash oracle half of the `rsdd verify state` differential. Everything that needs the frozen legacy script
// lives here, behind !nodiff, so the mutation run (TEETHTAGS=nodiff) does not re-execute bash per mutant; the
// Go-only half is replayed from testdata/state-goldens.json by TestStateGoldens (statecases_test.go).

// sdLegacy runs the frozen script in cwd.
func sdLegacy(t *testing.T, cwd string, args ...string) observed.Run {
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
	return observed.New(out.String(), errb.String(), rc)
}

// sdCompare runs both on the same arguments and reports any difference.
func sdCompare(t *testing.T, what, cwd string, args ...string) observed.Run {
	t.Helper()
	want := sdNormalize(t, sdLegacy(t, cwd, args...))
	got := sdGo(t, cwd, true, args...)
	want.Stdout = sdAlignSections(want.Stdout, got.Stdout)
	observed.Same(t, what, want, got)
	return want
}

// sdNormalize applies the intended differences to the legacy observation: bash names the script as it was
// invoked in its own error lines (the Go command prints "verify-state.sh"), and the "[: N: integer expression
// expected" errors of a test over an integer beyond int64 are not reproduced (the comparison is false in both).
func sdNormalize(t *testing.T, o observed.Run) observed.Run {
	t.Helper()
	script := filepath.Join(sdLegacyDir(t), "verify-state.sh")
	var keep []string
	for _, l := range strings.SplitAfter(o.Stderr, "\n") {
		if strings.Contains(l, ": line ") && strings.HasSuffix(l, ": integer expression expected\n") {
			continue
		}
		keep = append(keep, strings.Replace(l, script+": line ", "verify-state.sh: line ", 1))
	}
	o.Stderr = strings.Join(keep, "")
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

// sdSections splits a report into the lines before the first "== verify-state: " header, one block per header,
// and the "== exit N ==" trailer the multi-state run prints after the last block.
func sdSections(out string) (head string, secs []string, tail string) {
	const mark, exit = "== verify-state: ", "\n== exit "
	i := strings.Index(out, mark)
	if i < 0 || (i > 0 && out[i-1] != '\n') {
		return out, nil, ""
	}
	head, rest := out[:i], out[i:]
	for rest != "" {
		j := strings.Index(rest[len(mark):], "\n"+mark)
		if j < 0 {
			if k := strings.LastIndex(rest, exit); k >= 0 {
				rest, tail = rest[:k+1], rest[k+1:]
			}
			secs = append(secs, rest)
			break
		}
		secs = append(secs, rest[:len(mark)+j+1])
		rest = rest[len(mark)+j+1:]
	}
	return head, secs, tail
}

// sdAlignSections puts the oracle's per-state sections in the Go command's order when the two reports hold the
// same sections in a different order, and returns the oracle report unchanged otherwise. The bash oracle prints
// states in find's readdir order, which depends on the filesystem (#2477: the GitHub runner and a local ext4
// disagreed); the Go command walks each directory in byte order. Only a permutation is forgiven: any section that
// differs in content or count, or a different head or trailer, still fails the comparison, and
// TestFindStatesByteOrder pins the Go order itself.
func sdAlignSections(oracle, goOut string) string {
	oh, osecs, ot := sdSections(oracle)
	gh, gs, gt := sdSections(goOut)
	if oh != gh || ot != gt || len(osecs) != len(gs) || len(osecs) < 2 {
		return oracle
	}
	pool := map[string]int{}
	for _, s := range osecs {
		pool[s]++
	}
	for _, s := range gs {
		if pool[s] == 0 {
			return oracle
		}
		pool[s]--
	}
	return goOut
}

func TestAlignSections(t *testing.T) {
	const h = "   INFO x\n"
	a := "== verify-state: A.md (target: d) ==\n   ok a\n"
	b := "== verify-state: B.md (target: d) ==\n   FAIL b\n"
	c := "== verify-state: C.md (target: d) ==\n   ok c\n"
	const tl = "== exit 1 ==\n"
	for _, tc := range []struct{ name, oracle, goOut, want string }{
		{"permutation aligned", h + b + a + c + tl, h + a + b + c + tl, h + a + b + c + tl},
		{"permutation without trailer", h + b + a, h + a + b, h + a + b},
		{"content differs", h + b + a + tl, h + a + c + tl, h + b + a + tl},
		{"count differs", h + b + a + a + tl, h + a + b + tl, h + b + a + a + tl},
		{"duplicate multiset differs", h + a + a + b, h + a + b + b, h + a + a + b},
		{"head differs", "   INFO y\n" + b + a, h + a + b, "   INFO y\n" + b + a},
		{"trailer differs", h + b + a + "== exit 0 ==\n", h + a + b + tl, h + b + a + "== exit 0 ==\n"},
		{"single section untouched", h + a, h + a, h + a},
		{"no sections", "plain\n", "other\n", "plain\n"},
	} {
		if got := sdAlignSections(tc.oracle, tc.goOut); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}
