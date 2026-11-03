//go:build linux

package formats

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// zipToolbelt is the frozen oracle copy (core consolidation, #2561) of analysis_manifest.py, which the --manifest-cli argument names (the commands build the manifest in
// process; the path is an argument value only and is never executed here).
const zipToolbelt = "../core/adapter/testdata/frozen"

var fakeNow = time.Date(2026, 1, 2, 3, 4, 5, 678901000, time.UTC)

// runGo runs one of the commands in process, as `rsdd formats <name>` would.
func runGo(t testing.TB, fn func([]string, cli.Stdio) int, cwd string, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env:     os.Getenv,
		Environ: os.Environ,
		Clock:   func() time.Time { return fakeNow },
		Cwd:     cwd,
	}
	code = fn(args, s)
	return code, out.String(), errb.String()
}

func zipManifestCLI(t testing.TB) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join(zipToolbelt, "analysis_manifest.py"))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func metaArgs(t testing.TB, in, out string, extra ...string) []string {
	return append([]string{"--input", in, "--output", out, "--manifest-cli", zipManifestCLI(t)}, extra...)
}

func storedArgs(t testing.TB, in, out string, extra ...string) []string {
	return append([]string{"--input", in, "--output", out, "--manifest-cli", zipManifestCLI(t)}, extra...)
}

// tree lists every path under root with its mode, and every regular file's bytes.
type zipTreeEntry struct {
	mode fs.FileMode
	data string
}

func readTree(t testing.TB, root string) map[string]zipTreeEntry {
	t.Helper()
	out := map[string]zipTreeEntry{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == root {
			return err
		}
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		e := zipTreeEntry{mode: fi.Mode()}
		if fi.Mode().IsRegular() {
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			e.data = string(b)
		}
		out[rel] = e
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func treeNames(m map[string]zipTreeEntry) []string {
	var names []string
	for k := range m {
		names = append(names, k)
	}
	sort.Strings(names)
	return names
}

func manifestOf(t testing.TB, tree string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(tree, "analysis-manifest.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func assertNoLeftovers(t testing.TB, dir string, names ...string) {
	t.Helper()
	for _, n := range names {
		for _, p := range []string{filepath.Join(dir, n), filepath.Join(dir, "."+n+".stage")} {
			if _, err := os.Lstat(p); err == nil {
				t.Errorf("%s exists after a failed run", p)
			}
		}
	}
}

// cmdCase is one archive run through both implementations.
type cmdCase struct {
	name  string
	extra []string
}

func itoa(i int) string { return strconv.Itoa(i) }
