package kit

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
)

func TestShimEnv(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real-rsdd")
	if err := os.WriteFile(real, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link-rsdd")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	realResolved, err := filepath.EvalSymlinks(real)
	if err != nil {
		t.Fatal(err)
	}
	relAbs, err := filepath.Abs("rel-rsdd") // does not exist: EvalSymlinks leaves it as it is
	if err != nil {
		t.Fatal(err)
	}
	ok := func(p string) func() (string, error) { return func() (string, error) { return p, nil } }
	fail := func() (string, error) { return "", errors.New("no executable") }
	for _, c := range []struct {
		name string
		env  []string
		self func() (string, error)
		want []string
	}{
		{"unset", []string{"A=1"}, ok(real), []string{"A=1", "RSDD_BIN=" + realResolved}},
		{"empty is replaced", []string{"A=1", "RSDD_BIN=", "B=2"}, ok(real), []string{"A=1", "B=2", "RSDD_BIN=" + realResolved}},
		{"caller-set is kept", []string{"RSDD_BIN=/mine/rsdd", "A=1"}, ok(real), []string{"RSDD_BIN=/mine/rsdd", "A=1"}},
		{"self error leaves the env alone", []string{"A=1", "RSDD_BIN="}, fail, []string{"A=1", "RSDD_BIN="}},
		{"symlink is resolved", []string{}, ok(link), []string{"RSDD_BIN=" + realResolved}},
		{"unresolvable path is used as given", []string{}, ok(filepath.Join(dir, "gone")), []string{"RSDD_BIN=" + filepath.Join(dir, "gone")}},
		{"relative path is made absolute", []string{}, ok("rel-rsdd"), []string{"RSDD_BIN=" + relAbs}},
		{"the last entry decides: an empty last value is replaced", []string{"RSDD_BIN=/x", "A=1", "RSDD_BIN="}, ok(real), []string{"A=1", "RSDD_BIN=" + realResolved}},
		{"the last entry decides: a non-empty last value is kept", []string{"RSDD_BIN=", "RSDD_BIN=/x"}, ok(real), []string{"RSDD_BIN=", "RSDD_BIN=/x"}},
		{"a bare RSDD_BIN with no = is not a value", []string{"RSDD_BIN"}, ok(real), []string{"RSDD_BIN", "RSDD_BIN=" + realResolved}},
		{"a similar name is not RSDD_BIN", []string{"XRSDD_BIN=/x"}, ok(real), []string{"XRSDD_BIN=/x", "RSDD_BIN=" + realResolved}},
	} {
		t.Run(c.name, func(t *testing.T) {
			in := append([]string(nil), c.env...)
			got := ShimEnv(c.env, c.self)
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("got %q, want %q", got, c.want)
			}
			if !slices.Equal(c.env, in) {
				t.Errorf("the input was modified: %q", c.env)
			}
		})
	}
}

// A nil environ stays nil, so exec.Cmd still inherits the parent's environment: `cmd.Env = ShimEnv(cmd.Env, ...)`
// must not turn "inherit everything" into "only RSDD_BIN", whether self succeeds or fails.
func TestShimEnvNilStaysNil(t *testing.T) {
	ok := func() (string, error) { return "/bin/sh", nil }
	fail := func() (string, error) { return "", errors.New("no executable") }
	for _, self := range []func() (string, error){ok, fail} {
		if got := ShimEnv(nil, self); got != nil {
			t.Errorf("ShimEnv(nil) = %q, want nil (inherit the parent environment)", got)
		}
	}
}
