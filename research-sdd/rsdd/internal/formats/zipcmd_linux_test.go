//go:build linux

package formats

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

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

// legacy runs the real Python tool. A missing python3 fails the test.
func legacy(t testing.TB, script string, args ...string) (code int, stderr string) {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests: %v", err)
	}
	tb, err := filepath.Abs(zipToolbelt)
	if err != nil {
		t.Fatal(err)
	}
	argv := append([]string{filepath.Join(tb, script)}, args...)
	cmd := exec.Command(py, argv...)
	cmd.Dir = tb
	var errb bytes.Buffer
	cmd.Stderr = &errb
	err = cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		return 0, errb.String()
	case errors.As(err, &ee):
		return ee.ExitCode(), errb.String()
	}
	t.Fatalf("cannot run %s: %v", script, err)
	return -1, ""
}

func manifestCLI(t testing.TB) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join(zipToolbelt, "analysis_manifest.py"))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func metaArgs(t testing.TB, in, out string, extra ...string) []string {
	return append([]string{"--input", in, "--output", out, "--manifest-cli", manifestCLI(t)}, extra...)
}

func storedArgs(t testing.TB, in, out string, extra ...string) []string {
	return append([]string{"--input", in, "--output", out, "--manifest-cli", manifestCLI(t)}, extra...)
}

func legacyStoredArgs(t testing.TB, in, out string, extra ...string) []string {
	tb, _ := filepath.Abs(zipToolbelt)
	return append(storedArgs(t, in, out, extra...), "--metadata-parser", filepath.Join(tb, "zip_metadata.py"))
}

// tree lists every path under root with its mode, and every regular file's bytes.
type treeEntry struct {
	mode fs.FileMode
	data string
}

