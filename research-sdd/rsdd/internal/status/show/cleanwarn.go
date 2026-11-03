package show

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// The terminal no-garbage warning (terminal_clean_warn, kit #1277 slice 2; METHODOLOGY §15, contract
// clean-check.v1.md). An exhausted STOP, with or without the issue-coverage marker, runs clean-check.sh over the
// target and echoes its findings to STDERR as a loud WARN. Report-only: stdout, the verdict line, the --emit-token
// mapping and the exit code are unchanged. Three states (§7): clean (one INFO line), findings (a WARN per line) and
// unverifiable (a typed WARN for a missing script, a timeout or exit 2/3) — never a silent zero.
// RSDD_STATUS_NO_CLEAN_CHECK=1 skips it (the caller already ran clean-check).

const cleanCheckDefaultSecs = 20

// cleanCheckGrace is the kill grace of `timeout -k 5`.
const cleanCheckGrace = 5 * time.Second

func (c *ctx) terminalCleanWarn() {
	if c.s.Env("RSDD_STATUS_NO_CLEAN_CHECK") == "1" {
		return
	}
	script, ok := c.toolbeltFile("clean-check.sh")
	if st, err := os.Stat(script); !ok || err != nil || !st.Mode().IsRegular() {
		c.warnf("WARN: clean-check: unverifiable (clean-check.sh not found beside research-sdd-status.sh) — terminal no-garbage check NOT run\n")
		return
	}
	secs := c.cleanCheckSecs()
	r := cleanCheckRun(script, c.target, time.Duration(secs)*time.Second, c.s)
	out := strings.TrimRight(r.out+r.err, "\n") // `$(... 2>&1)`: both streams, trailing newlines dropped
	switch r.rc {
	case 124, 137:
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
		c.warnf("WARN: clean-check: unverifiable (exit %d: %s) — terminal no-garbage check NOT confirmed\n", r.rc, last)
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
	if err != nil || n > 1<<30 {
		return 1 << 30 // a value timeout(1) takes as effectively unbounded
	}
	return n
}
