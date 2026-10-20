package commands

import (
	"runtime/debug"
	"testing"

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
