package show

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/cleancheck"
)

// The terminal no-garbage warning (terminal_clean_warn, kit #1277 slice 2; METHODOLOGY §15, contract
// clean-check.v1.md). An exhausted STOP, with or without the issue-coverage marker, runs clean-check.sh over the
// target and echoes its findings to STDERR as a loud WARN. Report-only: stdout, the verdict line, the --emit-token
// mapping and the exit code are unchanged. Three states (§7): clean (one INFO line), findings (a WARN per line) and
// unverifiable (a typed WARN for a timeout or exit 2/3) — never a silent zero.
// RSDD_STATUS_NO_CLEAN_CHECK=1 skips it (the caller already ran clean-check).

const cleanCheckDefaultSecs = 20

// terminalCleanWarn runs core/cleancheck in process (tool-registry.d/research-sdd-status.md divergence rows (22)-(24)):
// there is no clean-check.sh to look up, and the deadline of the context stops the git children it starts.
func (c *ctx) terminalCleanWarn() {
	if c.s.Env("RSDD_STATUS_NO_CLEAN_CHECK") == "1" {
		return
	}
	secs := c.cleanCheckSecs()
	now := c.s.Clock
	if now == nil {
		now = time.Now
	}
	// Tmp, Scratchpad and UID stay empty: Check reads TMPDIR, CLEAN_CHECK_SCRATCHPAD and CLEAN_CHECK_UID from Env.
	o := cleancheck.Options{Target: c.target, Env: c.s.Environment(), Cwd: c.s.Cwd, Now: now}
	cx, cancel := context.WithTimeout(context.Background(), time.Duration(secs)*time.Second)
	defer cancel()
	r := cleanCheckRun(cx, o)
	out := strings.TrimRight(r.Merged(), "\n") // `$(... 2>&1)`: both streams in print order, trailing newlines dropped
	switch r.Exit {
	case 124:
		c.warnf("WARN: clean-check: unverifiable (timed out after %ds) — terminal no-garbage check NOT confirmed\n", secs)
	case 0:
		c.warnf("INFO: clean-check: clean at terminal STOP\n")
	case 1:
		c.warnf("WARN: clean-check: findings at terminal STOP — resolve or declare in <target>/.research-sdd/keep.txt before closing\n")
		for _, l := range strings.Split(out, "\n") {
			c.warnf("WARN: clean-check: %s\n", l)
		}
	default:
		last := out[strings.LastIndex(out, "\n")+1:]
		c.warnf("WARN: clean-check: unverifiable (exit %d: %s) — terminal no-garbage check NOT confirmed\n", r.Exit, last)
	}
}

// cleanCheckSecs is RSDD_STATUS_CLEAN_CHECK_TIMEOUT: an exact positive integer (digits only, non-zero once leading
// zeros are stripped; 010 is 10). Anything else is named and the default 20 is used: GNU timeout reads 0 as "no
// limit", so a zero is never passed through.
func (c *ctx) cleanCheckSecs() int {
	v := c.s.Env("RSDD_STATUS_CLEAN_CHECK_TIMEOUT")
	if v == "" {
		return cleanCheckDefaultSecs
	}
	stripped := strings.TrimLeft(v, "0")
	if strings.Trim(v, "0123456789") != "" || stripped == "" {
		c.warnf("WARN: clean-check: invalid RSDD_STATUS_CLEAN_CHECK_TIMEOUT=%s (need an integer >= 1) — using %d\n", v, cleanCheckDefaultSecs)
		return cleanCheckDefaultSecs
	}
	n, err := strconv.Atoi(stripped)
	if err != nil {
		n = 1 << 30
	}
	return min(n, 1<<30) // 1<<30: a value timeout(1) takes as effectively unbounded
}
