package fetchdoc

import "testing"

// A refused name, sub-directory or URL is a usage error (2) before the curl/wget probe, which says 3 only for a
// request that would otherwise have been served.
func TestRefusalComesBeforeTheDownloaderProbe(t *testing.T) {
	for _, c := range []struct {
		args []string
		want int
	}{
		{[]string{"doc", "http://h/a.pdf", "T", "datasheets", "../x"}, 2},
		{[]string{"doc", "http://h/a.pdf", "T", "../up", "x"}, 2},
		{[]string{"doc", "-oops", "T"}, 2},
		{[]string{"web", "-oops", "T"}, 2},
		{[]string{"doc", "http://h/a.pdf", "T"}, 3},
		{[]string{"web", "http://h/page", "T"}, 3},
	} {
		w := newWorld(t) // neither curl nor wget on the PATH
		args := append([]string(nil), c.args...)
		for i, a := range args {
			if a == "T" {
				args[i] = w.dir
			}
		}
		if got := w.goRun(args...); got.rc != c.want {
			t.Errorf("%v: exit %d, want %d (%q)", c.args, got.rc, c.want, got.err)
		}
	}
}
