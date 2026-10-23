package commands

import (
	"bytes"
	"runtime/debug"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/golden"
)

func pin(t *testing.T, bi *debug.BuildInfo) {
	t.Helper()
	old := readBuildInfo
	readBuildInfo = func() (*debug.BuildInfo, bool) { return bi, bi != nil }
	t.Cleanup(func() { readBuildInfo = old })
}

func TestVersionGolden(t *testing.T) {
	pin(t, &debug.BuildInfo{
		Main:     debug.Module{Version: "v1.2.3"},
		Settings: []debug.BuildSetting{{Key: "vcs.revision", Value: "abc123"}},
	})
	golden.Run(t, "testdata/golden", Main)
}

func TestVersionUnknownWhenBuildInfoAbsent(t *testing.T) {
	pin(t, nil)
	golden.Run(t, "testdata/golden-nobuildinfo", Main)
}

func TestRealTableIsValid(t *testing.T) {
	if err := cli.Validate(Table); err != nil {
		t.Fatalf("the shipped command table is invalid: %v", err)
	}
}

func TestVersionRejectsUnknownFlagsAndArgs(t *testing.T) {
	pin(t, &debug.BuildInfo{Main: debug.Module{Version: "v1"}})
	for _, args := range [][]string{{"version", "--bogus"}, {"version", "extra"}} {
		var out, errOut bytes.Buffer
		code := Main(args, cli.Stdio{Out: &out, Err: &errOut})
		if code != cli.ExitUsage || out.Len() != 0 || errOut.Len() == 0 {
			t.Errorf("%v: got (%d, out=%q, err=%q), want exit 2, empty stdout, a stderr message", args, code, out.String(), errOut.String())
		}
	}
}

func pinSourceHash(t *testing.T, v string) {
	t.Helper()
	old := sourceHash
	sourceHash = v
	t.Cleanup(func() { sourceHash = old })
}

func TestVersionSourceHash(t *testing.T) {
	const val = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	for _, tt := range []struct{ name, set, want string }{
		{"embedded value", val, val + "\n"},
		{"unset", "", "sha256:unknown\n"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			pin(t, &debug.BuildInfo{Main: debug.Module{Version: "v1"}})
			pinSourceHash(t, tt.set)
			var out, errOut bytes.Buffer
			code := Main([]string{"version", "--source-hash"}, cli.Stdio{Out: &out, Err: &errOut})
			if code != cli.ExitOK || out.String() != tt.want || errOut.Len() != 0 {
				t.Errorf("got (%d, %q, %q), want (0, %q, \"\")", code, out.String(), errOut.String(), tt.want)
			}
		})
	}
}

func TestVersionSourceHashRejectsExtraArgsAndKeepsDefaultOutput(t *testing.T) {
	pin(t, &debug.BuildInfo{Main: debug.Module{Version: "v1"}})
	pinSourceHash(t, "sha256:abc")
	var out, errOut bytes.Buffer
	if code := Main([]string{"version", "--source-hash", "extra"}, cli.Stdio{Out: &out, Err: &errOut}); code != cli.ExitUsage || out.Len() != 0 {
		t.Errorf("extra arg: got (%d, %q)", code, out.String())
	}
	out.Reset()
	if code := Main([]string{"version"}, cli.Stdio{Out: &out, Err: &errOut}); code != cli.ExitOK || out.String() != "rsdd version v1 revision unknown\n" {
		t.Errorf("plain version must be unchanged: got (%d, %q)", code, out.String())
	}
}
