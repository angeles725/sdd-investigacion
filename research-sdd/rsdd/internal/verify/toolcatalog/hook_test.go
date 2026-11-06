package toolcatalog

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// stand-ins for the check, run by runHook in place of the real one.
func printing(out string, rc int) hookCheck {
	return func(dir string, l locale, o, e io.Writer) int {
		io.WriteString(o, out)
		return rc
	}
}

func panicking(string, locale, io.Writer, io.Writer) int { panic("boom") }

func hookRun(run hookCheck, args ...string) observed {
	var out, errb bytes.Buffer
	code := runHook(args, stdio(&out, &errb, "/cwd", "C"), run)
	return observed{out.String(), errb.String(), code}
}

func contextOfOutput(t *testing.T, o observed) string {
	t.Helper()
	return contextOf(t, o.stdout)
}

// Every could-not-run path of the hook is capped by hookenv.FailureContext and keeps the header and the last line.
func TestHookCapsEveryCouldNotRunPath(t *testing.T) {
	t.Parallel()
	long := strings.Repeat("a long line of failure output to be dropped\n", 80) + "the cause, last"
	for name, c := range map[string]struct {
		out    string
		rc     int
		header string
	}{
		"rc != 0":         {long, 1, "Research-SDD tool catalog check could not run (exit 1 — check INSTALLED-TOOLS.md and tool-registry.md):"},
		"rc 2":            {long, 2, "Research-SDD tool catalog check could not run (exit 2 — check INSTALLED-TOOLS.md and tool-registry.md):"},
		"missing Summary": {long, 0, "Research-SDD tool catalog check: missing Summary line — unexpected output from verify-tool-catalog.sh:"},
	} {
		got := hookRun(printing(c.out, c.rc))
		ctx := contextOfOutput(t, got)
		lines := strings.Split(ctx, "\n")
		if got.code != 0 || hookenv.Width(ctx) > hookenv.FailureCap || lines[0] != c.header || lines[len(lines)-1] != "the cause, last" ||
			!strings.Contains(ctx, "run `rsdd verify tool-catalog` for the full output") {
			t.Errorf("%s: exit %d, width %d, context %q", name, got.code, hookenv.Width(ctx), ctx)
		}
	}
}

// A panic inside the check is the could-not-run context, not silence (hookenv.Guard).
func TestHookPanicIsCouldNotRun(t *testing.T) {
	t.Parallel()
	got := hookRun(panicking)
	want := "Research-SDD tool catalog check could not run (exit 1 — check INSTALLED-TOOLS.md and tool-registry.md):\nrsdd: internal-error: boom"
	if ctx := contextOfOutput(t, got); got.code != 0 || ctx != want {
		t.Errorf("exit %d, context %q, want %q", got.code, ctx, want)
	}
}

// `--full` is read as the first argument, or the one after the directory; anything else is the directory or ignored.
func TestHookArguments(t *testing.T) {
	t.Parallel()
	drift := warn("a") + "\n" + warn("b") + "\n" + summary("2", "0", "2")
	var dirs []string
	spy := func(dir string, l locale, o, e io.Writer) int {
		dirs = append(dirs, dir)
		io.WriteString(o, drift)
		return 0
	}
	for _, c := range []struct {
		args []string
		dir  string
		full bool
	}{
		{nil, "/cwd", false},
		{[]string{"--full"}, "/cwd", true},
		{[]string{"/d"}, "/d", false},
		{[]string{"/d", "--full"}, "/d", true},
		{[]string{"/d", "x", "--full"}, "/d", false},
		{[]string{"--full", "/d"}, "/cwd", true},
		{[]string{"/d", "--fullx"}, "/d", false},
	} {
		dirs = nil
		ctx := contextOfOutput(t, hookRun(spy, c.args...))
		if len(dirs) != 1 || dirs[0] != c.dir {
			t.Errorf("%v: ran in %v, want %s", c.args, dirs, c.dir)
		}
		if full := strings.Contains(ctx, "\n"+warn("a")+"\n"); full != c.full {
			t.Errorf("%v: full = %v, want %v: %q", c.args, full, c.full, ctx)
		}
	}
}

// The hook runs the check in the locale of its environment.
func TestHookPassesTheLocale(t *testing.T) {
	t.Parallel()
	var got []locale
	for _, loc := range locales {
		var out, errb bytes.Buffer
		runHook(nil, stdio(&out, &errb, "/cwd", loc), func(dir string, l locale, o, e io.Writer) int {
			got = append(got, l)
			return 0
		})
	}
	if len(got) != 2 || got[0].utf8 || !got[1].utf8 {
		t.Errorf("locales seen %v, want the C locale then UTF-8", got)
	}
}