func readTree(t testing.TB, root string) map[string]treeEntry {
	t.Helper()
	out := map[string]treeEntry{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == root {
			return err
		}
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		e := treeEntry{mode: fi.Mode()}
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

func treeNames(m map[string]treeEntry) []string {
	var names []string
	for k := range m {
		names = append(names, k)
	}
	sort.Strings(names)
	return names
}

// verifyManifest runs the legacy `analysis_manifest.py verify` over a published tree.
func verifyManifest(t testing.TB, tree string) {
	t.Helper()
	code, stderr := legacy(t, "analysis_manifest.py", "verify", "--root", tree, filepath.Join(tree, "analysis-manifest.v1.json"))
	if code != 0 {
		t.Fatalf("analysis manifest of %s does not verify (exit %d): %s", tree, code, stderr)
	}
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

// sameManifestFacts compares the manifest fields that describe WHAT was produced; the tool, argv and run
// stamp describe how it was launched and are expected to differ (documented in the contracts).
func sameManifestFacts(t testing.TB, legacyTree, goTree string) {
	t.Helper()
	a, b := manifestOf(t, legacyTree), manifestOf(t, goTree)
	for _, k := range []string{"schema_version", "input", "stdout", "stderr", "outputs", "findings", "limitations", "errors", "completeness", "isolation_profile"} {
		x, _ := json.Marshal(a[k])
		y, _ := json.Marshal(b[k])
		if string(x) != string(y) {
			t.Errorf("manifest field %q differs\n legacy: %s\n Go:     %s", k, x, y)
		}
	}
	run := b["run"].(map[string]any)
	if run["started_at"] != "2026-01-02T03:04:05.678901Z" || run["ended_at"] != run["started_at"] {
		t.Errorf("manifest run stamp = %v, want the injected clock", run)
	}
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

func TestZipMetadataCommandParity(t *testing.T) {
	work := t.TempDir()
	in := t.TempDir()
	paths := writeFixtures(t, in, metaFixtures())
	cases := []cmdCase{
		{name: "empty.zip"}, {name: "mixed.zip"}, {name: "comment.zip"}, {name: "prefix.zip"}, {name: "utf8.zip"},
		{name: "truncated.zip"}, {name: "malformed.zip"}, {name: "multi.zip"}, {name: "zip64.zip"},
		{name: "mixed.zip", extra: []string{"--max-central-directory-bytes", "10"}},
		{name: "mixed.zip", extra: []string{"--max-entries", "2"}},
		{name: "mixed.zip", extra: []string{"--max-input-bytes", "4"}},
		{name: "mixed.zip", extra: []string{"--max-field-bytes", "3"}},
		{name: "mixed.zip", extra: []string{"--max-report-bytes", "100"}},
		{name: "mixed.zip", extra: []string{"--max-report-bytes", "0"}},
		{name: "mixed.zip", extra: []string{"--max-entries", "-3"}},
	}
	var accepted atomic.Int32
	t.Run("cases", func(t *testing.T) {
		for i, c := range cases {
			i, c := i, c
			t.Run(c.name+" "+strings.Join(c.extra, " "), func(t *testing.T) {
				t.Parallel()
				lo, mo := filepath.Join(work, "legacy-"+itoa(i)), filepath.Join(work, "go-"+itoa(i))
				lcode, lerr := legacy(t, "zip_metadata.py", metaArgs(t, paths[c.name], lo, c.extra...)...)
				gcode, gout, gerr := runGo(t, ZipMetadata, work, metaArgs(t, paths[c.name], mo, c.extra...)...)
				label := c.name + " " + strings.Join(c.extra, " ")
				if lcode != gcode {
					t.Errorf("%s: legacy exit %d (%s), Go exit %d (%s)", label, lcode, strings.TrimSpace(lerr), gcode, strings.TrimSpace(gerr))
					return
				}
				if gout != "" {
					t.Errorf("%s: stdout must stay empty, got %q", label, gout)
				}
				if lcode != 0 {
					if lerr != gerr {
						t.Errorf("%s: stderr differs\n legacy: %q\n Go:     %q", label, lerr, gerr)
					}
					assertNoLeftovers(t, work, "legacy-"+itoa(i), "go-"+itoa(i))
					return
				}
				accepted.Add(1)
				lt, gt := readTree(t, lo), readTree(t, mo)
				if strings.Join(treeNames(lt), ",") != strings.Join(treeNames(gt), ",") {
					t.Errorf("%s: trees differ: legacy %v, Go %v", label, treeNames(lt), treeNames(gt))
					return
				}
				for name, e := range lt {
					g := gt[name]
					if e.mode != g.mode {
						t.Errorf("%s: %s mode legacy %v, Go %v", label, name, e.mode, g.mode)
					}
					if name != "analysis-manifest.v1.json" && e.data != g.data {
						t.Errorf("%s: %s bytes differ", label, name)
					}
				}
				verifyManifest(t, mo)
				sameManifestFacts(t, lo, mo)
			})
		}
	})
	if accepted.Load() < 5 {
		t.Fatalf("only %d archives were accepted; the comparison proves nothing", accepted.Load())
	}
}

func itoa(i int) string { return strconv.Itoa(i) }

func TestZipStoredCommandParity(t *testing.T) {
	work := t.TempDir()
	in := t.TempDir()
	paths := writeFixtures(t, in, storedFixtures())
	var cases []cmdCase
	for name := range paths {
		cases = append(cases, cmdCase{name: name})
	}
	sort.Slice(cases, func(i, j int) bool { return cases[i].name < cases[j].name })
	for _, c := range [][]string{
		{"--max-input-bytes", "4"}, {"--max-entries", "1"}, {"--max-path-bytes", "3"}, {"--max-depth", "1"}, {"--max-entry-bytes", "4"},
		{"--max-total-bytes", "6"}, {"--max-report-bytes", "100"}, {"--max-metadata-bytes", "10"}, {"--max-depth", "0"},
	} {
		cases = append(cases, cmdCase{name: "good.zip", extra: c})
	}
	var accepted atomic.Int32
	t.Run("cases", func(t *testing.T) {
		for i, c := range cases {
			i, c := i, c
			t.Run(c.name+" "+strings.Join(c.extra, " "), func(t *testing.T) {
				t.Parallel()
				lo, mo := filepath.Join(work, "legacy-"+itoa(i)), filepath.Join(work, "go-"+itoa(i))
				lcode, lerr := legacy(t, "zip_stored.py", legacyStoredArgs(t, paths[c.name], lo, c.extra...)...)
				gcode, gout, gerr := runGo(t, ZipStored, work, storedArgs(t, paths[c.name], mo, c.extra...)...)
				label := c.name + " " + strings.Join(c.extra, " ")
				if lcode != gcode {
					t.Errorf("%s: legacy exit %d (%s), Go exit %d (%s)", label, lcode, strings.TrimSpace(lerr), gcode, strings.TrimSpace(gerr))
					return
				}
				if gout != "" {
					t.Errorf("%s: stdout must stay empty, got %q", label, gout)
				}
				if lcode != 0 {
					// A legacy rejection that surfaced through the manifest tool names a subprocess; compare the others.
					if !strings.Contains(lerr, "Command '[") && lerr != gerr {
						t.Errorf("%s: stderr differs\n legacy: %q\n Go:     %q", label, lerr, gerr)
					}
					assertNoLeftovers(t, work, "legacy-"+itoa(i), "go-"+itoa(i))
					return
				}
				accepted.Add(1)
				lt, gt := readTree(t, lo), readTree(t, mo)
				if strings.Join(treeNames(lt), ",") != strings.Join(treeNames(gt), ",") {
					t.Errorf("%s: trees differ: legacy %v, Go %v", label, treeNames(lt), treeNames(gt))
					return
				}
				for name, e := range lt {
					g := gt[name]
					if e.mode != g.mode {
						t.Errorf("%s: %s mode legacy %v, Go %v", label, name, e.mode, g.mode)
					}
					if name != "analysis-manifest.v1.json" && e.data != g.data {
						t.Errorf("%s: %s bytes differ", label, name)
					}
				}
				verifyManifest(t, mo)
				sameManifestFacts(t, lo, mo)
			})
		}
	})
	if accepted.Load() < 5 {
		t.Fatalf("only %d archives were extracted; the comparison proves nothing", accepted.Load())
	}
}
