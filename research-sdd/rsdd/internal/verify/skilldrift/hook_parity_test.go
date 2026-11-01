package skilldrift

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// Parity of `rsdd verify skill-drift-hook` with the frozen legacy hook, like parity_test.go does for the drift command. The
// compared streams are the raw ones: the SessionStart JSON is held to jq's own bytes, not to its decoded text.

func expectHook(t *testing.T, c hcase, r result, took time.Duration) {
	t.Helper()
	if r.code != 0 {
		t.Errorf("a hook never fails the session: exit = %d", r.code)
	}
	if r.err != "" {
		t.Errorf("stderr must stay empty, got %q", r.err)
	}
	ctx := decode(r.out)
	if c.silent && r.out != "" {
		t.Errorf("expected silence, got %q", r.out)
	}
	if !c.silent && len(c.has) > 0 && r.out == "" {
		t.Fatalf("expected a report, got silence")
	}
	flat := strings.ReplaceAll(ctx, "\n", `\n`)
	for _, h := range c.has {
		if !strings.Contains(ctx, h) && !strings.Contains(flat, h) {
			t.Errorf("context lacks %q:\n%s", h, ctx)
		}
	}
	for _, n := range c.not {
		if strings.Contains(ctx, n) {
			t.Errorf("context contains %q:\n%s", n, ctx)
		}
	}
	if c.max > 0 && utf8.RuneCountInString(ctx) > c.max {
		t.Errorf("context is %d characters, budget %d", utf8.RuneCountInString(ctx), c.max)
	}
	if c.limitSec > 0 && took > time.Duration(c.limitSec)*time.Second {
		t.Errorf("took %v, bound %ds", took, c.limitSec)
	}
}

func TestHookParity(t *testing.T) {
	for _, c := range hookCases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			w, env := c.prepare(t)
			start := time.Now()
			got := w.norm(w.runGoHook(c, env))
			took := time.Since(start)
			expectHook(t, c, got, took)
			if left := w.leftover(); len(left) != 0 {
				t.Errorf("the Go run left temp entries behind: %v", left)
			}
			if !c.oracle || c.diverg {
				return
			}
			want := w.norm(w.runBashHook(env))
			if got != want {
				t.Errorf("parity broken\n--- legacy (exit %d)\nstdout: %q\nstderr: %q\n--- go (exit %d)\nstdout: %q\nstderr: %q",
					want.code, want.out, want.err, got.code, got.out, got.err)
			}
			if _, err := os.Stat(filepath.Join(w.root, "vt-pwned")); err == nil {
				t.Error("a command substitution in a timeout value was executed")
			}
		})
	}
}

func TestHookGolden(t *testing.T) {
	for _, c := range hookCases {
		if !c.oracle || c.diverg {
			continue
		}
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			w, env := c.prepare(t)
			if *update {
				writeGolden(t, "hook-"+c.name, w.norm(w.runBashHook(env)))
				return
			}
			got := w.norm(w.runGoHook(c, env))
			if want := readGolden(t, "hook-"+c.name); got != want {
				t.Errorf("golden mismatch\n--- golden (exit %d)\nstdout: %q\nstderr: %q\n--- go (exit %d)\nstdout: %q\nstderr: %q",
					want.code, want.out, want.err, got.code, got.out, got.err)
			}
		})
	}
}
