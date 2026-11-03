package verifyretro

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// The Options.Read seam: the unreadable exit 2 is reached without chmod, so it holds for root too.
func TestRunUnreadableThroughTheReadSeam(t *testing.T) {
	boom := errors.New("injected read failure")
	fail := func(err error) func(string) (*retrogrammar.Doc, error) {
		return func(string) (*retrogrammar.Doc, error) { return nil, err }
	}
	for _, c := range []struct {
		name  string
		arg   string
		read  func(string) (*retrogrammar.Doc, error)
		state State
	}{
		{"read error on a .md file", "a.md", fail(boom), StateUnreadable},
		{"the unreadable sentinel", "a.md", fail(retrogrammar.ErrUnreadable), StateUnreadable},
		{"read error on a non-.md file is not-md", "a.txt", fail(boom), StateNotMarkdown},
		{"absent input beats the suffix", "a.txt", fail(retrogrammar.ErrAbsentInput), StateAbsent},
		{"absent input on a .md file", "a.md", fail(retrogrammar.ErrAbsentInput), StateAbsent},
		{"a successful read is checked", "a.md", func(p string) (*retrogrammar.Doc, error) { return retrogrammar.Parse(p, cConform), nil }, StateConforming},
	} {
		rep, err := Run(context.Background(), Options{Args: []string{c.arg}, Read: c.read})
		if err != nil || rep.State != c.state {
			t.Errorf("%s: state %v err %v, want state %v", c.name, rep.State, err, c.state)
		}
	}
}

func TestReadSeamReceivesTheResolvedPathAndRendersExit2(t *testing.T) {
	var got string
	read := func(p string) (*retrogrammar.Doc, error) { got = p; return nil, errors.New("boom") }
	rep, _ := Run(context.Background(), Options{Args: []string{"r.md"}, Cwd: "/w", Read: read})
	if got != "/w/r.md" {
		t.Errorf("Read got %q, want /w/r.md", got)
	}
	var so, se bytes.Buffer
	if rc := rep.Render(&so, &se); rc != 2 || so.Len() != 0 || se.String() != "ERROR: file not readable (absent-input): r.md\n" {
		t.Errorf("rc %d out %q err %q", rc, so.String(), se.String())
	}
}
