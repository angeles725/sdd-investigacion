package cishard

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// result is what one command run produced.
type result struct {
	rc       int
	out, err string
}

// runIn runs `rsdd maint ci-shard args...` in cwd with stdin; a nil stdin is an absent input (Stdio.In nil).
func runIn(t *testing.T, cwd string, stdin *string, args ...string) result {
	t.Helper()
	var out, errb bytes.Buffer
	s := cli.Stdio{
		Out: &out, Err: &errb, Cwd: cwd,
		Env:   func(string) string { return "" },
		Clock: func() time.Time { return time.Unix(0, 0) },
	}
	if stdin != nil {
		s.In = strings.NewReader(*stdin)
	}
	rc := Run(args, s)
	return result{rc, out.String(), errb.String()}
}

// str returns a pointer for runIn's stdin.
func str(s string) *string { return &s }

// writeFile writes name under dir and returns its path.
func writeFile(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// lines splits output into its non-empty lines.
func lines(s string) []string {
	var l []string
	for _, x := range strings.Split(s, "\n") {
		if x != "" {
			l = append(l, x)
		}
	}
	return l
}

// has reports whether any line of text contains sub.
func has(text, sub string) bool { return strings.Contains(text, sub) }
