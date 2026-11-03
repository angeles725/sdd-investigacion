package kit

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
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
		{"symlink is resolved", nil, ok(link), []string{"RSDD_BIN=" + realResolved}},
		{"unresolvable path is used as given", nil, ok(filepath.Join(dir, "gone")), []string{"RSDD_BIN=" + filepath.Join(dir, "gone")}},
		{"relative path is made absolute", nil, ok("rel-rsdd"), []string{"RSDD_BIN=" + relAbs}},
		{"a similar name is not RSDD_BIN", []string{"XRSDD_BIN=/x"}, ok(real), []string{"XRSDD_BIN=/x", "RSDD_BIN=" + realResolved}},
	} {
		t.Run(c.name, func(t *testing.T) {
			in := append([]string(nil), c.env...)
			got := ShimEnv(c.env, c.self)
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("got %q, want %q", got, c.want)
			}
			if !reflect.DeepEqual(c.env, in) {
				t.Errorf("the input was modified: %q", c.env)
			}
		})
	}
}
