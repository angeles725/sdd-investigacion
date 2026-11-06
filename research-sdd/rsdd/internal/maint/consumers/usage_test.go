package consumers

import (
	"strings"
	"testing"
)

const wantUsage = "usage: rsdd maint consumers [--repo DIR] [--refs] [--script NAME]\n"

func TestUsageErrors(t *testing.T) {
	f := newFixture(t)
	cases := []struct {
		name, why string
		args      []string
	}{
		{"unknown flag", "unknown argument: --bogus", []string{"--bogus"}},
		{"a positional argument", "unknown argument: extra", []string{"extra"}},
		{"--repo without a value", "--repo needs a value", []string{"--repo"}},
		{"--repo with an empty value", "--repo needs a value", []string{"--repo", ""}},
		{"--script without a value", "--script needs a value", []string{"--script"}},
		{"--script with an empty value", "--script needs a value", []string{"--refs", "--script", ""}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := f.run(c.args...)
			want := ran{"", "consumers: " + c.why + "\n" + wantUsage, 2}
			if got != want {
				t.Fatalf("got %+v, want %+v", got, want)
			}
		})
	}
}

func TestHelp(t *testing.T) {
	f := newFixture(t)
	for _, a := range []string{"-h", "--help"} {
		got := f.run(a)
		if got.rc != 0 || got.err != "" || !strings.HasPrefix(got.out, "rsdd maint consumers") || got.out != help {
			t.Fatalf("%s: rc %d, err %q, out %q", a, got.rc, got.err, got.out)
		}
	}
}
