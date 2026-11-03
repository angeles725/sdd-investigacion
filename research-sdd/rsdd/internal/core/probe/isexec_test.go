//go:build unix

package probe

import "testing"

func TestIsExecIsTheShellTest(t *testing.T) {
	dir := t.TempDir()
	run := exe(t, dir, "bin/run", "exit 0")
	plain := put(t, dir, "bin/plain", "x", 0o644)
	sub := mkdir(t, dir, "bin/sub")
	p := New(nil, dir)
	for _, c := range []struct {
		path string
		want bool
	}{
		{run, true}, {"bin/run", true}, // a relative path is anchored at the working directory
		{plain, false}, {dir + "/absent", false}, {"", false},
		{sub, true}, // `[ -x dir ]` is true for a searchable directory; callers that need a file test it themselves
	} {
		if got := p.IsExec(c.path); got != c.want {
			t.Errorf("IsExec(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}
