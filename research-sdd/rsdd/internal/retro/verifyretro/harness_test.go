package verifyretro

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
// A case runs in a BOX: a temp dir with rh/retros/<file> holding the retro and work/ as the working directory.
// The legacy run and the Go run use the SAME box, so paths in messages are equal; the box path is replaced by
// @BOX@ in every recorded output.

// dcase is one scenario.
type dcase struct {
	name string
	// retro is the content of the retro; noRetro leaves the file absent.
	retro   string
	noRetro bool
	// file is the retro's base name, r.md when empty.
	file string
	// args replaces the argument list (@BOX@ is the box root, @RETRO@ the retro path); nil = [@RETRO@].
	args []string
	// rel passes the retro as a bare file name with the retro's directory as the working directory.
	rel bool
	// prep runs once on the box after it is built.
	prep func(t *testing.T, b *box)
}

type box struct {
	root, retro, cwd string
	args             []string
}

// result is what one run produced, normalised.
type result struct {
	RC     int    `json:"rc"`
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
}

func mkBox(t *testing.T, c dcase) *box {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	file := c.file
	if file == "" {
		file = "r.md"
	}
	b := &box{root: root, cwd: filepath.Join(root, "work"), retro: filepath.Join(root, "rh", "retros", file)}
	for _, d := range []string{"work", "rh/retros"} {
		mustMkdir(t, filepath.Join(root, d))
	}
	if !c.noRetro {
		mustWrite(t, b.retro, c.retro)
	}
	b.args = []string{b.retro}
	switch {
	case c.rel:
		b.args, b.cwd = []string{file}, filepath.Dir(b.retro)
	case c.args != nil:
		b.args = nil
		for _, a := range c.args {
			b.args = append(b.args, strings.NewReplacer("@BOX@", root, "@RETRO@", b.retro).Replace(a))
		}
	}
	if c.prep != nil {
		c.prep(t, b)
	}
	return b
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

// runGo runs the port on the box, the way the command does: Run, then Render.
func runGo(t *testing.T, b *box) result {
	t.Helper()
	rep, err := Run(context.Background(), Options{Args: b.args, Cwd: b.cwd})
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
		t.Fatalf("%v (regenerate with VERIFYRETRO_UPDATE=1 go test -run TestDifferential)", err)
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
	if want.Stdout != got.Stdout {
		sb.WriteString("stdout:\n  want " + quote(want.Stdout) + "\n  got  " + quote(got.Stdout) + "\n")
	}
	if want.Stderr != got.Stderr {
		sb.WriteString("stderr:\n  want " + quote(want.Stderr) + "\n  got  " + quote(got.Stderr) + "\n")
	}
	return sb.String()
}

func quote(v any) string { b, _ := json.Marshal(v); return string(b) }
