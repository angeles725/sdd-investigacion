package writercheck

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

const (
	defaultTimeout = 900 // seconds, KIT_WRITER_CHECK_TIMEOUT
	termGrace      = 2 * time.Second
	timedOutRC     = 124 // the exit code `timeout` gives a command it stopped
)

// timeoutSeconds reads KIT_WRITER_CHECK_TIMEOUT: unset or empty is the default, otherwise a positive integer without
// a leading zero (a larger number than fits is read as "no practical limit").
func timeoutSeconds(v string) (int64, bool) {
	if v == "" {
		return defaultTimeout, true
	}
	if strings.Trim(v, "0123456789") != "" || v[0] == '0' {
		return 0, false
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 1 << 31, true
	}
	return n, true
}

// writeLogs runs each suite with --prove-teeth and writes its log: the binding header, then the run's output, in
// dir. A suite that is not found, is not a *.test.sh, fails or times out counts as bad (exit 1).
func (c *ctx) writeLogs(dir, header string, limit int64) int {
	bad := 0
	for _, s := range c.o.positional {
		path, rel := filepath.Join(c.repo, s), s
		if strings.HasPrefix(s, "/") {
			path, rel = s, strings.TrimPrefix(s, c.repo+"/")
		}
		switch {
		case !isFile(path):
			fmt.Fprintf(c.s.Err, "FAIL  %s: suite not found\n", s)
			bad++
			continue
		case !strings.HasSuffix(s, ".test.sh"):
			fmt.Fprintf(c.s.Err, "FAIL  %s: only *.test.sh suites take --prove-teeth\n", s)
			bad++
			continue
		}
		log := filepath.Join(dir, logName(rel))
		rc, err := c.runSuite(path, log, header, limit)
		switch {
		case err != nil:
			fmt.Fprintf(c.s.Err, "FAIL  %s: cannot write the log: %v\n", s, err)
			bad++
		case rc == 0:
			fmt.Fprintf(c.s.Out, "PASS  %s -> %s\n", s, log)
		case rc == timedOutRC:
			fmt.Fprintf(c.s.Err, "FAIL  %s: timed out after %ds -> %s\n", s, limit, log)
			bad++
		default:
			fmt.Fprintf(c.s.Err, "FAIL  %s: exit %d -> %s\n", s, rc, log)
			bad++
		}
	}
	if bad > 0 {
		return exitFindings
	}
	return exitOK
}

// runSuite runs `bash suite --prove-teeth` in the repository with its output (stdout and stderr, interleaved) after
// the header in log. A suite still running after limit seconds has its process group stopped (TERM, then KILL) and
// the exit code is 124.
func (c *ctx) runSuite(suite, log, header string, limit int64) (int, error) {
	f, err := os.Create(log)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if _, err := fmt.Fprintln(f, header); err != nil {
		return 0, err
	}
	bash, err := probe.New(c.env, c.s.Cwd).LookPath("bash")
	if err != nil {
		return 127, nil
	}
	cmd := exec.Command(bash, suite, "--prove-teeth")
	cmd.Dir, cmd.Env = c.repo, append(append([]string(nil), c.env...), "PWD="+c.repo)
	cmd.Stdout, cmd.Stderr = f, f
	kitmaint.ProcAttr(cmd)
	if err := cmd.Start(); err != nil {
		return 127, nil
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	select {
	case <-done:
		return kitmaint.ExitCode(cmd.ProcessState), nil
	case <-time.After(time.Duration(min(limit, 1<<31)) * time.Second):
	}
	kitmaint.SignalGroup(cmd, false)
	select {
	case <-done:
	case <-time.After(termGrace):
		kitmaint.SignalGroup(cmd, true)
		<-done
	}
	return timedOutRC, nil
}
