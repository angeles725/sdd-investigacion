package parallelfloor

import (
	"flag"
	"strconv"
	"strings"
	"testing"
)

// set registers -test.parallel with def and parses args, as the test binary does.
func set(t *testing.T, def string, args ...string) *flag.FlagSet {
	t.Helper()
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	fs.String(flagName, def, "")
	if err := fs.Parse(args); err != nil {
		t.Fatal(err)
	}
	return fs
}

func value(fs *flag.FlagSet) string { return fs.Lookup(flagName).Value.String() }

func TestRaise(t *testing.T) {
	cases := []struct {
		name, def string
		args      []string
		min       int
		want      string
	}{
		{"default below the floor is raised", "2", nil, 8, "8"},
		{"default one below the floor is raised", "7", nil, 8, "8"},
		{"default at the floor stays", "8", nil, 8, "8"},
		{"default above the floor stays", "16", nil, 8, "16"},
		{"explicit value below the floor wins", "2", []string{"-" + flagName + "=1"}, 8, "1"},
		{"explicit value equal to the default wins", "2", []string{"-" + flagName + "=2"}, 8, "2"},
	}
	for _, c := range cases {
		fs := set(t, c.def, c.args...)
		if err := raise(fs, c.min); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got := value(fs); got != c.want {
			t.Errorf("%s: -%s = %s, want %s", c.name, flagName, got, c.want)
		}
	}
}

// counting is a flag.Value that records every Set, so a test can tell "left alone" from "rewritten to the same value".
type counting struct {
	v    string
	sets int
}

func (c *counting) String() string     { return c.v }
func (c *counting) Set(s string) error { c.v, c.sets = s, c.sets+1; return nil }

// A value already at or above the floor is never rewritten, not merely rewritten to the same number.
func TestRaiseLeavesAValueAtTheFloorUntouched(t *testing.T) {
	for _, c := range []struct {
		def      string
		min      int
		wantSets int
	}{{"8", 8, 0}, {"9", 8, 0}, {"7", 8, 1}} {
		v := &counting{v: c.def}
		fs := flag.NewFlagSet("t", flag.ContinueOnError)
		fs.Var(v, flagName, "")
		if err := raise(fs, c.min); err != nil {
			t.Fatal(err)
		}
		if v.sets != c.wantSets {
			t.Errorf("default %s, floor %d: %d Set call(s), want %d", c.def, c.min, v.sets, c.wantSets)
		}
	}
}

func TestRaiseWithoutTheFlagIsANoOp(t *testing.T) {
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	fs.String("other", "x", "")
	if err := raise(fs, 8); err != nil || fs.Lookup("other").Value.String() != "x" {
		t.Fatalf("err = %v, other = %s; want no error and nothing changed", err, fs.Lookup("other").Value)
	}
}

func TestRaiseRefusesANonIntegerValue(t *testing.T) {
	fs := set(t, "many")
	err := raise(fs, 8)
	if err == nil || !strings.Contains(err.Error(), `-test.parallel is "many", not an integer`) || value(fs) != "many" {
		t.Fatalf("err = %v, value = %s; want the typed error and the value unchanged", err, value(fs))
	}
}

// TestRaiseOnTheTestBinary runs the exported entry point on this binary's own flag set, which go test parsed
// before the tests ran: the value is at least the floor unless -parallel was given explicitly.
func TestRaiseOnTheTestBinary(t *testing.T) {
	explicit := false
	flag.Visit(func(f *flag.Flag) { explicit = explicit || f.Name == flagName })
	before := value(flag.CommandLine)
	Raise(4)
	got := value(flag.CommandLine)
	n, err := strconv.Atoi(got)
	switch {
	case err != nil:
		t.Fatalf("-parallel = %q after Raise(4), not an integer", got)
	case explicit && got != before:
		t.Fatalf("explicit -parallel %s was changed to %s", before, got)
	case !explicit && n < 4:
		t.Fatalf("-parallel = %d after Raise(4), want at least 4", n)
	}
}
