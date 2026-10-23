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
