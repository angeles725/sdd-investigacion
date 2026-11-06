package toolcatalog

import (
	"bytes"
	"encoding/json"
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

// The two locales every case runs in: the byte (C) rules and the UTF-8 rules of grep -iw.
var locales = []string{"C", "C.UTF-8"}

func stdio(out, errw io.Writer, cwd, loc string) cli.Stdio {
	return cli.Stdio{
		In: strings.NewReader(""), Out: out, Err: errw,
		Env: func(k string) string {
			if k == "LC_ALL" {
				return loc
			}
			return ""
		},
		Environ: func() []string { return nil },
		Clock:   time.Now,
		Cwd:     cwd,
	}
}

func runGo(cwd, loc string, run func([]string, cli.Stdio) int, args ...string) observed {
	var out, errb bytes.Buffer
	code := run(args, stdio(&out, &errb, cwd, loc))
	return observed{out.String(), errb.String(), code}
}

// kit writes files (name -> content) into a fresh directory. A name ending in "/" creates only the directory.
func kit(t *testing.T, files map[string]string) string {
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

const logHead = "# Installed tools log\n\n| Tool | How | Status | Target | Date (UTC) | Notes |\n|---|---|---|---|---|---|\n"

const regHead = "# Tool Registry\n\n| Artifact type | Tool |\n|---|---|\n"

// logRow is one auto-log row of INSTALLED-TOOLS.md.
func logRow(tool string) string {
	return "| " + tool + " | `brew` | installed | kit | 2026-01-01T00:00:00Z | n/a |\n"
}

// logOf is INSTALLED-TOOLS.md with one row per tool.
func logOf(tools ...string) string {
	var b strings.Builder
	b.WriteString(logHead)
	for _, tl := range tools {
		b.WriteString(logRow(tl))
	}
	return b.String()
}

// regOf is tool-registry.md with one capability row per entry (the entry is the whole Tool cell).
func regOf(cells ...string) string {
	var b strings.Builder
	b.WriteString(regHead)
	for _, c := range cells {
		b.WriteString("| A | " + c + " |\n")
	}
	return b.String()
}

// contextOf is the additionalContext of a SessionStart envelope.
func contextOf(t *testing.T, envelope string) string {
	t.Helper()
	var e struct {
		HookSpecificOutput struct {
			AdditionalContext string `json:"additionalContext"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(envelope), &e); err != nil {
		t.Fatalf("not a SessionStart envelope: %v: %q", err, envelope)
	}
	return e.HookSpecificOutput.AdditionalContext
}
