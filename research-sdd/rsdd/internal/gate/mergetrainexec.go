package gate

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// The bash had no bound on any child; a run that never ends is the only thing a ceiling can change.
const (
	mtChildCeiling = 10 * time.Minute
	mtMaxBytes     = 64 << 20
)

// mtRes is one finished child: stdout, stderr and the shell's exit code (127 not runnable, 124 timed out).
type mtRes struct {
	out, err string
	rc       int
}

func (r mtRes) ok() bool { return r.rc == 0 }

func mkdirAll(p string) error { return os.MkdirAll(p, 0o777) }

func (g *train) git(dir string, args ...string) mtRes {
	out, err := git.Runner{Env: g.env, Timeout: mtChildCeiling, Now: g.s.Clock}.Run(g.abs(dir), args...)
	r := mtRes{out: string(out)}
	var ee *git.ExitError
	switch {
	case err == nil:
	case errors.As(err, &ee):
		r.rc, r.err = ee.Code, ee.Stderr
	case errors.Is(err, git.ErrTimeout):
		r.rc = 124
	default:
		r.rc = 127
	}
	g.poll()
	return r
}

// gh is `(cd dir && gh args)`.
func (g *train) gh(dir string, args ...string) mtRes {
	res, err := proc.Run(proc.Spec{
		Argv: append([]string{"gh"}, args...), Dir: dir, Env: append(append([]string(nil), g.env...), "PWD="+dir),
		Timeout: mtChildCeiling, MaxBytes: mtMaxBytes, Now: g.s.Clock,
	})
	g.poll()
	if err != nil {
		return mtRes{rc: 127}
	}
	r := mtRes{out: string(res.Stdout), err: string(res.Stderr), rc: res.ReturnCode}
	switch {
	case res.Reason == proc.ReasonTimeout:
		r.rc = 124
	case res.ReturnCode < 0:
		r.rc = 128 - res.ReturnCode
	}
	return r
}

// retry is kit_retry TRIES CMD: up to three tries, KIT_RETRY_SLEEP (default 5) seconds times the attempt apart. The
// result carries the stdout of every attempt (a command substitution around kit_retry collects them all) and the
// stderr and rc of the last. quiet is the `2>/dev/null` around the bash call: attempt notes and git's own stderr
// are dropped. words is "$*" of the retried command.
func (g *train) retry(words string, quiet bool, f func() mtRes) mtRes {
	return g.retryAs(mtTool, 3, words, quiet, f)
}

func (g *train) retryAs(tool string, tries int, words string, quiet bool, f func() mtRes) mtRes {
	var all mtRes
	for n := 1; ; n++ {
		r := f()
		all.out += r.out
		all.err, all.rc = r.err, r.rc
		if !quiet && r.rc != 0 && r.err != "" {
			fmt.Fprint(g.s.Err, r.err) // the child's stderr, which the bash inherited
		}
		if r.rc == 0 || n >= tries {
			return all
		}
		if !quiet {
			fmt.Fprintf(g.s.Err, "%s: retry %d/%d after rc=%d: %s\n", tool, n, tries, r.rc, words)
		}
		g.d.sleep(time.Duration(atoi0(g.s.Env("KIT_RETRY_SLEEP"), 5)*n) * time.Second)
	}
}

// atoi0 is `$(( ${VAR:-def} * n ))`: an empty value takes the default, a non-number counts as 0.
func atoi0(v string, def int) int {
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return 0
	}
	return n
}

// poll is where the bash trap would fire: a pending INT/TERM finishes the run.
func (g *train) poll() {
	if g.finishing {
		return
	}
	if !g.interrupted && g.sig != nil {
		select {
		case <-g.sig:
			g.interrupted = true
		default:
		}
	}
	if g.interrupted {
		g.finish(29, "train-error", "interrupted")
	}
}

type mtReceiptPR struct {
	PR     int    `json:"pr"`
	Head   string `json:"head"`
	Status string `json:"status"`
	Reason string `json:"reason"`
}

type mtReceiptGate struct {
	RC  *int   `json:"rc"`
	Log string `json:"log"`
	Cmd string `json:"cmd"`
}

type mtReceipt struct {
	State       string        `json:"state"`
	BaseSHA     string        `json:"base_sha"`
	TrainBranch string        `json:"train_branch"`
	TrainSHA    string        `json:"train_sha"`
	Gate        mtReceiptGate `json:"gate"`
	Culprit     *int          `json:"culprit"`
	PRs         []mtReceiptPR `json:"prs"`
}

func (g *train) writeReceipt(state string) {
	cmd := g.gateCmd
	if cmd == "" {
		cmd = "default"
	}
	rc := mtReceipt{State: state, BaseSHA: g.baseSHA, TrainBranch: g.branch, TrainSHA: g.trainSHA,
		Gate: mtReceiptGate{Log: g.gateLog, Cmd: cmd}, PRs: []mtReceiptPR{}}
	if n, err := strconv.Atoi(g.gateRC); g.gateRC != "" && err == nil {
		rc.Gate.RC = &n
	}
	if n, err := strconv.Atoi(g.culprit); g.culprit != "" && err == nil {
		rc.Culprit = &n
	}
	for _, p := range g.prs {
		row := g.rows[p]
		status := row.status
		if status == "" {
			status = "pending"
		}
		n, _ := strconv.Atoi(p)
		rc.PRs = append(rc.PRs, mtReceiptPR{PR: n, Head: row.head, Status: status, Reason: row.reason})
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(rc); err != nil || os.WriteFile(g.receipt, buf.Bytes(), 0o666) != nil {
		g.say("degraded: could not write the receipt %s", g.receipt)
	}
}

func (g *train) cleanup() {
	for _, w := range g.madeWts {
		g.git(g.repo, "worktree", "remove", "--force", w)
	}
	if g.started {
		g.git(g.repo, "branch", "-D", g.branch)
	}
	for _, p := range g.prs {
		g.git(g.repo, "update-ref", "-d", "refs/train/"+g.ts+"/"+p)
	}
	g.git(g.repo, "worktree", "prune")
}

// finish is the bash `finish`: INT/TERM are ignored from here, the receipt is written, everything made is removed
// and the typed line ends the run.
func (g *train) finish(code int, state, msg string) {
	g.finishing = true
	g.writeReceipt(state)
	g.cleanup()
	g.say("receipt=%s", g.receipt)
	g.fail(code, state, msg)
}
