package proc

import (
	"errors"
	"fmt"
	"io"
	"sync"
	"time"
)

// Reasons a run was stopped early, as run_bounded reports them.
const (
	ReasonTimeout   = "timeout"
	ReasonOutputCap = "output-cap"
)

// DefaultGrace is how long each stop phase (TERM, then KILL) waits for the
// group to empty, as run_bounded's stop_group does.
const DefaultGrace = 500 * time.Millisecond

// ErrInvalidSpec wraps every rejected Spec.
var ErrInvalidSpec = errors.New("proc: invalid spec")

// Spec is one bounded run.
type Spec struct {
	// Argv is the program and its arguments. A name without a slash is looked
	// up on Env's PATH (default "/bin:/usr/bin", like Popen); a relative path
	// is relative to Dir.
	Argv []string
	Dir  string
	// Env is the program's whole environment; nothing is inherited.
	Env []string
	// Timeout is the wall-clock bound, > 0.
	Timeout time.Duration
	// MaxBytes is the joint stdout+stderr cap, > 0. Reaching it stops the run.
	MaxBytes int
	// Grace is the wait after TERM and after KILL; 0 means DefaultGrace.
	Grace time.Duration
	// Limits are rlimits lowered in the child only, through Helper.
	Limits []Limit
	// Helper is the rsdd binary that serves HelperCommand; required with Limits.
	Helper string
	// Now stamps Started and Ended (Duration is their difference); nil leaves
	// all three zero. The package reads no clock of its own.
	Now func() time.Time
}

// Result is what a run produced. ReturnCode follows Popen: >= 0 is the exit
// status, -N means killed by signal N.
type Result struct {
	Stdout, Stderr []byte
	// Reason is "" or the Reason* that stopped the run.
	Reason         string
	ReturnCode     int
	Started, Ended time.Time
	Duration       time.Duration
}

// Errors returns run_bounded's error list: the stop reason, or
// "analyzer-exit:<code>" for a non-zero code when nothing stopped the run.
func (r Result) Errors() []string {
	if r.Reason != "" {
		return []string{r.Reason}
	}
	if r.ReturnCode != 0 {
		return []string{fmt.Sprintf("analyzer-exit:%d", r.ReturnCode)}
	}
	return nil
}

// SpawnError is a program that could not be started; Path is Argv[0].
type SpawnError struct {
	Path string
	Err  error
}

func (e *SpawnError) Error() string { return fmt.Sprintf("proc: cannot start %s: %v", e.Path, e.Err) }
func (e *SpawnError) Unwrap() error { return e.Err }

func (s Spec) validate() error {
	var why string
	switch {
	case len(s.Argv) == 0:
		why = "empty argv"
	case s.Timeout <= 0:
		why = "timeout must be positive"
	case s.MaxBytes <= 0:
		why = "max bytes must be positive"
	case s.Grace < 0:
		why = "grace must not be negative"
	case len(s.Limits) > 0 && s.Helper == "":
		why = "limits need a helper binary"
	}
	if why != "" {
		return fmt.Errorf("%w: %s", ErrInvalidSpec, why)
	}
	return nil
}

func (s Spec) grace() time.Duration {
	if s.Grace == 0 {
		return DefaultGrace
	}
	return s.Grace
}

func (s Spec) now() time.Time {
	if s.Now == nil {
		return time.Time{}
	}
	return s.Now()
}

// capture drains both streams, keeping at most max bytes of each and
// counting every byte; hit closes once the joint count reaches max.
type capture struct {
	mu    sync.Mutex
	max   int
	total int
	bufs  [2][]byte
	hit   chan struct{}
	once  sync.Once
}

func newCapture(max int) *capture { return &capture{max: max, hit: make(chan struct{})} }

// stream returns the writer for stdout (0) or stderr (1).
func (c *capture) stream(i int) io.Writer { return streamWriter{c, i} }

func (c *capture) reached() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.total >= c.max
}

// output returns both streams jointly cut to max: stdout keeps its bytes
// first, stderr gets what is left, as run_bounded truncates its two files.
func (c *capture) output() (stdout, stderr []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := c.bufs[0][:min(len(c.bufs[0]), c.max)]
	return out, c.bufs[1][:min(len(c.bufs[1]), c.max-len(out))]
}

type streamWriter struct {
	c *capture
	i int
}

// Write never fails: past the cap the bytes are counted and dropped, so the
// writer is never blocked on a full pipe.
func (w streamWriter) Write(p []byte) (int, error) {
	c := w.c
	c.mu.Lock()
	keep := min(len(p), c.max-len(c.bufs[w.i]))
	c.bufs[w.i] = append(c.bufs[w.i], p[:keep]...)
	c.total += len(p)
	reached := c.total >= c.max
	c.mu.Unlock()
	if reached {
		c.once.Do(func() { close(c.hit) })
	}
	return len(p), nil
}
