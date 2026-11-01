//go:build unix

package verify

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Golden test of `rsdd verify block`: every case of blockCases() is built in a fresh directory, run through the
// Go command, and compared with the recorded output of the frozen legacy script (testdata/block/legacy, the
// bytes of verify-block.sh and its two libs before the port). testdata/block/golden.json is that record; the
// differential test (block_diff_test.go) re-runs the legacy script and fails when the record is stale, so the
// golden proves the same thing the differential does, without bash, and survives `-tags nodiff`
// (mutation runs).

// blockCase is one invocation: files are created under the case root (relative paths), args are passed as
// written (relative to the root, which is the working directory), env is added to the fixed environment.
type blockCase struct {
	name  string
	files map[string]string
	args  []string
	env   map[string]string
	setup func(t testing.TB, root string) // optional: symlinks, modes, git
}

type blockRecord struct {
	RC             int
	Stdout, Stderr string
}

const blockGoldenPath = "testdata/block/golden.txt"

// blockWorld builds the case root and returns it with the environment both implementations run in.
func blockWorld(t testing.TB, c blockCase) (root string, env map[string]string, args []string) {
	t.Helper()
	root = filepath.Join(t.TempDir(), "r")
	if err := os.MkdirAll(filepath.Join(root, "home"), 0o755); err != nil {
		t.Fatal(err)
	}
	for p, body := range c.files {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(strings.ReplaceAll(body, "{ROOT}", root)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if c.setup != nil {
		c.setup(t, root)
	}
	env = map[string]string{
		"PATH": os.Getenv("PATH"), "HOME": filepath.Join(root, "home"), "LC_ALL": "C.UTF-8",
		"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
	}
	for k, v := range c.env {
		env[k] = strings.ReplaceAll(v, "{ROOT}", root)
	}
	for _, a := range c.args {
		args = append(args, strings.ReplaceAll(a, "{ROOT}", root))
	}
	return root, env, args
}

// normalize replaces the case root (and its symlink-resolved form) by <ROOT>, so a recorded output does not
// depend on the temporary directory.
func normalize(root, s string) string {
	if real, err := filepath.EvalSymlinks(root); err == nil && real != root {
		s = strings.ReplaceAll(s, real, "<ROOT>")
	}
	return strings.ReplaceAll(s, root, "<ROOT>")
}

func runBlockGo(t testing.TB, c blockCase) blockRecord {
	t.Helper()
	root, env, args := blockWorld(t, c)
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env: func(k string) string { return env[k] },
		Environ: func() []string {
			var e []string
			for k, v := range env {
				e = append(e, k+"="+v)
			}
			return e
		},
		Clock: func() time.Time { return time.Unix(0, 0) },
		Cwd:   root,
	}
	rc := cli.Run(Commands, append([]string{"verify", "block"}, args...), s)
	return blockRecord{rc, normalize(root, out.String()), normalize(root, errb.String())}
}

func loadBlockGolden(t testing.TB) map[string]blockRecord {
	t.Helper()
	raw, err := os.ReadFile(blockGoldenPath)
	if err != nil {
		t.Fatalf("golden record missing (record it with RSDD_BLOCK_RECORD=1 go test -run TestBlockDifferential): %v", err)
	}
	g := map[string]blockRecord{}
	for i, line := range strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n") {
		f := strings.Split(line, "\t")
		if len(f) != 4 {
			t.Fatalf("%s:%d: want 4 tab-separated fields, got %d", blockGoldenPath, i+1, len(f))
		}
		name, err1 := strconv.Unquote(f[0])
		rc, err2 := strconv.Atoi(f[1])
		out, err3 := strconv.Unquote(f[2])
		errs, err4 := strconv.Unquote(f[3])
		if err := errors.Join(err1, err2, err3, err4); err != nil {
			t.Fatalf("%s:%d: %v", blockGoldenPath, i+1, err)
		}
		g[name] = blockRecord{rc, out, errs}
	}
	return g
}

// writeBlockGolden records one case per line: quoted name, exit code, quoted stdout, quoted stderr. Go quoting
// keeps bytes that are not valid UTF-8 (cut -c counts bytes), which JSON cannot.
func writeBlockGolden(t testing.TB, g map[string]blockRecord) {
	t.Helper()
	names := make([]string, 0, len(g))
	for n := range g {
		names = append(names, n)
	}
	sort.Strings(names)
	var b bytes.Buffer
	for _, n := range names {
		r := g[n]
		fmt.Fprintf(&b, "%s\t%d\t%s\t%s\n", strconv.Quote(n), r.RC, strconv.Quote(r.Stdout), strconv.Quote(r.Stderr))
	}
	if err := os.WriteFile(blockGoldenPath, b.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestBlockGolden(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Fatalf("git is required (a skipped golden proves nothing): %v", err)
	}
	g := loadBlockGolden(t)
	cases := blockCases()
	seen := map[string]bool{}
	only := os.Getenv("RSDD_BLOCK_ONLY") // development filter: run the cases whose name contains it
	for _, c := range cases {
		if only != "" && !strings.Contains(c.name, only) {
			continue
		}
		if seen[c.name] {
			t.Fatalf("duplicate case name %q", c.name)
		}
		seen[c.name] = true
		want, ok := g[c.name]
		if !ok {
			t.Errorf("%s: no golden record", c.name)
			continue
		}
		got := runBlockGo(t, c)
		if got != want {
			t.Errorf("%s differs from the recorded legacy output\nlegacy rc=%d\n%s\n--- stderr: %q\n     go rc=%d\n%s\n--- stderr: %q",
				c.name, want.RC, want.Stdout, want.Stderr, got.RC, got.Stdout, got.Stderr)
		}
	}
	for n := range g {
		if only == "" && !seen[n] {
			t.Errorf("golden record %q has no case (stale record)", n)
		}
	}
}
