package migratebacklogs

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// This file is the shared test harness. It carries no build tag: gremlins builds with -tags nodiff, and the case
// tables, the Go runner and the golden replay need it. The tagged differential_test.go adds the live legacy run.
//
// A case lays a corpus out in a temp directory. The legacy script and the Go command read the SAME directory (the
// tool only reads), and the whole tree is fingerprinted before and after each run: propose-never-apply is
// asserted for every case, refusals included. The temp root is replaced by @T@ in every recorded output.

type dcase struct {
	name string
	// files maps a slash path under the corpus to its content; a key ending in "/" is an empty directory.
	files map[string]string
	// links maps a symlink path under the corpus to its (relative) target.
	links map[string]string
	// args replaces the argument list; @C@ is the corpus directory and @T@ the temp root. nil is [@C@].
	args []string
}

// result is what one run produced, normalised.
type result struct {
	RC     int    `json:"rc"`
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
}

// layout writes the case under a fresh temp root and returns the root and the corpus directory.
func (c dcase) layout(t *testing.T) (root, corpus string) {
	t.Helper()
	r, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	corpus = filepath.Join(r, "corpus")
	if err := os.MkdirAll(corpus, 0o755); err != nil {
		t.Fatal(err)
	}
	for p, content := range c.files {
		full := filepath.Join(corpus, filepath.FromSlash(p))
		if strings.HasSuffix(p, "/") {
			if err := os.MkdirAll(full, 0o755); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for p, target := range c.links {
		full := filepath.Join(corpus, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, full); err != nil {
			t.Fatal(err)
		}
	}
	return r, corpus
}

func (c dcase) resolveArgs(root, corpus string) []string {
	if c.args == nil {
		return []string{corpus}
	}
	out := make([]string, len(c.args))
	for i, a := range c.args {
		out[i] = strings.NewReplacer("@C@", corpus, "@T@", root).Replace(a)
	}
	return out
}

// normalize hides the temp root and the one stderr text the port words differently: the usage line names the
// command instead of the script.
func normalize(root, s string) string {
	s = strings.ReplaceAll(s, root, "@T@")
	return strings.ReplaceAll(s, "usage: migrate-backlogs.sh <corpus-dir>", "usage: rsdd corpus migrate-backlogs <corpus-dir>")
}

// treeFingerprint is every path under dir with its mode, size, content digest and link target: a run that
// touches the corpus in any way changes it.
func treeFingerprint(t *testing.T, dir string) string {
	t.Helper()
	var lines []string
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		entry := fmt.Sprintf("%s %v %d", rel, info.Mode(), info.Size())
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			target, _ := os.Readlink(p)
			entry += " -> " + target
		case info.Mode().IsRegular():
			data, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			sum := sha256.Sum256(data)
			entry += " " + hex.EncodeToString(sum[:])
		}
		lines = append(lines, entry)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(lines)
	return strings.Join(lines, "\n")
}

// runGo runs the command the way the shim does and checks that it left the tree as it found it.
func runGo(t *testing.T, root, corpus string, args []string) result {
	t.Helper()
	before := treeFingerprint(t, root)
	var so, se bytes.Buffer
	rc := Run(Options{Args: args, Out: &so, Err: &se})
	if after := treeFingerprint(t, root); after != before {
		t.Errorf("the run changed the corpus tree (propose-never-apply):\nbefore:\n%s\nafter:\n%s", before, after)
	}
	return result{RC: rc, Stdout: normalize(root, so.String()), Stderr: normalize(root, se.String())}
}

const goldenPath = "testdata/golden/cases.json"

func readGoldens(t *testing.T) map[string]result {
	t.Helper()
	data, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("%v (regenerate with MIGRATE_BACKLOGS_UPDATE=1 go test -run TestDifferential)", err)
	}
	var m map[string]result
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("%s: %v", goldenPath, err)
	}
	return m
}

func diffResult(want, got result) string {
	var sb strings.Builder
	if want.RC != got.RC {
		sb.WriteString("exit: want " + quote(want.RC) + ", got " + quote(got.RC) + "\n")
	}
	for _, p := range []struct{ name, w, g string }{{"stdout", want.Stdout, got.Stdout}, {"stderr", want.Stderr, got.Stderr}} {
		if p.w != p.g {
			sb.WriteString(p.name + ":\n  want " + quote(p.w) + "\n  got  " + quote(p.g) + "\n")
		}
	}
	return sb.String()
}

func quote(v any) string { b, _ := json.Marshal(v); return string(b) }
