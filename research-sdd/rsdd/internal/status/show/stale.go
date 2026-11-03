package show

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os/exec"
	"path"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The STALE gate of --next: refuse to hand out work on an internally inconsistent corpus. verify-state is the
// toolbelt's verify-state.sh, run as the script ran it (a domain cannot import another domain); a test swaps the
// variable for a recorded report.
var verifyState = execVerify

// execVerify runs "$here/verify-state.sh" args... with the caller's stdout, stderr and working directory. The
// script's own directory is RSDD_TOOLBELT_DIR (the shim hands it over, as verify state's own shim does): without
// it, or without the script, the shell's answer is 127, and a script that cannot be executed is 126.
func execVerify(args []string, s cli.Stdio) int {
	dir := s.Env("RSDD_TOOLBELT_DIR")
	if dir == "" {
		return 127
	}
	cmd := exec.Command(dir+"/verify-state.sh", args...)
	cmd.Dir, cmd.Stdout, cmd.Stderr = s.Cwd, s.Out, s.Err
	if s.Environ != nil {
		cmd.Env = s.Environ()
	}
	err := cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &ee):
		if ee.Exited() {
			return ee.ExitCode()
		}
		return 128 // killed by a signal: the shell reports 128+n
	case errors.Is(err, fs.ErrNotExist):
		return 127
	}
	return 126
}

// verifyArgs is the argv the script gives verify-state: the target, and one focus when asked.
func verifyArgs(target string, focus ...string) []string {
	if len(focus) == 0 {
		return []string{target}
	}
	return []string{target, "--focus", focus[0]}
}

// verifyReport runs verify-state with its stderr dropped and answers its stdout and exit code.
func (c *ctx) verifyReport(args []string) (string, int) {
	var buf bytes.Buffer
	s := c.s
	s.Out, s.Err = &buf, io.Discard
	rc := verifyState(args, s)
	return buf.String(), rc
}

// verifyOK is `verify-state.sh ... >/dev/null 2>&1`: true when the report is clean.
func (c *ctx) verifyOK(args []string) bool {
	s := c.s
	s.Out, s.Err = io.Discard, io.Discard
	return verifyState(args, s) == 0
}

// staleGate is `if ! _gate_verify; then ...`: true when the run is over because it printed STALE. With --focus the
// gate verifies that focus alone; without it the gate is corpus-wide, but a failure that comes only from stopped or
// paused focuses (a stale envelope nobody re-seeded, kit #194 and #641) is forgiven when an active sibling exists.
func (c *ctx) staleGate() bool {
	focus := c.opts.focus
	args := verifyArgs(c.target)
	if focus != "" {
		args = verifyArgs(c.target, focus)
	}
	if c.verifyOK(args) {
		return false
	}
	states := c.listStates()
	// A stopped focus must have an active sibling to fall through to: a single-file corpus with a failing
	// verify-state always surfaces as STALE.
	if focus != "" || len(states) < 2 {
		c.staleLine()
		return true
	}
	for _, st := range states {
		c.state = st
		if _, skip := c.focusStopped(st); skip { // N194-FOCUSES-SKIP, before the priority guard (N641)
			continue
		}
		if c.hasInvalidPriority() || c.activeFocusStale() {
			c.staleLine()
			return true
		}
	}
	return false // every failure came from a stopped focus: fall through to the aggregation
}

// hasInvalidPriority is `grep -q '^INVALID_PRIORITY' < <(backlog_rows 2>/dev/null)`: an unparseable backlog is a
// real failure for an ACTIVE focus (concealment hazard).
func (c *ctx) hasInvalidPriority() bool {
	for _, l := range splitLines(c.rows(false)) {
		if strings.HasPrefix(l, "INVALID_PRIORITY") {
			return true
		}
	}
	return false
}

// activeFocusStale mirrors verify-state CHECK B and CHECK D for a focus that still has investigable gaps: no
// envelope (an absent investigable_open), an investigable_open that is not the derived count, or declared full coverage (gaps_closed ==
// known_gaps > 0). A focus with nothing investigable is genuinely stopped, and its stale envelope is bypassed.
func (c *ctx) activeFocusStale() bool {
	n, _ := c.countInvestigable()
	if n == 0 {
		return false
	}
	if e, _ := c.envGet("investigable_open"); e != fmt.Sprint(n) {
		return true
	}
	gc, _ := c.envGet("gaps_closed")
	kg, _ := c.envGet("known_gaps")
	k, ok := intOf(kg)
	return ok && k > 0 && gc == kg
}

// staleLine prints the STALE line: in a multi-focus corpus (corpus-wide mode) it names the focuses whose own
// verify-state fails, and it always ends with the first failing check and the file it belongs to (kit #1544).
func (c *ctx) staleLine() {
	line := "STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh " + c.target
	focus := c.opts.focus
	var ff string
	switch states := c.listStates(); {
	case focus != "":
		ff = c.firstFailure(verifyArgs(c.target, focus))
	case len(states) >= 2:
		var failing []string
		for _, f := range states {
			slug, ok := strings.CutPrefix(strings.TrimSuffix(path.Base(f), ".md"), "RESEARCH-STATE-")
			if ok && slug != "" && !c.verifyOK(verifyArgs(c.target, slug)) {
				failing = append(failing, slug)
			}
		}
		if len(failing) == 0 {
			// No focus file fails on its own (a stale ROOT, or a corpus-wide-only check): the corpus-wide run names it.
			ff = c.firstFailure(verifyArgs(c.target))
		} else {
			line += " [failing focus: " + strings.Join(failing, ",") + "]"
			ff = c.firstFailure(verifyArgs(c.target, failing[0]))
		}
	default:
		ff = c.firstFailure(verifyArgs(c.target))
	}
	fmt.Fprintf(c.s.Out, "%s [first failure: %s]\n", line, ff)
}

// firstFailure is _first_failure: the first FAIL line of a verify-state report with the file header it sits under,
// or the typed `unavailable` pointer when the report holds none (never omitted).
func (c *ctx) firstFailure(args []string) string {
	out, rc := c.verifyReport(args)
	if ff := firstFailureLine(out); ff != "" {
		return ff
	}
	return fmt.Sprintf("unavailable — verify-state printed no FAIL line (rc=%d)", rc)
}

// firstFailureLine is the awk of _first_failure over a report. A FAIL line ending in ':' also carries the value
// line that follows. The text is cut at ~160 BYTES on a character boundary (continuation bytes backed off).
func firstFailureLine(report string) string {
	var file, text string
	pending := false
	emit := func() string {
		if len(text) > 160 {
			n := 157
			for n > 0 && text[n] >= 0x80 && text[n] <= 0xBF {
				n--
			}
			text = text[:n] + "..."
		}
		if file == "" {
			file = "?"
		}
		return file + ": " + text
	}
	for _, rec := range strings.Split(strings.TrimRight(report, "\n"), "\n") { // $(...) drops the trailing newlines
		if rest, ok := strings.CutPrefix(rec, "== verify-state: "); ok {
			file, _, _ = strings.Cut(rest, " (target: ")
			continue
		}
		if pending {
			text += " " + strings.TrimLeft(rec, " \t")
			return emit()
		}
		if rest, ok := strings.CutPrefix(rec, "   FAIL   "); ok {
			if text = rest; !strings.HasSuffix(text, ":") {
				return emit()
			}
			pending = true
		}
	}
	if pending {
		return emit()
	}
	return ""
}
