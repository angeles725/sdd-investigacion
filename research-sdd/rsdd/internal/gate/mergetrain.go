package gate

import (
	_ "embed"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// RunMergeTrain is `rsdd gate merge-train`, the port of toolbelt/maint/kit-merge-train.sh (kit issue #2213, Go port
// #2499): gate a batch of approved kit PRs ONCE on a combined local "train" head, then merge them in order. The
// script's header, kept as the frozen oracle under testdata/legacy/mergetrain until phase 8 and as `--help` text
// (testdata/mergetrain/help.txt), is the reference for the options, the receipt and the typed exit states.
//
// The one intended divergence: the bash ran kit-gate.sh and kit-wait-merge.sh as children, and kit-wait-merge ran
// merge-gate.sh. Here both steps are done in-process: the merge gate is RunMerge itself (mtDeps.mergeGate), the CI
// wait and the MERGED / --expect-head check of kit-wait-merge and the flock-serialised gate run of kit-gate are
// inlined with their own typed lines (`kit-wait-merge: ...`, `kit-gate: ...`). Consequences, each pinned by a test:
//   - KIT_MERGE_GATE is ignored (there is no merge-gate.sh to point at); the standalone kit-wait-merge.sh and
//     kit-gate.sh keep working for their other callers;
//   - the gate's lock is held on a file inherited by the gate command (fd 3, not 9), so a background process the
//     gate leaves behind still holds the lock exactly as the bash fd 9 did;
//   - the merge gate's stdout and stderr share one buffer whose last five lines are echoed (the bash 2>&1);
//   - a git or gh child is bounded (10 minutes); the bash had no bound;
//   - git's stderr from a failing fetch is relayed to stderr when the attempt fails (the bash inherited it);
//   - a degraded exit 3 also writes `DEGRADED: <why>` to stderr (the rsdd process contract);
//   - SIGINT/SIGTERM is forwarded to the running gate's process group and the train finishes `train-error:
//     interrupted` at once; the bash trap only ran after the gate child exited;
//   - the receipt is formatted by encoding/json (same bytes as jq for these values), and rsdd buffers stdout until
//     the command returns, so the typed lines appear at the end instead of as they happen.
func RunMergeTrain(args []string, s cli.Stdio) int {
	return runMergeTrain(args, s, mtDeps{
		mergeGate: RunMerge,
		sleep:     time.Sleep,
		pid:       os.Getpid(),
		notify: func() (<-chan os.Signal, func()) {
			ch := make(chan os.Signal, 4)
			signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
			return ch, func() { signal.Stop(ch) }
		},
	})
}

//go:embed testdata/mergetrain/help.txt
var mtHelp string

// mtDeps is everything the train takes from outside: the merge gate, sleeping, the pid in the run stamp and the
// INT/TERM source. Tests replace them; RunMergeTrain wires the real ones.
type mtDeps struct {
	mergeGate func(args []string, s cli.Stdio) int
	sleep     func(time.Duration)
	pid       int
	notify    func() (<-chan os.Signal, func())
}

const mtTool = "kit-merge-train"

// mtExit unwinds the run to runMergeTrain: the bash `exit`.
type mtExit struct{ code int }

type mtRow struct {
	head, status, reason string
}

type train struct {
	s    cli.Stdio
	d    mtDeps
	env  []string
	repo string

	base, state, gateCmd       string
	serial, bisect, dryRun     bool
	pin, pcwd                  map[string]string
	prs                        []string
	remote, baseBranch, wtroot string
	ts, receipt, wt, branch    string
	rows                       map[string]*mtRow
	baseSHA, trainSHA          string
	gateRC, gateLog, culprit   string
	started                    bool
	madeWts                    []string
	sig                        <-chan os.Signal
	stopSig                    func()
	interrupted, finishing     bool
	keep, merged, mergedOK     []string
	inBisect                   bool
	finalGateRC, finalGateLog  string
	expTip, stopped            string
	stopRC                     int
	pidStr                     string
}

func runMergeTrain(args []string, s cli.Stdio, d mtDeps) (code int) {
	g := &train{s: s, d: d, env: s.Environ(), pin: map[string]string{}, pcwd: map[string]string{}, rows: map[string]*mtRow{}}
	defer func() {
		if r := recover(); r != nil {
			if e, ok := r.(mtExit); ok {
				code = e.code
				return
			}
			panic(r)
		}
	}()
	return g.run(args)
}

func (g *train) say(format string, a ...any) {
	fmt.Fprintf(g.s.Out, "%s: %s\n", mtTool, fmt.Sprintf(format, a...))
}

// fail is kit_fail: the typed line, then exit CODE.
func (g *train) fail(code int, state, msg string) {
	if msg == "" {
		g.say("%s", state)
	} else {
		g.say("%s: %s", state, msg)
	}
	if code == cli.ExitDegraded {
		fmt.Fprintf(g.s.Err, "DEGRADED: %s\n", msg)
	}
	panic(mtExit{code})
}

func (g *train) usage(msg string) { g.fail(cli.ExitUsage, "usage", msg) }

func isHex(s string) bool { return s != "" && strings.Trim(s, "0123456789abcdefABCDEF") == "" }

func (g *train) parseArgs(args []string) []string {
	rest := args
	need := func(flag, what string) string {
		if len(rest) < 2 {
			g.usage(flag + " needs " + what)
		}
		return rest[1]
	}
	split := func(v string) (string, string) {
		if k, val, ok := strings.Cut(v, "="); ok {
			return k, val
		}
		return v, v // ${v%%=*} and ${v#*=} of a value with no '='
	}
loop:
	for len(rest) > 0 {
		switch rest[0] {
		case "--rdd-ok":
			v := need("--rdd-ok", "PR=SHA")
			k, sha := split(v)
			if k == "" || !allDigits(k) {
				g.usage("--rdd-ok PR must be a number: " + v)
			}
			if !isHex(sha) {
				g.usage("--rdd-ok SHA must be hex: " + v)
			}
			if len(sha) < 7 || k+"="+sha != v {
				g.usage("--rdd-ok wants PR=SHA with 7+ hex chars: " + v)
			}
			g.pin[k] = sha
			rest = rest[2:]
		case "--pr-cwd":
			v := need("--pr-cwd", "PR=DIR")
			k, dir := split(v)
			if k == "" || !allDigits(k) {
				g.usage("--pr-cwd PR must be a number: " + v)
			}
			if dir == "" || k+"="+dir != v {
				g.usage("--pr-cwd wants PR=DIR: " + v)
			}
			g.pcwd[k] = dir
			rest = rest[2:]
		case "--repo":
			g.repo = need("--repo", "a value")
			rest = rest[2:]
		case "--base-ref":
			g.base = need("--base-ref", "a value")
			rest = rest[2:]
		case "--state-dir":
			g.state = need("--state-dir", "a value")
			rest = rest[2:]
		case "--gate-cmd":
			g.gateCmd = need("--gate-cmd", "a value")
			rest = rest[2:]
		case "--serial":
			g.serial = true
			rest = rest[1:]
		case "--bisect":
			g.bisect = true
			rest = rest[1:]
		case "--dry-run":
			g.dryRun = true
			rest = rest[1:]
		case "-h", "--help":
			fmt.Fprint(g.s.Out, mtHelp)
			panic(mtExit{0})
		case "--":
			rest = rest[1:]
			break loop
		default:
			if strings.HasPrefix(rest[0], "-") {
				g.usage("unknown option " + rest[0])
			}
			break loop
		}
	}
	return rest
}

func (g *train) run(args []string) int {
	g.repo, g.base = ".", "origin/main"
	g.prs = g.parseArgs(args)
	if len(g.prs) < 1 {
		g.usage("kit-merge-train.sh [options] <pr> [<pr>...]")
	}
	seen := map[string]bool{}
	dup := false
	for _, p := range g.prs {
		if p == "" || !allDigits(p) {
			g.usage("pr must be a number: " + p)
		}
		if seen[p] {
			dup = true
		}
		seen[p] = true
	}
	if dup {
		g.usage("a PR is listed twice")
	}
	for _, k := range mtSortedKeys(g.pcwd) {
		if !seen[k] {
			g.usage("--pr-cwd names #" + k + ", which is not in the batch")
		}
	}
	if g.serial && g.gateCmd != "" {
		g.usage("--serial cannot be combined with --gate-cmd")
	}
	remote, _, ok := strings.Cut(g.base, "/")
	if !ok {
		g.usage("--base-ref must be <remote>/<branch>: " + g.base)
	}
	g.remote = remote
	if !isDir(g.abs(g.repo)) {
		g.usage("repo is not a directory: " + g.repo)
	}
	repo, err := g.resolveDir(g.repo)
	if err != nil {
		g.usage("cannot resolve --repo")
	}
	g.repo = repo
	if g.state == "" {
		g.state = g.stateDir()
	}
	st, err := g.physPath(g.state)
	if err != nil {
		g.usage("cannot resolve --state-dir")
	}
	g.state = st
	if strings.HasPrefix(g.state+"/", g.repo+"/") {
		g.usage("--state-dir " + g.state + " is inside the repo; state never lives in the repo")
	}
	g.wtroot = filepath.Dir(g.repo) + "/" + filepath.Base(g.repo) + "-worktrees"

	if g.dryRun {
		ser := ""
		if g.serial {
			ser = ", serial"
		}
		gc := g.gateCmd
		if gc == "" {
			gc = "default full gate"
		}
		bis := 0
		if g.bisect {
			bis = 1
		}
		g.say("plan: PRs %s in order onto %s; one gate (%s%s); bisect=%d", strings.Join(g.prs, " "), g.base, gc, ser, bis)
		g.say("plan: train worktree under %s, state dir %s; each PR needs --rdd-ok; nothing was run", g.wtroot, g.state)
		return 0
	}

	// kit_probe_deps git gh jq flock: jq and flock are not executed here (the receipt and the lock are in-process)
	// but the typed degraded state of a kit without them is part of the contract.
	pr := probe.New(g.env, g.s.Cwd)
	var missing string
	for _, dep := range []string{"git", "gh", "jq", "flock"} {
		if _, err := pr.LookPath(dep); err != nil {
			missing += " " + dep
		}
	}
	if missing != "" {
		g.fail(cli.ExitDegraded, "degraded", "missing runtime dependency:"+missing)
	}
	if r := g.git(g.repo, "rev-parse", "--git-dir"); r.rc != 0 {
		g.usage("not a git checkout: " + g.repo)
	}
	if err := os.MkdirAll(g.state, 0o777); err != nil {
		g.usage("cannot create state dir " + g.state)
	}
	g.pidStr = strconv.Itoa(g.d.pid)
	g.ts = g.s.Clock().Format("20060102-150405") + "-" + g.pidStr
	g.receipt = g.state + "/train-" + g.ts + ".json"
	g.wt = g.wtroot + "/train-" + g.ts
	g.branch = "train/" + g.ts
	for _, p := range g.prs {
		g.rows[p] = &mtRow{}
	}

	if g.d.notify != nil {
		g.sig, g.stopSig = g.d.notify()
		defer g.stopSig()
	}

	if !g.retry("git -C "+g.repo+" fetch -q "+g.remote, false, func() mtRes { return g.git(g.repo, "fetch", "-q", g.remote) }).ok() {
		g.finish(21, "fetch-failed", "git fetch "+g.remote+" still failing")
	}
	r := g.git(g.repo, "rev-parse", g.base+"^{commit}")
	if r.rc != 0 {
		g.finish(29, "train-error", "base ref "+g.base+" does not resolve")
	}
	g.baseSHA = strings.TrimRight(r.out, "\n")
	g.baseBranch = g.base[strings.Index(g.base, "/")+1:]

	g.checkPRs()
	if len(g.keep) == 0 {
		g.finish(28, "train-empty", "no PR passed the checks")
	}
	g.buildTrain()
	g.runTrainGate()
	g.preMerge()
	g.mergeAll()
	return 0
}

func mtSortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	// numeric strings in a map: order only decides which unlisted PR is named first, as bash's unordered "${!pcwd[@]}"
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j] < out[j-1]; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func (g *train) abs(p string) string {
	if strings.HasPrefix(p, "/") {
		return p
	}
	return g.s.Cwd + "/" + p
}

// resolveDir is `cd -- DIR && pwd -P`.
func (g *train) resolveDir(p string) (string, error) {
	return filepath.EvalSymlinks(filepath.Clean(g.abs(p)))
}

// physPath is kit_phys_path: the physical path of P even when P does not exist yet.
func (g *train) physPath(p string) (string, error) {
	p = g.abs(p)
	rest := ""
	for !isDir(p) && p != "/" {
		rest = "/" + p[strings.LastIndex(p, "/")+1:] + rest
		p = p[:strings.LastIndex(p, "/")]
		if p == "" {
			p = "/"
		}
	}
	d, err := filepath.EvalSymlinks(filepath.Clean(p))
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(d, "/") + rest, nil
}

func (g *train) stateDir() string {
	base := g.s.Env("XDG_STATE_HOME")
	if base == "" {
		base = g.s.Env("HOME") + "/.local/state"
	}
	return base + "/research-sdd/pipeline"
}
