package gapdrift

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// observed is what a caller sees of one run: both streams and the exit code.
type observed struct {
	stdout, stderr string
	code           int
}

func stdio(out, errw io.Writer, cwd string) cli.Stdio {
	return cli.Stdio{
		In: strings.NewReader(""), Out: out, Err: errw,
		Env:     func(string) string { return "" },
		Environ: func() []string { return nil },
		Clock:   time.Now,
		Cwd:     cwd,
	}
}

// runGo runs the command in-process in cwd.
func runGo(cwd string, args ...string) observed {
	var out, errb bytes.Buffer
	code := Run(args, stdio(&out, &errb, cwd))
	return observed{out.String(), errb.String(), code}
}

// corpus writes files (relative path -> content) under a fresh directory and returns it. A name ending in "/" creates
// only the directory.
func corpus(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		p := filepath.Join(dir, name)
		if strings.HasSuffix(name, "/") {
			if err := os.MkdirAll(p, 0o755); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

const stateHead = "# s\n\n## Gap-backlog\n\n| Priority | Gap | Type | Status |\n|---|---|---|---|\n"

// state builds a RESEARCH-STATE.md with the given table rows.
func state(rows ...string) string { return stateHead + strings.Join(rows, "\n") + "\n" }

func row(prio, text, status string) string {
	return "| " + prio + " | " + text + " | w | " + status + " |"
}
