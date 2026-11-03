package corrections

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

// observed is what a caller sees of one run: both streams and the exit code. A minimal local copy of the
// run-shape helper that internal/testkit/observed will provide once it lands (switch to it then).
type observed struct {
	stdout, stderr string
	code           int
}

// readFile is the production reader, for tests that wrap it.
func readFile(p string) ([]byte, error) { return os.ReadFile(p) }

// stdio is a quiet Stdio writing to the given sinks.
func stdio(out, errw io.Writer) cli.Stdio {
	return cli.Stdio{
		In: strings.NewReader(""), Out: out, Err: errw,
		Env:     func(string) string { return "" },
		Environ: func() []string { return nil },
		Clock:   time.Now,
		Cwd:     "/",
	}
}

// runGo runs the command in-process against args with a quiet environment.
func runGo(args ...string) observed {
	var out, errb bytes.Buffer
	code := Run(args, stdio(&out, &errb))
	return observed{out.String(), errb.String(), code}
}

// corpus writes files (relative path -> content) under a fresh directory and returns it. A name ending in "/"
// creates only the directory.
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
