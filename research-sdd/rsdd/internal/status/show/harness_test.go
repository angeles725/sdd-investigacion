package show

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The scenario harness shared by the replay test (runs everywhere, kills mutants without the oracle) and the
// differential test (needs bash and the frozen script). A scenario is a file tree, a working directory and an
// argv; the probe tail below stands in for the sections that are not ported yet, in the same words on both sides.

const probeState = "# RESEARCH-STATE\n"

// scenario is one world and one invocation. Paths are relative to the world root; a trailing "/" is a directory.
type scenario struct {
	name       string
	files      map[string]string
	unreadable []string
	cwd        string
	args       []string // "{ROOT}" is replaced by the world root
	env        map[string]string
	needsUser  bool // the scenario depends on a mode-000 file being unreadable: skipped as root
}

type outcome struct {
	rc  int
	out string
	err string
}

type files = map[string]string

func (sc scenario) build(t testing.TB) string {
	t.Helper()
	root := t.TempDir()
	for p, body := range sc.files {
		full := filepath.Join(root, p)
		if strings.HasSuffix(p, "/") {
			must(t, os.MkdirAll(full, 0o755))
			continue
		}
		must(t, os.MkdirAll(filepath.Dir(full), 0o755))
		must(t, os.WriteFile(full, []byte(body), 0o644))
	}
	for _, p := range sc.unreadable {
		must(t, os.Chmod(filepath.Join(root, p), 0))
	}
	return root
}

func (sc scenario) argv(root string) []string {
	out := make([]string, len(sc.args))
	for i, a := range sc.args {
		out[i] = strings.ReplaceAll(a, "{ROOT}", root)
	}
	return out
}

func must(t testing.TB, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// probeTail is the stand-in for everything after the pick: the verdict (and exit code) the environment names, or a
// line that shows what the pick and the parser produced.
func probeTail(c *ctx) int {
	if c.s.Env("PROBE_SILENT") != "" {
		return 0
	}
	if v := c.s.Env("PROBE_VERDICT"); v != "" {
		fmt.Fprintf(c.s.Out, "%s\n", v)
		rc := 0
		if r := c.s.Env("PROBE_RC"); r != "" {
			fmt.Sscanf(r, "%d", &rc)
		}
		return rc
	}
	b := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}
	o := c.opts
	only := 0
	if o.onlySet {
		only = 1
	}
	mode := o.mode
	fmt.Fprintf(c.s.Out, "PICKED state=%s corpus=%s mode=%s focus=%s emit=%d all=%d queue=%d root=%d only=%s only_set=%d stall=%d\n",
		c.state, c.corpus, mode, o.focus, b(o.emitToken), b(o.all), b(o.queue), b(o.root), o.onlyList, only, o.stallMinutes)
	return 0
}

// probeTailBash is the same tail for the frozen excerpt, appended by the differential test.
const probeTailBash = `
if [ -n "${PROBE_SILENT:-}" ]; then exit 0; fi
if [ -n "${PROBE_VERDICT:-}" ]; then printf '%s\n' "$PROBE_VERDICT"; exit "${PROBE_RC:-0}"; fi
printf 'PICKED state=%s corpus=%s mode=%s focus=%s emit=%d all=%d queue=%d root=%d only=%s only_set=%d stall=%d\n' "$state" "$corpus" "$mode" "$focus_slug" "$emit_token" "$all_flag" "$queue_flag" "$root_flag" "$only_list" "$only_set" "$stall_minutes"
`

func runGo(t testing.TB, sc scenario, root string) outcome {
	t.Helper()
	var out, errb bytes.Buffer
	env := sc.env
	s := cli.Stdio{
		In:  strings.NewReader(""),
		Out: &out,
		Err: &errb,
		Env: func(k string) string { return env[k] },
		Clock: func() time.Time {
			return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
		},
		Cwd: filepath.Join(root, sc.cwd),
	}
	rc := run(sc.argv(root), s, probeTail)
	return outcome{rc, out.String(), errb.String()}
}

// render is the golden form of one outcome, with the world root scrubbed.
func render(name string, o outcome, root string) string {
	scrub := func(s string) string { return strings.ReplaceAll(s, root, "<ROOT>") }
	return fmt.Sprintf("=== %s\nrc: %d\n--- stdout\n%s--- stderr\n%s", name, o.rc, withNL(scrub(o.out)), withNL(scrub(o.err)))
}

// withNL ends a non-empty block with a newline so the next marker starts a line.
func withNL(s string) string {
	if s != "" && !strings.HasSuffix(s, "\n") {
		return s + "\n"
	}
	return s
}

// parseGolden splits a golden file into its sections by scenario name.
func parseGolden(t testing.TB, path string) map[string]string {
	t.Helper()
	b, err := os.ReadFile(path)
	must(t, err)
	out := map[string]string{}
	for _, sec := range strings.Split("\n"+string(b), "\n=== ")[1:] {
		name, _, _ := strings.Cut(sec, "\n")
		out[name] = "=== " + strings.TrimSuffix(sec, "\n") + "\n"
	}
	return out
}

// joinGolden is the file written by -update: sections in name order.
func joinGolden(sections map[string]string) string {
	names := make([]string, 0, len(sections))
	for n := range sections {
		names = append(names, n)
	}
	sort.Strings(names)
	var b strings.Builder
	for _, n := range names {
		b.WriteString(sections[n])
	}
	return b.String()
}

func skipIfRoot(t *testing.T, sc scenario) {
	t.Helper()
	if sc.needsUser && os.Geteuid() == 0 {
		t.Skip("mode-000 files are readable by root")
	}
}

const goldenArgsPick = "testdata/golden/args-pick.golden"

// TestReplayArgsPick replays the frozen oracle outputs through the Go code. The differential test asserts the
// same golden against the real script, so a mutant that changes behaviour dies here without bash.
func TestReplayArgsPick(t *testing.T) {
	golden := parseGolden(t, goldenArgsPick)
	scs := argsPickScenarios()
	if len(golden) != len(scs) {
		t.Fatalf("golden has %d scenarios, the table %d", len(golden), len(scs))
	}
	for _, sc := range scs {
		t.Run(sc.name, func(t *testing.T) {
			skipIfRoot(t, sc)
			want, ok := golden[sc.name]
			if !ok {
				t.Fatalf("no golden section for %s", sc.name)
			}
			root := sc.build(t)
			got := render(sc.name, runGo(t, sc, root), root)
			if got != want {
				t.Errorf("replay differs\nwant:\n%s\ngot:\n%s", want, got)
			}
		})
	}
}
