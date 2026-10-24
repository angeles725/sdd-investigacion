//go:build unix

package proc

import (
	"bytes"
	"os"
	"os/exec"
	"slices"
	"strings"
	"syscall"
	"testing"
)

func TestFormatAndParseLimitsRoundTrip(t *testing.T) {
	in := []Limit{{"as", 1 << 28}, {"nofile", 64}, {"fsize", 0}}
	got, err := parseLimits(formatLimits(in))
	if err != nil || !slices.Equal(got, in) {
		t.Fatalf("parseLimits(formatLimits(%v)) = %v, %v", in, got, err)
	}
	if got, err := parseLimits(""); err != nil || len(got) != 0 {
		t.Fatalf("empty spec = %v, %v; want no limits", got, err)
	}
}

func TestParseLimitsRejectsMalformedSpecs(t *testing.T) {
	for _, spec := range []string{"bogus=1", "as", "as=", "as=x", "as=-1", "as=1,", ",as=1", "AS=1"} {
		if got, err := parseLimits(spec); err == nil {
			t.Errorf("parseLimits(%q) = %v, want an error", spec, got)
		}
	}
}

// runHelper starts the test binary as the helper with args.
func runHelper(t *testing.T, args ...string) (stdout, stderr string, code int) {
	t.Helper()
	cmd := exec.Command(os.Args[0], append([]string{HelperCommand}, args...)...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	if _, isExit := err.(*exec.ExitError); err != nil && !isExit {
		t.Fatalf("helper did not run: %v", err)
	}
	return out.String(), errb.String(), cmd.ProcessState.ExitCode()
}

func TestHelperUsageErrorsExit125(t *testing.T) {
	for _, args := range [][]string{{}, {"as=1"}, {"as=1", "/bin/true"}, {"bogus=1", "/bin/true", "true"}} {
		_, stderr, code := runHelper(t, args...)
		if code != 125 || !strings.HasPrefix(stderr, "rsdd "+HelperCommand+": ") {
			t.Errorf("helper %q = exit %d stderr %q, want 125 and a typed line", args, code, stderr)
		}
	}
}

func TestHelperExecFailureExits127(t *testing.T) {
	_, stderr, code := runHelper(t, "", "/nonexistent/prog", "prog")
	if code != 127 || !strings.Contains(stderr, "/nonexistent/prog") {
		t.Fatalf("exit %d stderr %q, want 127 naming the program", code, stderr)
	}
}

func TestHelperExecsTheProgramWithItsArgs(t *testing.T) {
	stdout, _, code := runHelper(t, "", "/bin/sh", "sh", "-c", `echo "$0 $1"`, "zero", "one")
	if code != 0 || stdout != "zero one\n" {
		t.Fatalf("exit %d stdout %q, want the args passed through", code, stdout)
	}
}

// A limit not named in LIMITS reaches the program as the caller set it. The
// Go runtime raises its own soft NOFILE at startup (syscall/rlimit.go), so
// the helper holds a raised one; syscall.Exec puts the original back before
// execve (syscall/exec_unix.go), and the program must see the caller's 200.
func TestHelperPassesAnUnnamedLimitThroughUnchanged(t *testing.T) {
	var own syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &own); err != nil {
		t.Fatal(err)
	}
	if own.Max <= 201 {
		t.Skipf("hard NOFILE %d leaves the runtime nothing to raise: the case proves nothing", own.Max)
	}
	script := `ulimit -Sn 200 && exec "$0" ` + HelperCommand + ` "" /bin/sh sh -c 'ulimit -Sn'`
	out, err := exec.Command("/bin/sh", "-c", script, os.Args[0]).CombinedOutput()
	if err != nil || string(out) != "200\n" {
		t.Fatalf("program's soft NOFILE = %q (%v), want the caller's 200", out, err)
	}
}
