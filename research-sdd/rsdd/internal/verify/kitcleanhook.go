package verify

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// Port of research-sdd/toolbelt/verify-kit-clean-hook.sh, the SessionStart wrapper of verify kit-clean:
//
//	rsdd verify kit-clean-hook [<kit-repo>]
//
// Silent (no output) when the kit is clean. Otherwise it prints the SessionStart envelope whose
// additionalContext is a header and the full stdout+stderr of the check. Like the script it always exits 0:
// a hook never fails the session. The header differs for exit 1 (dirty or unpushed) and any other code (the
// check could not run).
//
// Difference, by design: the script printed plain text when jq was missing; the envelope is built here with
// no jq, so it is always the JSON contract of the harness.
//
// The envelope encoder (core/hookenv) is pinned to jq's output by differential_test.go; a panic inside the check
// is turned into the could-not-run envelope by hookenv.Guard (kit issue #2610). lib/hook-emit.sh stays bash: it is
// the degraded path when rsdd cannot run.

const (
	hdrNotClean = "Research-SDD KIT is NOT clean — commit/stash + push before staging §18 retros (else the retro branch/PR mixes unrelated history):"
	hdrInternal = "Research-SDD kit-clean check could not run (internal error):"
	hdrCouldNot = "Research-SDD kit-clean check could not run (exit %d — misconfigured path or not a git repo):"
)

// RunKitCleanHook is the `verify kit-clean-hook` command.
func RunKitCleanHook(args []string, s cli.Stdio) int {
	var buf bytes.Buffer // one writer for both streams, so the order is the script's `2>&1`
	finished := false
	rc := hookenv.Guard(&buf, func() int {
		r := kitClean(repoArg(args), s.Cwd, &buf, &buf, gitRunner(s))
		finished = true
		return r
	})
	if rc == 0 {
		return cli.ExitOK
	}
	hdr := hdrNotClean // exit 1 is a dirty kit, which is also the code a panic maps to: `finished` tells them apart
	switch {
	case !finished:
		hdr = hdrInternal
	case rc != 1:
		hdr = fmt.Sprintf(hdrCouldNot, rc)
	}
	hookenv.WriteSessionStart(s.Out, hdr+"\n"+strings.TrimRight(buf.String(), "\n"))
	return cli.ExitOK
}
