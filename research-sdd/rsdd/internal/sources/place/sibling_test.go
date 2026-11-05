package place

import (
	"os"
	"strconv"
	"testing"
)

func TestSiblingKeepsTheDirectoryOfTheRow(t *testing.T) {
	for rel, want := range map[string]string{"a.pdf": "v", "d/a.pdf": "d/v", "/a.pdf": "/v", "x/y/a.pdf": "x/y/v"} {
		if got := sibling(rel, "v"); got != want {
			t.Errorf("sibling(%q) = %q, want %q", rel, got, want)
		}
	}
}

func TestSweepStaleDefaultsToProcLiveness(t *testing.T) {
	x := newFx(t, false)
	dead := x.sub + "/a.pdf.fetchdoc-part.2147483646"
	live := x.sub + "/b.pdf.fetchdoc-part." + strconv.Itoa(os.Getpid())
	write(t, dead, "x")
	write(t, live, "x")
	x.p.SweepStale(x.sub, nil)
	if _, err := os.Stat(dead); err == nil {
		t.Error("the part of a dead pid was kept")
	}
	if _, err := os.Stat(live); err != nil {
		t.Error("the part of a live pid was swept")
	}
}
