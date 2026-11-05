package gate

import (
	"bytes"
	"encoding/json"
	"os"
	"strconv"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// mtRes is one finished child: stdout, stderr and the shell's exit code (127 not runnable, 124 timed out).
type mtRes struct {
	out, err string
	rc       int
}

func (r mtRes) ok() bool { return r.rc == 0 }

func mkdirAll(p string) error { return os.MkdirAll(p, 0o777) }

func fromRes(r kitmaint.Res) mtRes { return mtRes{out: r.Out, err: r.Err, rc: r.RC} }

func toRes(r mtRes) kitmaint.Res { return kitmaint.Res{Out: r.out, Err: r.err, RC: r.rc} }

// newRunner is the train's child runner (core/kitmaint, shared with `rsdd maint`): a signal pending after any child
// finishes the run, as the bash trap did.
func (g *train) newRunner() *kitmaint.Runner {
	return &kitmaint.Runner{Env: g.env, Cwd: g.s.Cwd, Now: g.s.Clock, Err: g.s.Err, Getenv: g.s.Env,
		Sleep: func(d time.Duration) { g.d.sleep(d) }, Poll: g.poll}
}

func (g *train) git(dir string, args ...string) mtRes { return fromRes(g.kr.Git(dir, args...)) }

// gh is `(cd dir && gh args)`.
func (g *train) gh(dir string, args ...string) mtRes { return fromRes(g.kr.Gh(dir, args...)) }

// retry is kit_retry TRIES CMD under the train's own prefix.
func (g *train) retry(words string, quiet bool, f func() mtRes) mtRes {
	return fromRes(g.kr.Retry(mtTool, 3, words, quiet, func() kitmaint.Res { return toRes(f()) }))
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
