//go:build unix

package git

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// fakeGitScript is a stub git driven by GIT_OUT / GIT_ERR / GIT_RC / GIT_SLEEP / GIT_SELFKILL that logs its argv
// to $GIT_LOG. Absolute paths only: the PATH holds nothing but the stub.
const fakeGitScript = `#!/bin/sh
[ -z "$GIT_LOG" ] || printf '%s\n' "$*" > "$GIT_LOG"
[ -z "$GIT_SLEEP" ] || /bin/sleep "$GIT_SLEEP"
[ -z "$GIT_SELFKILL" ] || kill -s "$GIT_SELFKILL" $$
printf '%b' "$GIT_OUT"
printf '%s' "$GIT_ERR" >&2
exit "${GIT_RC:-0}"
`

// stub returns a Runner over the stub git with the extra environ entries.
func stub(t *testing.T, extra ...string) Runner {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "git"), []byte(fakeGitScript), 0o755); err != nil {
		t.Fatal(err)
	}
	return Runner{Env: append([]string{"PATH=" + dir}, extra...)}
}

func TestRunPassesArgvAndOutput(t *testing.T) {
	log := filepath.Join(t.TempDir(), "log")
	r := stub(t, "GIT_OUT=a\nb\n", "GIT_LOG="+log)
	out, err := r.Run("/some/dir", "remote", "get-url", "origin")
	if err != nil || string(out) != "a\nb\n" {
		t.Fatalf("got %q, %v", out, err)
	}
	if b, _ := os.ReadFile(log); string(b) != "-C /some/dir remote get-url origin\n" {
		t.Fatalf("argv %q", b)
	}
}

func TestRunErrors(t *testing.T) {
	cases := []struct {
		name    string
		r       Runner
		is      error
		code    int // for an *ExitError
		stderr  string
		maxTime time.Duration
	}{
		{"exit status", stub(t, "GIT_RC=128", "GIT_ERR=fatal: not a git repository\n"), nil, 128, "fatal: not a git repository\n", 0},
		{"signal", stub(t, "GIT_SELFKILL=TERM"), nil, 143, "", 0},
		{"missing git", Runner{Env: []string{"PATH=" + t.TempDir()}}, ErrMissing, 0, "", 0},
		{"missing git by path", Runner{Bin: "/nonexistent/git"}, ErrMissing, 0, "", 0},
		{"timeout", func() Runner { r := stub(t, "GIT_SLEEP=30"); r.Timeout = 200 * time.Millisecond; return r }(), ErrTimeout, 0, "", 10 * time.Second},
		{"output cap", func() Runner { r := stub(t, "GIT_OUT=0123456789"); r.MaxBytes = 4; return r }(), ErrOutputCap, 0, "", 0},
		{"refused spec", func() Runner { r := stub(t); r.MaxBytes = -1; return r }(), proc.ErrInvalidSpec, 0, "", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			start := time.Now()
			_, err := c.r.Run("", "status")
			if c.maxTime > 0 && time.Since(start) > c.maxTime {
				t.Fatalf("took %v: the bound did not hold", time.Since(start))
			}
			if c.is != nil {
				if !errors.Is(err, c.is) {
					t.Fatalf("got %v, want %v", err, c.is)
				}
				return
			}
			var ee *ExitError
			if !errors.As(err, &ee) || ee.Code != c.code || ee.Stderr != c.stderr || strings.Join(ee.Args, " ") != "status" {
				t.Fatalf("got %#v", err)
			}
		})
	}
}

func TestRunDefaults(t *testing.T) {
	r := stub(t, "GIT_OUT=ok")
	if out, err := r.Run(""); err != nil || string(out) != "ok" {
		t.Fatalf("got %q, %v", out, err)
	}
	if r.timeout() != DefaultTimeout || r.maxBytes() != DefaultMaxBytes {
		t.Fatalf("defaults %v %d", r.timeout(), r.maxBytes())
	}
}

func TestExitErrorText(t *testing.T) {
	e := &ExitError{Args: []string{"merge-base", "HEAD", "x"}, Code: 128, Stderr: "fatal: bad\nmore\n"}
	if got := e.Error(); got != "git merge-base HEAD x: exit 128: fatal: bad" {
		t.Fatalf("got %q", got)
	}
	if got := (&ExitError{Args: []string{"x"}, Code: 1}).Error(); got != "git x: exit 1" {
		t.Fatalf("got %q", got)
	}
}
