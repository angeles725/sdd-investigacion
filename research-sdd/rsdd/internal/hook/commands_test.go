package hook

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

var hookNames = []string{"git-root", "wiring-state", "script-state", "launch-state", "wired-exec"}

func run(t *testing.T, args ...string) (out, errOut string, code int) {
	t.Helper()
	var o, e bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e,
		Env: func(string) string { return "" }, Clock: func() time.Time { return time.Unix(0, 0) }, Cwd: "/w"}
	code = cli.Run(Commands, args, s)
	return o.String(), e.String(), code
}

func TestCommandsValidate(t *testing.T) {
	if err := cli.Validate(Commands); err != nil {
		t.Fatal(err)
	}
	if len(Commands) != len(hookNames) {
		t.Errorf("%d commands registered, want %d", len(Commands), len(hookNames))
	}
}

// Each name reaches its own handler: with no argument every handler prints its own usage line.
func TestEachCommandReachesItsHandler(t *testing.T) {
	for _, name := range hookNames {
		out, errOut, code := run(t, "hook", name)
		if out != "" || code != cli.ExitUsage || !strings.Contains(errOut, "usage: rsdd hook "+name+" ") {
			t.Errorf("hook %s = (%q, %q, %d), want its own usage line and exit 2", name, out, errOut, code)
		}
	}
}

func TestHookGroupHelpListsTheCommands(t *testing.T) {
	out, _, code := run(t, "hook", "--help")
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, name := range hookNames {
		if !strings.Contains(out, name) {
			t.Errorf("hook --help does not list %s:\n%s", name, out)
		}
	}
}
