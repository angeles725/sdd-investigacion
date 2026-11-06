package verify

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// bigPanic is a panic value of many lines: what a crash with a long stack-like message puts in a hook's buffer.
func bigPanic() string {
	var b strings.Builder
	for i := 0; i < 400; i++ {
		fmt.Fprintf(&b, "frame %03d: some/package.function(...)\n", i)
	}
	return "first line of the failure\n" + b.String() + "last line: the real cause"
}

// A hook whose body panics with a long message still prints at most its share of the session budget (#2631), keeps
// the cause printed last, and names a command that exists in this domain's table.
func TestVerifyHooksCapTheirFailureContext(t *testing.T) {
	hooks := []struct {
		name, header, rerun string
		run                 func([]string, cli.Stdio) int
	}{
		{"registry-hook", fmt.Sprintf(hdrRegistryCouldNo, cli.ExitOperational), registryRerun, RunRegistryHook},
		{"kit-clean-hook", hdrInternal, kitCleanRerun, RunKitCleanHook},
		{"skill-drift-hook", hdrCannotRun, skillDriftRerun, runSkillDriftHook},
	}
	for _, h := range hooks {
		t.Run(h.name, func(t *testing.T) {
			var out, errb bytes.Buffer
			s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Cwd: t.TempDir(),
				Env:     func(string) string { panic(bigPanic()) },
				Environ: func() []string { return nil }, Clock: func() time.Time { return time.Unix(0, 0) }}
			if rc := h.run(nil, s); rc != cli.ExitOK {
				t.Fatalf("rc %d: a hook never fails the session", rc)
			}
			var env struct {
				HookSpecificOutput struct{ AdditionalContext string }
			}
			if err := json.Unmarshal(out.Bytes(), &env); err != nil {
				t.Fatalf("stdout is not one JSON object: %v\n%s", err, out.String())
			}
			ctx := env.HookSpecificOutput.AdditionalContext
			if w := hookenv.Width(ctx); w > hookenv.FailureCap {
				t.Errorf("context width %d > cap %d", w, hookenv.FailureCap)
			}
			if !strings.HasPrefix(ctx, h.header+"\n") || !strings.HasSuffix(ctx, "\nlast line: the real cause") ||
				!strings.Contains(ctx, "line(s) dropped") || !strings.Contains(ctx, "`"+h.rerun+"`") {
				t.Errorf("context:\n%s", ctx)
			}
		})
	}
}

// Each rerun hint names a command of this domain (kit issue #2631: a hint naming a missing command is a defect).
func TestVerifyHookRerunCommandsExist(t *testing.T) {
	for _, r := range []string{registryRerun, kitCleanRerun, skillDriftRerun} {
		f := strings.Fields(r)
		found := false
		for _, c := range Commands {
			found = found || (len(f) == 3 && f[0] == "rsdd" && f[1] == c.Group && f[2] == c.Name)
		}
		if !found {
			t.Errorf("%q names no command of the verify table", r)
		}
	}
}

// The skill-drift check that could not run (rc >= 2) is capped too, and keeps its last line (#2631).
func TestSkillDriftCouldNotRunIsCapped(t *testing.T) {
	t.Parallel()
	w := hookWorld(t)
	w.env["HOME"] = ""
	w.installStub(`for i in $(seq 1 60); do echo "verify harness=h$i status=drift detail=a-long-enough-reason-to-fill-the-session-budget"; done; echo 'verify kit status=behind by 3'`)
	out, errs, rc := w.runGoHook()
	var env struct {
		HookSpecificOutput struct{ AdditionalContext string }
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil || errs != "" || rc != 0 {
		t.Fatalf("rc %d, stderr %q, stdout %q: %v", rc, errs, out, err)
	}
	ctx := env.HookSpecificOutput.AdditionalContext
	if w := hookenv.Width(ctx); w > hookenv.FailureCap {
		t.Errorf("width %d > cap %d", w, hookenv.FailureCap)
	}
	if !strings.HasPrefix(ctx, hdrCannot+"\n") || !strings.Contains(ctx, "`"+skillDriftRerun+"`") || !strings.Contains(ctx, "line(s) dropped") ||
		!strings.HasSuffix(ctx, "\nverify kit status=behind by 3") {
		t.Errorf("context:\n%s", ctx)
	}
}
