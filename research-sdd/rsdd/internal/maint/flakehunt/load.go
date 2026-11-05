package flakehunt

import (
	"os/exec"
	"strconv"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// loadTagPrefix labels every worker's command line so a process listing (and the tests) can tell whose they are.
const loadTagPrefix = "kit-flake-hunt-load:"

// stopGrace is how long a TERMed group gets to leave before it is KILLed.
const stopGrace = 2 * time.Second

// worker is one `timeout S bash -c 'while :; do :; done'` busy loop in its own process group.
type worker struct {
	cmd  *exec.Cmd
	done chan struct{} // closed once the process has been reaped
}

func (w *worker) finished() bool {
	select {
	case <-w.done:
		return true
	default:
		return false
	}
}

// pool is the synthetic CPU load of a hunt.
type pool struct{ workers []*worker }

// startLoad starts n workers bounded by timeout seconds each. timeoutBin and bashBin are resolved paths; the tools
// are named plainly in argv (`timeout S bash -c ...`) so the command line reads as it always did.
func startLoad(n, seconds int, tag, timeoutBin string, env []string) (*pool, error) {
	p := &pool{}
	for i := 0; i < n; i++ {
		cmd := exec.Command(timeoutBin)
		cmd.Args = []string{"timeout", strconv.Itoa(seconds), "bash", "-c", "while :; do :; done", loadTagPrefix + tag}
		cmd.Env = env
		kitmaint.ProcAttr(cmd)
		if err := cmd.Start(); err != nil {
			p.stop()
			return nil, err
		}
		w := &worker{cmd: cmd, done: make(chan struct{})}
		go func() { _ = cmd.Wait(); close(w.done) }()
		p.workers = append(p.workers, w)
	}
	return p, nil
}

// alive is true while every worker is still running; an expired `timeout` is reaped, so it reads as gone. A hunt
// with no workers (--load 0) is always alive.
func (p *pool) alive() bool {
	for _, w := range p.workers {
		if w.finished() {
			return false
		}
	}
	return true
}

// stop ends every worker by its process group (never by name) and waits for it to be reaped.
func (p *pool) stop() {
	if p == nil {
		return
	}
	for _, w := range p.workers {
		if !w.finished() {
			kitmaint.SignalGroup(w.cmd, false)
		}
	}
	for _, w := range p.workers {
		select {
		case <-w.done:
		case <-time.After(stopGrace):
			kitmaint.SignalGroup(w.cmd, true)
			<-w.done
		}
	}
}
