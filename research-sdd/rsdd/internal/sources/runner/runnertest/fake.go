// Package runnertest is the scripted Runner of the sources tests: no process is started, every call is recorded,
// and the test decides what each program prints and returns.
package runnertest

import (
	"context"
	"io"
	"strings"
	"sync"
)

// Reply is what one scripted call produces.
type Reply struct {
	Stdout, Stderr string
	RC             int
}

// Fake is a Runner whose behaviour is Script. Script may also act on the file system (a fake curl writes its -o
// file); it receives the call's argv.
type Fake struct {
	Script func(argv []string) Reply

	mu    sync.Mutex
	calls [][]string
}

// Run implements runner.Runner.
func (f *Fake) Run(_ context.Context, argv []string, stdout, stderr io.Writer) int {
	f.mu.Lock()
	f.calls = append(f.calls, append([]string(nil), argv...))
	f.mu.Unlock()
	r := f.Script(argv)
	if stdout != nil {
		_, _ = io.WriteString(stdout, r.Stdout)
	}
	if stderr != nil {
		_, _ = io.WriteString(stderr, r.Stderr)
	}
	return r.RC
}

// Calls returns every recorded call as one space-joined line, in order.
func (f *Fake) Calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]string, len(f.calls))
	for i, c := range f.calls {
		out[i] = strings.Join(c, " ")
	}
	return out
}

// Count is the number of recorded calls whose joined argv contains substr.
func (f *Fake) Count(substr string) int {
	n := 0
	for _, c := range f.Calls() {
		if strings.Contains(c, substr) {
			n++
		}
	}
	return n
}
