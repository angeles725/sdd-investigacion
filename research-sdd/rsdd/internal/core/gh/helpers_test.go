//go:build unix

package gh

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeGHScript is the stub gh: driven by GH_OUT (printf %b escapes) / GH_ERR / GH_RC / GH_SLEEP / GH_SELFKILL /
// GH_IGNORE_TERM, it logs its argv, cwd, GH_PROMPT_DISABLED, GH_REPO and FOO to $GH_LOG. Only absolute paths, so
// a PATH holding nothing but the stub's directory keeps the host's gh, timeout and git out of reach.
const fakeGHScript = `#!/bin/sh
[ -z "$GH_LOG" ] || printf 'argv=%s\ncwd=%s\nprompt=%s\nrepo=%s\nfoo=%s\n' "$*" "$(pwd)" \
  "${GH_PROMPT_DISABLED-unset}" "${GH_REPO-unset}" "${FOO-unset}" > "$GH_LOG"
[ -z "$GH_IGNORE_TERM" ] || trap '' TERM
[ -z "$GH_SLEEP" ] || /bin/sleep "$GH_SLEEP"
[ -z "$GH_SELFKILL" ] || kill -s "$GH_SELFKILL" $$
printf '%b' "$GH_OUT"
printf '%s' "$GH_ERR" >&2
exit "${GH_RC:-0}"
`

// fakeBin returns a directory holding only the stub gh, for use as the whole PATH.
func fakeBin(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "gh"), []byte(fakeGHScript), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

// opts returns Options whose PATH is a fresh fake bin directory, plus the extra environ entries.
func opts(t *testing.T, extra ...string) Options {
	t.Helper()
	return Options{Env: append([]string{"PATH=" + fakeBin(t)}, extra...)}
}

// withLog sets GH_LOG in o and returns a reader of the stub's log as key -> value.
func withLog(t *testing.T, o *Options) func() map[string]string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "gh.log")
	o.Env = append(o.Env, "GH_LOG="+p)
	return func() map[string]string {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("the stub gh did not run: %v", err)
		}
		m := map[string]string{}
		for _, l := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
			k, v, _ := strings.Cut(l, "=")
			m[k] = v
		}
		return m
	}
}
