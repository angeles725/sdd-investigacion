//go:build unix

package proc

import (
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"syscall"
)

// Helper exit codes, as env(1) uses them: 125 the helper itself failed
// (usage, a limit it could not set), 127 the program could not be executed.
const (
	helperFailed = 125
	execFailed   = 127
)

// resources maps a Limit's Resource name to its rlimit.
var resources = map[string]int{
	"as":     syscall.RLIMIT_AS,
	"core":   syscall.RLIMIT_CORE,
	"cpu":    syscall.RLIMIT_CPU,
	"data":   syscall.RLIMIT_DATA,
	"fsize":  syscall.RLIMIT_FSIZE,
	"nofile": syscall.RLIMIT_NOFILE,
	"stack":  syscall.RLIMIT_STACK,
}

// formatLimits renders limits as the helper's LIMITS argument:
// comma-separated name=value pairs, "" for none.
func formatLimits(limits []Limit) string {
	parts := make([]string, len(limits))
	for i, l := range limits {
		parts[i] = l.Resource + "=" + strconv.FormatUint(l.Value, 10)
	}
	return strings.Join(parts, ",")
}

// parseLimits is the inverse of formatLimits; an unknown resource or a
// malformed pair is an error, never skipped.
func parseLimits(spec string) ([]Limit, error) {
	if spec == "" {
		return nil, nil
	}
	var out []Limit
	for _, pair := range strings.Split(spec, ",") {
		name, value, ok := strings.Cut(pair, "=")
		if _, known := resources[name]; !ok || !known {
			return nil, fmt.Errorf("bad limit %q: want <resource>=<value> with resource one of as, core, cpu, data, fsize, nofile, stack", pair)
		}
		v, err := strconv.ParseUint(value, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("bad limit %q: %w", pair, err)
		}
		out = append(out, Limit{name, v})
	}
	return out, nil
}

// lower sets soft and hard of l to min(l.Value, current hard): an
// unprivileged process can always lower a limit, never raise its hard one.
func lower(l Limit) error {
	res := resources[l.Resource]
	var cur syscall.Rlimit
	if err := syscall.Getrlimit(res, &cur); err != nil {
		return err
	}
	v := min(l.Value, cur.Max)
	return syscall.Setrlimit(res, &syscall.Rlimit{Cur: v, Max: v})
}

// HelperMain is the body of `rsdd __exec LIMITS PATH ARGV0 [ARG...]`, run in
// the freshly started child: it lowers every limit and then replaces itself
// with PATH, so the limits bind the program and never the caller. env is the
// program's environment. It returns only on failure, with a typed stderr line.
func HelperMain(args, env []string, stderr io.Writer) int {
	fail := func(code int, err error) int {
		fmt.Fprintf(stderr, "rsdd %s: %v\n", HelperCommand, err)
		return code
	}
	if len(args) < 3 {
		return fail(helperFailed, errors.New("usage: LIMITS PATH ARGV0 [ARG...]"))
	}
	limits, err := parseLimits(args[0])
	if err != nil {
		return fail(helperFailed, err)
	}
	for _, l := range limits {
		if err := lower(l); err != nil {
			return fail(helperFailed, fmt.Errorf("setrlimit %s: %w", l.Resource, err))
		}
	}
	err = syscall.Exec(args[1], args[2:], env)
	return fail(execFailed, fmt.Errorf("exec %s: %w", args[1], err))
}
