package waitmerge

import (
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

func TestParseUsageErrors(t *testing.T) {
	const usage = "kit-wait-merge.sh [--base-ref REF] <worktree> <pr>"
	for _, c := range []struct {
		name string
		args []string
		want string // "" = accepted
	}{
		{"no arguments", nil, usage},
		{"one positional", []string{"wt"}, usage},
		{"--base-ref with its value and nothing else", []string{"--base-ref", "b"}, usage},
		{"--expect-head with its value and nothing else", []string{"--expect-head", "h"}, usage},
		{"three positionals", []string{"wt", "7", "x"}, usage},
		{"unknown option first", []string{"--bogus", "wt", "7"}, "unknown option --bogus"},
		{"unknown option after a flag", []string{"--base-ref", "b", "-x", "wt", "7"}, "unknown option -x"},
		{"option after the positionals", []string{"wt", "7", "--bogus"}, usage},
		{"--base-ref last", []string{"--base-ref"}, "--base-ref needs a value"},
		{"--expect-head last", []string{"--expect-head"}, "--expect-head needs a value"},
		{"--expect-head last after a flag", []string{"--base-ref", "b", "--expect-head"}, "--expect-head needs a value"},
		{"flag value may look like a flag", []string{"--base-ref", "--expect-head", "wt", "7"}, ""},
		{"pr empty", []string{"wt", ""}, "pr must be a number: "},
		{"pr letters", []string{"wt", "7a"}, "pr must be a number: 7a"},
		{"pr negative", []string{"wt", "-7"}, "pr must be a number: -7"},
		{"pr with space", []string{"wt", "7 8"}, "pr must be a number: 7 8"},
		{"pr digits", []string{"wt", "0123"}, ""},
		{"double dash", []string{"--", "wt", "7"}, ""},
		{"double dash then a dashed worktree", []string{"--", "-wt", "7"}, ""},
		{"double dash then too few", []string{"--", "7"}, usage},
		{"help wins over a later error", []string{"-h", "--bogus"}, ""},
		{"help after a flag", []string{"--base-ref", "b", "--help"}, ""},
		{"help after an error is never reached", []string{"--bogus", "--help"}, "unknown option --bogus"},
		{"all options", []string{"--base-ref", "b", "--expect-head", "abc", "wt", "7"}, ""},
	} {
		_, err := parse(c.args)
		got := ""
		if err != nil {
			got = err.Error()
		}
		if got != c.want {
			t.Errorf("%s: error %q, want %q", c.name, got, c.want)
		}
	}
}

func TestParseValues(t *testing.T) {
	o, err := parse([]string{"--base-ref", "B", "--expect-head", "H", "W", "42"})
	if err != nil || o.base != "B" || o.expectHead != "H" || o.wt != "W" || o.pr != "42" || o.help {
		t.Errorf("%+v %v", o, err)
	}
	if o, _ = parse([]string{"W", "1"}); o.base != "origin/main" || o.expectHead != "" {
		t.Errorf("defaults: %+v", o)
	}
	if o, _ = parse([]string{"--base-ref", "a", "--base-ref", "b", "W", "1"}); o.base != "b" {
		t.Errorf("the last --base-ref wins: %+v", o)
	}
	if o, err = parse([]string{"-h"}); err != nil || !o.help {
		t.Errorf("-h: %+v %v", o, err)
	}
}

func TestUsageLinesAndHelp(t *testing.T) {
	w := kitworld.New(t)
	r := goRun(t, w, []string{"--bogus"})
	if r.rc != 2 || r.out != "kit-wait-merge: usage: unknown option --bogus\n" || r.err != "" {
		t.Errorf("%+v", r)
	}
	r = goRun(t, w, []string{w.Dir + "/nope", "7"})
	if r.rc != 2 || r.out != "kit-wait-merge: usage: worktree is not a directory: "+w.Dir+"/nope\n" {
		t.Errorf("%+v", r)
	}
	r = goRun(t, w, []string{"--help"})
	if r.rc != 0 || r.err != "" || r.out != help || !strings.HasPrefix(r.out, "# kit-wait-merge.sh [--base-ref REF] [--expect-head SHA] <worktree> <pr>") ||
		!strings.Contains(r.out, "#   33  merged-out-of-band") {
		t.Errorf("%+v", r)
	}
}
