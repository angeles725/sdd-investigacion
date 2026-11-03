package show

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The S3 harness: a world (files, symlinks, unreadable files), then one or more full invocations of
// `research-sdd-status.sh <target> --sync-state ...`. The rendering is the golden: every invocation's rc, stdout and
// stderr, then the tree the runs left behind (every file with its mode and bytes), because --sync-state is a writer
// and its write semantics (the atomic replace, the 0600 temp file the mv keeps, no leftover temp) are part of the
// contract.

const goldenS3 = goldenS2Dir + "s3.golden"

type s3Scenario struct {
	name       string
	files      map[string]string // relative to the world root; a trailing "/" is a directory
	links      map[string]string // link path -> target ("{ROOT}" is replaced)
	unreadable []string
	needsUser  bool // depends on a mode-000 file being unreadable: skipped as root
	cwd        string
	runs       [][]string // each is one argv; "{ROOT}" is replaced
}

// ss is the one-run scenario of the common shape: a corpus holding a RESEARCH-STATE.md and extra files.
func ss(name, state string, extra files, args ...string) s3Scenario {
	f := files{stateRel: state}
	for p, b := range extra {
		f[p] = b
	}
	if len(args) == 0 {
		args = []string{"--sync-state"}
	}
	return s3Scenario{name: name, files: f, runs: [][]string{append([]string{"{ROOT}/corpus"}, args...)}}
}

func (sc s3Scenario) build(t testing.TB) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	must(t, err)
	for p, body := range sc.files {
		full := filepath.Join(root, p)
		if strings.HasSuffix(p, "/") {
			must(t, os.MkdirAll(full, 0o755))
			continue
		}
		must(t, os.MkdirAll(filepath.Dir(full), 0o755))
		must(t, os.WriteFile(full, []byte(body), 0o644))
	}
	for l, target := range sc.links {
		full := filepath.Join(root, l)
		must(t, os.MkdirAll(filepath.Dir(full), 0o755))
		must(t, os.Symlink(strings.ReplaceAll(target, "{ROOT}", root), full))
	}
	for _, p := range sc.unreadable {
		must(t, os.Chmod(filepath.Join(root, p), 0))
	}
	return root
}

func (sc s3Scenario) argv(i int, root string) []string {
	out := make([]string, len(sc.runs[i]))
	for k, a := range sc.runs[i] {
		out[k] = strings.ReplaceAll(a, "{ROOT}", root)
	}
	return out
}

// s3Tail is the stand-in for every section after the sync: the same line on both sides.
func s3Tail(c *ctx) int {
	fmt.Fprintf(c.s.Out, "S3-TAIL mode=%s\n", c.opts.mode)
	return 0
}

const s3TailBash = `
printf 'S3-TAIL mode=%s\n' "$mode"
`

func runGoS3(t testing.TB, sc s3Scenario, root string) []outcome {
	t.Helper()
	var res []outcome
	for i := range sc.runs {
		var out, errb bytes.Buffer
		s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: func(string) string { return "" },
			Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: filepath.Join(root, sc.cwd)}
		rc := run(sc.argv(i, root), s, syncOr(s3Tail))
		res = append(res, outcome{rc, out.String(), errb.String()})
	}
	return res
}

// treeDump lists every entry under root: files with their permission bits and bytes, links with their target.
func treeDump(t testing.TB, root string) string {
	t.Helper()
	var paths []string
	must(t, filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p != root && !d.IsDir() {
			paths = append(paths, p)
		}
		return nil
	}))
	sort.Strings(paths)
	var b strings.Builder
	for _, p := range paths {
		rel, _ := filepath.Rel(root, p)
		st, err := os.Lstat(p)
		must(t, err)
		if st.Mode()&os.ModeSymlink != 0 {
			to, _ := os.Readlink(p)
			fmt.Fprintf(&b, "--- link %s -> %s\n", rel, strings.ReplaceAll(to, root, "<ROOT>"))
			continue
		}
		body, err := os.ReadFile(p)
		if err != nil { // mode-000 file: its bytes are not part of the oracle
			fmt.Fprintf(&b, "--- file %s mode=%04o (unreadable)\n", rel, st.Mode().Perm())
			continue
		}
		fmt.Fprintf(&b, "--- file %s mode=%04o\n%s", rel, st.Mode().Perm(), strings.ReplaceAll(withNL(string(body)), "\n=== ", "\n=\\== "))
	}
	return b.String()
}

// renderS3 is the golden section of one scenario.
func renderS3(t testing.TB, sc s3Scenario, outs []outcome, root string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "=== %s\n", sc.name)
	for i, o := range outs {
		fmt.Fprintf(&b, "run %d: %s\n", i+1, strings.Join(sc.argv(i, "<ROOT>"), " "))
		b.WriteString(render("", o, root)[len("=== \n"):])
	}
	// The end marker keeps a state file that ends in blank lines from losing them in the golden round trip.
	b.WriteString("--- tree\n" + strings.ReplaceAll(treeDump(t, root), root, "<ROOT>") + "--- end\n")
	return b.String()
}
