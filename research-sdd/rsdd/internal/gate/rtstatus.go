package gate

import (
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// The bounded status call of the return-token gate (moved out of returntoken.go unchanged).

// runStatus is `timeout SECS bash STATUS TARGET --next --emit-token 2>/dev/null`: stdout, the exit code `timeout`
// would report (125 for a bad duration, 127 when bash cannot start, 128+N for a signal) and whether the bound hit.
func (g *rtGate) runStatus(status, tgt, secs string) (out string, rc int, timedOut bool) {
	d, ok := parseTimeout(secs)
	if !ok {
		return "", 125, false
	}
	bash, err := probe.New([]string{"PATH=" + g.s.Env("PATH")}, g.s.Cwd).LookPath("bash")
	if err != nil {
		return "", 127, false
	}
	// Env nil: exec.Cmd inherits the process environment, exactly like the child of the bash hook.
	res, err := proc.Run(proc.Spec{Argv: []string{bash, status, tgt, "--next", "--emit-token"}, Timeout: d, MaxBytes: 16 << 20})
	switch {
	case err != nil:
		return "", 127, false
	case res.Reason == proc.ReasonTimeout:
		return "", 124, true
	case res.ReturnCode < 0:
		return string(res.Stdout), 128 - res.ReturnCode, false
	}
	return string(res.Stdout), res.ReturnCode, false
}

// parseTimeout is GNU timeout's DURATION: a non-negative number with an optional s, m, h or d suffix; 0 disables
// the bound (here: a day). ok is false for what timeout rejects with its exit 125.
func parseTimeout(v string) (time.Duration, bool) {
	unit := time.Second
	if n := len(v); n > 0 {
		switch v[n-1] {
		case 's':
			v = v[:n-1]
		case 'm':
			unit, v = time.Minute, v[:n-1]
		case 'h':
			unit, v = time.Hour, v[:n-1]
		case 'd':
			unit, v = 24*time.Hour, v[:n-1]
		}
	}
	if v == "" || strings.ContainsAny(v[:1], "+-") {
		return 0, false
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil || f < 0 || math.IsNaN(f) {
		return 0, false
	}
	if f == 0 || f*float64(unit) > float64(24*time.Hour) {
		return 24 * time.Hour, true
	}
	d := time.Duration(f * float64(unit))
	if d <= 0 {
		d = time.Nanosecond
	}
	return d, true
}
