package reconcile

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// This file is the shared test harness. It carries no build tag: gremlins builds with -tags nodiff, and the case
// table, the Go runner and the golden replay need it. The tagged differential_test.go adds the live legacy run.
//
// A case runs in a BOX: a temp dir that looks like a kit checkout (research-sdd/TARGETS.md with one registered
// target, rh/<target>/retros/ holding the retro, cache.txt the --issues-cache file). The legacy run and the Go
// run use the SAME box, so paths in messages are equal; box paths are replaced by @BOX@ in every recorded output.

// updateGoldens regenerates testdata/golden from the LEGACY script (needs bash): RECONCILE_UPDATE=1 go test
// -run TestDifferential. An environment variable, not a flag: a flag only this package defines would fail the
// other packages of a repo-wide run.
func updateGoldens() bool { return os.Getenv("RECONCILE_UPDATE") == "1" }

// dcase is one scenario.
type dcase struct {
	name string
	// retro is the content of the retro; noRetro leaves the file absent.
	retro   string
	noRetro bool
	// retroFile is the retro's base name, r.md when empty.
	retroFile string
	// cache is the --issues-cache content; cacheMissing points the flag at a file that does not exist.
	cache        string
	cacheMissing bool
	// target is the registered target name and the directory under rh/; "target-foo" when empty.
	target string
	// retroDir is the retro's directory relative to the box root; rh/<target>/retros when empty.
	retroDir string
	// targets replaces TARGETS.md (@BOX@ is the box root); noTargets removes it.
	targets   string
	noTargets bool
	// files are extra files relative to the box root.
	files map[string]string
	// prep runs once on the box after it is built.
	prep func(t *testing.T, b *box)
	// rel passes the retro as a bare file name with the retro's directory as the working directory.
	rel bool
	// retroArg replaces the retro argument (@BOX@ is the box root); "" = the real retro path.
	retroArg string
}

type box struct {
	root  string
	retro string // absolute path of the retro (it may not exist)
	cache string
	cwd   string
	arg   string // the retro argument as the command line carries it
}

// result is what one run produced, normalised.
type result struct {
	RC     int    `json:"rc"`
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
}

const defaultTargets = "# test targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | @TARGET@ | `@BOX@/rh/@TARGET@` |\n"

func mkBox(t *testing.T, c dcase) *box {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	tgt := c.target
	if tgt == "" {
		tgt = "target-foo"
	}
	dir := c.retroDir
	if dir == "" {
		dir = "rh/" + tgt + "/retros"
	}
	file := c.retroFile
	if file == "" {
		file = "r.md"
	}
	b := &box{root: root, cwd: filepath.Join(root, "work"), cache: filepath.Join(root, "cache.txt")}
	b.retro = filepath.Join(root, dir, file)
	for _, d := range []string{"research-sdd", "work", "home", dir} {
		mustMkdir(t, filepath.Join(root, d))
	}
	if !c.noTargets {
		tm := c.targets
		if tm == "" {
			tm = defaultTargets
		}
		mustWrite(t, filepath.Join(root, "research-sdd", "TARGETS.md"), box2(tm, root, tgt))
	}
	if !c.noRetro {
		mustWrite(t, b.retro, c.retro)
	}
	if !c.cacheMissing {
		mustWrite(t, b.cache, c.cache)
	}
	for name, content := range c.files {
		p := filepath.Join(root, name)
		mustMkdir(t, filepath.Dir(p))
		mustWrite(t, p, box2(content, root, tgt))
	}
	b.arg = b.retro
	switch {
	case c.rel:
		b.arg, b.cwd = file, filepath.Dir(b.retro)
	case c.retroArg != "":
		b.arg = box2(c.retroArg, root, tgt)
	}
	if c.prep != nil {
		c.prep(t, b)
	}
	return b
}

func box2(s, root, tgt string) string {
	return strings.NewReplacer("@BOX@", root, "@TARGET@", tgt).Replace(s)
}

func mustMkdir(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, p, content string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// normalize replaces the box path so recorded outputs do not depend on the temp dir.
func (b *box) normalize(rc int, stdout, stderr string) result {
	return result{RC: rc, Stdout: strings.ReplaceAll(stdout, b.root, "@BOX@"), Stderr: strings.ReplaceAll(stderr, b.root, "@BOX@")}
}

// runGo runs the port on the box, the way the shim will: Run, then Render.
func runGo(t *testing.T, b *box) result {
	t.Helper()
	rep, err := Run(context.Background(), Options{
		Retro: b.arg, IssuesCache: CacheFile(b.cache), KitRoot: b.root, Cwd: b.cwd,
		Env: func(k string) string {
			if k == "HOME" {
				return filepath.Join(b.root, "home")
			}
			return ""
		},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	var so, se bytes.Buffer
	rc := rep.Render(&so, &se)
	return b.normalize(rc, so.String(), se.String())
}

const goldenPath = "testdata/golden/cases.json"

func readGoldens(t *testing.T) map[string]result {
	t.Helper()
	data, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("%v (regenerate with RECONCILE_UPDATE=1 go test -run TestDifferential)", err)
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
		sb.WriteString("exit: want " + itoa(want.RC) + ", got " + itoa(got.RC) + "\n")
	}
	if want.Stdout != got.Stdout {
		sb.WriteString("stdout:\n  want " + quote(want.Stdout) + "\n  got  " + quote(got.Stdout) + "\n")
	}
	if want.Stderr != got.Stderr {
		sb.WriteString("stderr:\n  want " + quote(want.Stderr) + "\n  got  " + quote(got.Stderr) + "\n")
	}
	return sb.String()
}

func quote(s string) string { b, _ := json.Marshal(s); return string(b) }
func itoa(n int) string     { b, _ := json.Marshal(n); return string(b) }
