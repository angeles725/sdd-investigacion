//go:build linux

package proc

import (
	"strconv"
	"strings"
	"syscall"
	"testing"
)

// limitsOf parses /proc/<pid>/limits text into "Max ..." name -> {soft, hard}.
func limitsOf(t *testing.T, text string) map[string][2]string {
	t.Helper()
	out := map[string][2]string{}
	for _, line := range strings.Split(text, "\n") {
		if len(line) < 26 || !strings.HasPrefix(line, "Max ") {
			continue
		}
		f := strings.Fields(line[25:])
		if len(f) >= 2 {
			out[strings.TrimSpace(line[:25])] = [2]string{f[0], f[1]}
		}
	}
	if len(out) == 0 {
		t.Fatalf("no limits parsed from %q", text)
	}
	return out
}

func wantLimit(t *testing.T, got map[string][2]string, name string, v uint64) {
	t.Helper()
	s := strconv.FormatUint(v, 10)
	if got[name] != [2]string{s, s} {
		t.Errorf("%s = %v, want soft and hard %s", name, got[name], s)
	}
}

// The child reports its own limits; the address-space limit leaves ample
// room for cat while staying far below the test binary's own cap.
func TestHelperAppliesLimitsInTheChildOnly(t *testing.T) {
	var before syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &before); err != nil {
		t.Fatal(err)
	}
	spec := "as=268435456,cpu=7,fsize=12345,nofile=64"
	stdout, stderr, code := runHelper(t, spec, "/bin/cat", "cat", "/proc/self/limits")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	got := limitsOf(t, stdout)
	wantLimit(t, got, "Max address space", 268435456)
	wantLimit(t, got, "Max cpu time", 7)
	wantLimit(t, got, "Max file size", 12345)
	wantLimit(t, got, "Max open files", 64)
	var after syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &after); err != nil || after != before {
		t.Fatalf("our own NOFILE limit changed from %+v to %+v (%v): limits must apply to the child only", before, after, err)
	}
}

// A request above the hard limit is clamped to it (as run_bounded clamps
// RLIMIT_FSIZE), never an error and never a raise.
func TestHelperClampsToTheHardLimit(t *testing.T) {
	var own syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &own); err != nil {
		t.Fatal(err)
	}
	stdout, stderr, code := runHelper(t, "nofile=18446744073709551614", "/bin/cat", "cat", "/proc/self/limits")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	wantLimit(t, limitsOf(t, stdout), "Max open files", own.Max)
}

// ARGV0 is passed through as is, separate from PATH (Popen keeps argv[0]).
func TestHelperKeepsArgv0(t *testing.T) {
	stdout, stderr, code := runHelper(t, "", "/bin/cat", "my-cat", "/proc/self/cmdline")
	if code != 0 || stdout != "my-cat\x00/proc/self/cmdline\x00" {
		t.Fatalf("exit %d stdout %q stderr %q, want argv0 my-cat", code, stdout, stderr)
	}
}
