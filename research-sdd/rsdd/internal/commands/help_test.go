package commands

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime/debug"
	"slices"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/golden"
)

// helpTable is the fixed table the help and no-args goldens render (#2385). The goldens pin the cli
// boundary's rendering, not the shipped registry, so registering a command never changes them.
var helpTable = []cli.Command{
	versionCommand,
	{Name: "alpha", Group: "grp", Summary: "a grouped command", Run: func([]string, cli.Stdio) int { return cli.ExitOK }},
}

func helpMain(args []string, s cli.Stdio) int { return cli.Run(helpTable, args, s) }

func TestHelpGoldensRenderTheFixedTable(t *testing.T) {
	pin(t, &debug.BuildInfo{Main: debug.Module{Version: "v1.2.3"}})
	golden.Run(t, "testdata/golden-help", helpMain)
}

// The real-table golden set must hold no case whose output lists commands: such a case would change
// every time a porting unit registers one.
func TestRealTableGoldensDoNotListCommands(t *testing.T) {
	cases, err := filepath.Glob("testdata/golden/*/stdout")
	if err != nil || len(cases) == 0 {
		t.Fatalf("no real-table golden cases found (err=%v)", err)
	}
	more, _ := filepath.Glob("testdata/golden/*/stderr")
	for _, f := range append(cases, more...) {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(b, []byte("\nCommands:\n")) {
			t.Errorf("%s lists commands; move the case to testdata/golden-help (fixed table)", f)
		}
	}
}

// The shipped table's help: it renders, lists every entry exactly once, and the listing is sorted.
func TestRealTableHelpListsEveryCommandOnceSorted(t *testing.T) {
	pin(t, &debug.BuildInfo{Main: debug.Module{Version: "v1"}})
	var out, errOut bytes.Buffer
	if code := Main([]string{"--help"}, cli.Stdio{Out: &out, Err: &errOut}); code != cli.ExitOK || errOut.Len() != 0 {
		t.Fatalf("--help: exit %d, stderr %q", code, errOut.String())
	}
	_, list, ok := strings.Cut(out.String(), "\nCommands:\n")
	if !ok {
		t.Fatalf("no Commands: section in\n%s", out.String())
	}
	var got []string
	for _, line := range strings.Split(strings.TrimSuffix(list, "\n"), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		label := strings.TrimSpace(line[:min(len(line), 27)])
		got = append(got, label)
	}
	want := make([]string, 0, len(Table))
	for _, c := range Table {
		want = append(want, cmdLabel(c))
	}
	slices.Sort(want)
	if !slices.Equal(got, want) {
		t.Fatalf("help listing\n%q\nwant every Table entry once, sorted:\n%q", got, want)
	}
	if !slices.IsSorted(got) {
		t.Fatalf("listing not sorted: %q", got)
	}
}
