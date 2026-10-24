//go:build unix

package proc

import (
	"fmt"
	"io"
	"runtime"
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

// lower sets soft and hard of l to limitTarget: an unprivileged process can
// always lower a limit, never raise its hard one.
func lower(l Limit) error {
	res := resources[l.Resource]
	var cur syscall.Rlimit
	if err := syscall.Getrlimit(res, &cur); err != nil {
		return err
	}
	v := limitTarget(l, cur.Max, platformCeiling)
	return syscall.Setrlimit(res, &syscall.Rlimit{Cur: v, Max: v})
}

// limitTarget is l.Value clamped to the hard limit and to ceiling, the
// highest value the platform accepts for the resource when it has one.
func limitTarget(l Limit, hard uint64, ceiling func(res int) (uint64, bool)) uint64 {
	v := min(l.Value, hard)
	if c, ok := ceiling(resources[l.Resource]); ok {
		v = min(v, c)
	}
	return v
}

// HelperMain is the body of `rsdd __exec LIMITS PATH ARGV0 [ARG...]`, run in
// the freshly started child: it lowers every limit and then replaces itself
// with PATH, so the limits bind the program and never the caller. env is the
// program's environment. It returns only on failure, with a typed stderr line.
//
// A memory limit (as, data, stack) may sit below what the helper has already
// mapped, so once the limits are lowered nothing may need a new mapping:
// prepareExec runs first, and a failure is reported through a line buffer
// allocated up front.
func HelperMain(args, env []string, stderr io.Writer) int {
	if len(args) < 3 {
		return newReport(stderr, 0).fail(helperFailed, "usage: LIMITS PATH ARGV0 [ARG...]", "", nil)
	}
	limits, err := parseLimits(args[0])
	if err != nil {
		return newReport(stderr, 0).fail(helperFailed, err.Error(), "", nil)
	}
	path, argv := args[1], args[2:]
	r := newReport(stderr, len(path))
	prepareExec(path, argv, env)
	for _, l := range limits {
		if err := lower(l); err != nil {
			return r.fail(helperFailed, "setrlimit ", l.Resource, err)
		}
	}
	// syscall.Exec, never a raw execve: it puts back the soft NOFILE the
	// runtime raised at startup (unless a nofile limit was set here), so a
	// limit not in LIMITS reaches the program as the caller left it.
	err = syscall.Exec(path, argv, env)
	return r.fail(execFailed, "exec ", path, err)
}

// prepareExec readies the helper for limits below what it has already
// mapped, under which any new mapping is a fatal runtime error rather than
// an error value:
//   - the heap profiler is turned off: it samples allocations at random and
//     records each sample in a bucket that may need a new mapping. Keeping
//     one P frees the other Ps' allocation caches, and the allocations below
//     settle the remaining one at the new rate.
//   - syscall.Exec's own allocations (the NUL-terminated copies of path,
//     argv and env) are made once, dropped and collected. Go never returns
//     heap address space to the OS, so the same copies made again by
//     syscall.Exec are served from those pages.
func prepareExec(path string, argv, env []string) {
	runtime.MemProfileRate = 0
	runtime.GOMAXPROCS(1)
	p, _ := syscall.BytePtrFromString(path)
	a, _ := syscall.SlicePtrFromStrings(argv)
	e, _ := syscall.SlicePtrFromStrings(env)
	runtime.KeepAlive(p)
	runtime.KeepAlive(a)
	runtime.KeepAlive(e)
	runtime.GC()
}

// report writes the helper's one stderr line, "rsdd __exec: <what><subject>:
// <err>", into a buffer sized before any limit is lowered, so reporting a
// failure under a memory limit needs no allocation.
type report struct {
	w   io.Writer
	buf []byte
}

// newReport sizes the line for a subject of up to n bytes.
func newReport(w io.Writer, n int) report {
	return report{w, make([]byte, 0, n+256)}
}

func (r report) fail(code int, what, subject string, err error) int {
	b := append(r.buf, "rsdd "+HelperCommand+": "...)
	b = append(append(b, what...), subject...)
	if err != nil {
		b = append(append(b, ": "...), err.Error()...)
	}
	_, _ = r.w.Write(append(b, '\n'))
	return code
}
