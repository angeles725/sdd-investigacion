package hook

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Port of templates/hook-kit-run.sh <kit-relative-script> [args...] (kit #2175): run a kit script with the kit
// resolved at RUN time (resolution order and its messages live in core/kit.ResolveKitScript).
//
// Contract, byte-equal to the bash original (frozen copy in testdata/legacy is the differential oracle): stdin and
// the exit code pass through to `bash <kit>/<rel> args...`; an unresolvable kit, an escaping path or a missing
// script is the typed `kit-run: DEGRADED: <why>; <rel> did NOT run` on stderr with exit 1, never an allow.
// EXCEPTION: for a script whose path ends in hook-pretool-pkill-guard.sh the hook fails CLOSED: a payload that
// mentions pkill/pgrep gets permissionDecision "ask" naming the cause (exit 0); any other payload passes (exit 0).
//
// Differences from `exec bash`: Go cannot replace its process, so it runs bash as a child with the inherited
// environment and returns its exit code (128+n for a child killed by signal n, as a shell reports it); the child's
// stdout appears when it finishes (the cli stdout contract). A bash that cannot be started is exit 127 with a
// typed line. HOME unset is read as empty (bash aborts under `set -u`; see core/kit DEFERRED.md).

const pkillGuardSuffix = "hook-pretool-pkill-guard.sh"

// KitRun is `rsdd hook kit-run <kit-relative-script> [args...]`.
func KitRun(args []string, s cli.Stdio) int {
	rel := ""
	if len(args) > 0 {
		rel = args[0]
	}
	if rel == "" {
		fmt.Fprintln(s.Err, "kit-run: DEGRADED: no script given")
		return cli.ExitOperational
	}
	path, warns, err := kit.ResolveKitScript(rel, kit.Getenv(s.Env))
	for _, w := range warns {
		fmt.Fprintln(s.Err, w)
	}
	if err != nil {
		return degraded(rel, err.Error(), s)
	}
	cmd := exec.Command("bash", append([]string{path}, args[1:]...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = s.In, s.Out, s.Err // Env nil: the child inherits the environment, as exec does
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			fmt.Fprintf(s.Err, "kit-run: DEGRADED: cannot start bash (%v); %s did NOT run\n", err, rel)
			return 127
		}
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return ee.ExitCode()
	}
	return cli.ExitOK
}

func degraded(rel, why string, s cli.Stdio) int {
	if !strings.HasSuffix(rel, pkillGuardSuffix) {
		fmt.Fprintf(s.Err, "kit-run: DEGRADED: %s; %s did NOT run\n", why, rel)
		return cli.ExitOperational
	}
	raw, _ := io.ReadAll(s.In) // `cat || true`: a read error is whatever was read
	in := string(bytes.ReplaceAll(raw, []byte{0}, nil))
	if strings.Contains(in, "pkill") || strings.Contains(in, "pgrep") {
		reason := "kit-run pkill-guard DEGRADED: " + why + "; this command mentions pkill/pgrep and cannot be checked for a self-matching -f pattern. Approve only if the pattern is bracket-escaped or uses -x/a PID."
		// jq -n without -c: indented by two spaces.
		fmt.Fprintf(s.Out, "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"PreToolUse\",\n    \"permissionDecision\": \"ask\",\n    \"permissionDecisionReason\": %s\n  }\n}\n", jqString(reason))
	}
	return cli.ExitOK
}

// jqString encodes s the way jq does, which is NOT encoding/json: no HTML escaping, lowercase \u00xx for control
// characters and DEL, U+2028 raw, invalid UTF-8 as U+FFFD. TODO(#2386): core/jsonout will own this.
func jqString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\u%04x`, r)
		default: // includes utf8.RuneError, written as U+FFFD, which is what jq prints for invalid bytes
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}
