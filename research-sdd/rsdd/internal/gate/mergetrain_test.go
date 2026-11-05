package gate

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The merge-train tests. Every scenario builds REAL tiny git repositories (a bare origin; each PR head is pushed to
// refs/pull/N/head) and runs the port in-process against PATH stubs for gh (testdata/mergetrain/stubs/gh) and a
// stub merge gate (stubs/merge-gate.sh, a real squash onto origin/main), with a gate command that records the files
// present in the train worktree. The ordered calls.log shows `gh ...`, `GATE <head> <files>` and
// `MERGE <pr> head=<sha>`. Nothing reaches the network, a real remote or gentle-ai. This file asserts the contract
// of each scenario; mergetraindiff_test.go replays the same scenarios against the frozen bash (testdata/legacy).

const mtGateRecord = `echo "GATE $(git rev-parse HEAD) $(ls pr-*.txt 2>/dev/null | tr "\n" " ")" >> "$CASE/calls.log"; [ ! -e bad.txt ]`

var mtTools = []string{"bash", "env", "cat", "grep", "sed", "awk", "sleep", "date", "mkdir", "rm", "cut", "tail", "head", "dirname",
	"readlink", "basename", "mktemp", "tr", "sort", "wc", "touch", "ls", "uniq", "tee", "ln", "find", "python3", "cp", "mv", "chmod",
	"true", "false", "sh", "git", "jq", "flock", "timeout"}

// mtCase is one scenario's world: CASE/{origin.git,repo,sq,bin,state,...}.
type mtCase struct {
	t   *testing.T
	dir string
	env []string
}

func mtHostEnv() []string {
	return gitfixture.Env(append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com",
		"GIT_AUTHOR_DATE=2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE=2000-01-01T00:00:00Z", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"))
}

func (c *mtCase) sh(dir string, name string, args ...string) string {
	c.t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir, cmd.Env = dir, mtHostEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		c.t.Fatalf("%s %v: %v\n%s", name, args, err, out)
	}
	return strings.TrimRight(string(out), "\n")
}

func (c *mtCase) git(args ...string) string { c.t.Helper(); return c.sh(c.dir+"/repo", "git", args...) }

func (c *mtCase) write(rel, body string) {
	c.t.Helper()
	p := filepath.Join(c.dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		c.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
		c.t.Fatal(err)
	}
}

func (c *mtCase) read(rel string) string {
	b, _ := os.ReadFile(filepath.Join(c.dir, rel))
	return strings.TrimRight(string(b), "\n")
}

func (c *mtCase) has(rel string) bool {
	_, err := os.Stat(filepath.Join(c.dir, rel))
	return err == nil
}

func (c *mtCase) touch(rel string) { c.write(rel, "") }

// newMtCase builds the origin, the repo clone (base.txt and shared.txt on main), the squash clone and the PATH stubs.
func newMtCase(t *testing.T) *mtCase {
	t.Helper()
	c := &mtCase{t: t, dir: t.TempDir()}
	for _, d := range []string{"bin", "state"} {
		if err := os.MkdirAll(filepath.Join(c.dir, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range mtTools {
		if p, err := exec.LookPath(name); err == nil {
			_ = os.Symlink(p, filepath.Join(c.dir, "bin", name))
		}
	}
	for _, stub := range []struct{ from, to string }{{"gh", "bin/gh"}, {"merge-gate.sh", "merge-gate.sh"}, {"push-extra.sh", "push-extra.sh"}} {
		b, err := os.ReadFile(filepath.Join("testdata", "mergetrain", "stubs", stub.from))
		if err != nil {
			t.Fatal(err)
		}
		c.write(stub.to, string(b))
	}
	c.write("calls.log", "")
	c.sh(c.dir, "git", "init", "-q", "--bare", "-b", "main", c.dir+"/origin.git")
	c.sh(c.dir, "git", "init", "-q", "-b", "main", c.dir+"/repo")
	c.git("remote", "add", "origin", c.dir+"/origin.git")
	c.write("repo/base.txt", "base\n")
	c.write("repo/shared.txt", "base\n")
	c.git("add", ".")
	c.git("commit", "-q", "-m", "base")
	c.git("push", "-q", "origin", "main")
	c.git("fetch", "-q", "origin")
	c.sh(c.dir, "git", "clone", "-q", c.dir+"/origin.git", c.dir+"/sq")
	c.env = append(mtHostEnv(), "PATH="+c.dir+"/bin", "HOME="+c.dir, "CASE="+c.dir, "KIT_RETRY_SLEEP=0", "KIT_POLL_SLEEP=0",
		"KIT_MERGE_SLEEP=0", "KIT_MERGE_TRIES=1", "KIT_GATE_LOCK_TIMEOUT=2", "KIT_MERGE_GATE="+c.dir+"/merge-gate.sh")
	return c
}

// mkpr is a PR head branched from the CURRENT origin/main, pushed to refs/pull/N/head. file/content default to
// pr-N.txt / N.
func (c *mtCase) mkpr(n int, file, content string) {
	c.t.Helper()
	if file == "" {
		file = fmt.Sprintf("pr-%d.txt", n)
	}
	if content == "" {
		content = fmt.Sprint(n)
	}
	c.git("checkout", "-q", "-B", fmt.Sprintf("pr%d", n), "origin/main")
	c.write("repo/"+file, content+"\n")
	c.write(fmt.Sprintf("repo/pr-%d.txt", n), fmt.Sprint(n)+"\n")
	c.git("add", ".")
	c.git("commit", "-q", "-m", fmt.Sprintf("pr %d", n))
	c.git("push", "-q", "origin", fmt.Sprintf("HEAD:refs/pull/%d/head", n))
	sha := c.git("rev-parse", "HEAD")
	c.write(fmt.Sprintf("head-%d", n), sha+"\n")
	c.write(fmt.Sprintf("pr-%d.json", n), fmt.Sprintf(`{"state":"OPEN","isDraft":false,"headRefOid":"%s","baseRefName":"main"}`+"\n", sha))
	c.git("checkout", "-q", "main")
}

func (c *mtCase) head(n int) string { return c.read(fmt.Sprintf("head-%d", n)) }

func (c *mtCase) advanceMain() {
	c.git("checkout", "-q", "main")
	c.write("repo/shared.txt", "Z\n")
	c.git("commit", "-q", "-am", "main moves")
	c.git("push", "-q", "origin", "main")
	c.git("fetch", "-q", "origin")
}

func (c *mtCase) editJSON(n int, from, to string) {
	p := fmt.Sprintf("pr-%d.json", n)
	c.write(p, strings.Replace(c.read(p), from, to, 1)+"\n")
}

// mtRun is what a scenario hands the runner.
type mtRun struct {
	prs     []string
	extra   []string // after --state-dir
	pinned  []int    // PRs that get --rdd-ok (nil = every PR)
	pinArgs []string // replaces the generated pins when set
	gate    string
	noState bool     // do not add the default --state-dir
	env     []string // appended to the scenario environment
	term    bool     // SIGTERM once the gate has started
	wrapTO  bool     // run under `timeout --preserve-status -s TERM 4` (bash side of term)
}

func (c *mtCase) pins(ns []int) []string {
	var out []string
	for _, n := range ns {
		out = append(out, "--rdd-ok", fmt.Sprintf("%d=%s", n, c.head(n)[:12]))
	}
	return out
}

func atoiList(prs []string) (ns []int) {
	for _, p := range prs {
		var n int
		if _, err := fmt.Sscan(p, &n); err == nil {
			ns = append(ns, n)
		}
	}
	return ns
}

func (r mtRun) args(c *mtCase) []string {
	args := []string{"--repo", c.dir + "/repo", "--gate-cmd", r.gate}
	if !r.noState {
		args = append(args, "--state-dir", c.dir+"/state")
	}
	args = append(args, r.extra...)
	pinned := r.pinned
	if pinned == nil {
		pinned = atoiList(r.prs)
	}
	if r.pinArgs != nil {
		args = append(args, r.pinArgs...)
	} else if len(pinned) > 0 && c.has(fmt.Sprintf("head-%d", pinned[0])) {
		args = append(args, c.pins(pinned)...)
	}
	return append(args, r.prs...)
}

// mtResult is everything one run left behind, normalised so two runs in different directories compare equal.
type mtResult struct {
	rc            int
	out, err      string
	calls         string
	receipt, post string
}

var mtTS = regexp.MustCompile(`\d{8}-\d{6}-\d+`)

func (c *mtCase) norm(s string) string {
	s = strings.ReplaceAll(s, c.dir, "<CASE>")
	return mtTS.ReplaceAllString(s, "<TS>")
}

func (c *mtCase) collect(rc int, out, errs string) mtResult {
	rcpt := ""
	if m, _ := filepath.Glob(c.dir + "/state/train-*.json"); len(m) > 0 {
		b, _ := os.ReadFile(m[0])
		rcpt = string(b)
	}
	ls := func(dir string) string {
		es, _ := os.ReadDir(filepath.Join(c.dir, dir))
		var names []string
		for _, e := range es {
			names = append(names, e.Name())
		}
		return strings.Join(names, " ")
	}
	refs := func(dir, pat string) string {
		cmd := exec.Command("git", "-C", dir, "for-each-ref", "--format=%(refname)", pat)
		cmd.Env = mtHostEnv()
		o, _ := cmd.Output()
		return strings.Join(strings.Fields(string(o)), " ")
	}
	orig := "gone"
	if c.has("orig-1") {
		orig = "kept"
	}
	post := fmt.Sprintf("remote-heads: %s\nlocal-branches: %s\nworktrees-left: %s\ntrain-refs: %s\norig-wt: %s\nstate-files: %s",
		refs(c.dir+"/origin.git", "refs/heads/"), refs(c.dir+"/repo", "refs/heads/train/*"), ls("repo-worktrees"),
		refs(c.dir+"/repo", "refs/train/"), orig, mtTS.ReplaceAllString(ls("state"), "<TS>"))
	return mtResult{rc: rc, out: c.norm(out), err: c.norm(errs), calls: c.norm(c.read("calls.log")), receipt: c.norm(rcpt), post: c.norm(post)}
}

// stubGate is the in-process merge gate of the Go side: the same shell stub the bash side reaches via KIT_MERGE_GATE.
func (c *mtCase) stubGate(args []string, s cli.Stdio) int {
	cmd := exec.Command("bash", append([]string{c.dir + "/merge-gate.sh"}, args...)...)
	cmd.Env, cmd.Dir = s.Environ(), s.Cwd
	var buf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &buf, &buf
	err := cmd.Run()
	_, _ = s.Out.Write(buf.Bytes())
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode()
	}
	return 0
}

func envLookup(env []string) func(string) string {
	return func(k string) string {
		for i := len(env) - 1; i >= 0; i-- {
			if v, ok := strings.CutPrefix(env[i], k+"="); ok {
				return v
			}
		}
		return ""
	}
}

// runGo runs the port in-process.
func (c *mtCase) runGo(r mtRun, deps func(*mtDeps)) mtResult {
	c.env = append(c.env, r.env...)
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: envLookup(c.env), Environ: func() []string { return c.env },
		Clock: time.Now, Cwd: c.dir}
	sigs := make(chan os.Signal, 2)
	d := mtDeps{mergeGate: c.stubGate, sleep: time.Sleep, pid: 4242,
		notify: func() (<-chan os.Signal, func()) { return sigs, func() {} }}
	if deps != nil {
		deps(&d)
	}
	if r.term {
		go func() {
			for i := 0; i < 400 && !c.has("gate-started"); i++ {
				time.Sleep(25 * time.Millisecond)
			}
			sigs <- syscall.SIGTERM
		}()
	}
	rc := runMergeTrain(r.args(c), s, d)
	return c.collect(rc, out.String(), errb.String())
}

// scenario is one named setup plus the contract it must meet.
type mtScn struct {
	name     string
	setup    func(c *mtCase) mtRun
	rc       int
	has      []string // substrings of stdout
	hasNot   []string
	merges   string // PR numbers whose merge gate ran, in order
	statuses string // receipt per-PR statuses, comma joined
	check    func(t *testing.T, c *mtCase, r mtResult)
}

func plain(prs ...int) []string {
	var out []string
	for _, n := range prs {
		out = append(out, fmt.Sprint(n))
	}
	return out
}

func (c *mtCase) mk(ns ...int) {
	for _, n := range ns {
		c.mkpr(n, "", "")
	}
}

func mtScenarios() []mtScn {
	g := mtGateRecord
	std := func(prs ...int) func(c *mtCase) mtRun {
		return func(c *mtCase) mtRun { c.mk(prs...); return mtRun{prs: plain(prs...), gate: g} }
	}
	return []mtScn{
		{name: "happy", setup: std(1, 2, 3), rc: 0, has: []string{"kit-merge-train: merged: all 3 PRs merged after one gate"}, merges: "1 2 3", statuses: "merged,merged,merged",
			check: func(t *testing.T, c *mtCase, r mtResult) {
				if n := strings.Count(r.calls, "GATE "); n != 1 {
					t.Errorf("gate ran %d times, want exactly 1", n)
				}
				if !strings.Contains(r.calls, "pr-1.txt pr-2.txt pr-3.txt") {
					t.Errorf("the gate did not see the three PRs combined\n%s", r.calls)
				}
				for _, n := range []int{1, 2, 3} {
					if want := fmt.Sprintf("MERGE %d head=%s", n, c.head(n)); !strings.Contains(r.calls, want) {
						t.Errorf("merge gate for #%d did not run at the PR head: want %q\n%s", n, want, r.calls)
					}
				}
				if strings.Index(r.calls, "GATE ") > strings.Index(r.calls, "MERGE ") {
					t.Errorf("the gate must run before the first merge\n%s", r.calls)
				}
				var rc map[string]any
				if err := json.Unmarshal([]byte(r.receipt), &rc); err != nil || rc["state"] != "merged" || rc["culprit"] != nil {
					t.Errorf("receipt = %s (%v)", r.receipt, err)
				}
				if strings.Contains(r.calls, "FETCH_HEAD") {
					t.Errorf("PR heads must be fetched into refs/train/<ts>/<pr>, never through FETCH_HEAD\n%s", r.calls)
				}
				if !strings.Contains(r.post, "remote-heads: refs/heads/main\n") || !strings.Contains(r.post, "local-branches: \nworktrees-left: \ntrain-refs: \norig-wt: gone") {
					t.Errorf("train branch/worktrees/refs not cleaned or branch pushed:\n%s", r.post)
				}
			}},
		{name: "conflict-mid", setup: func(c *mtCase) mtRun {
			c.mkpr(1, "shared.txt", "A")
			c.mkpr(2, "shared.txt", "B")
			c.mk(3)
			return mtRun{prs: plain(1, 2, 3), gate: g}
		},
			rc: 27, has: []string{"train-conflict #2"}, merges: "1 3", statuses: "merged,dropped,merged"},
		{name: "conflict-last", setup: func(c *mtCase) mtRun {
			c.mk(1)
			c.mkpr(2, "shared.txt", "A")
			c.mkpr(3, "shared.txt", "B")
			return mtRun{prs: plain(1, 2, 3), gate: g}
		},
			rc: 27, has: []string{"train-conflict #3"}, merges: "1 2"},
		{name: "conflict-first", setup: func(c *mtCase) mtRun {
			c.mkpr(1, "shared.txt", "A")
			c.mk(2)
			c.advanceMain()
			return mtRun{prs: plain(1, 2), gate: g}
		},
			rc: 27, has: []string{"train-conflict #1"}, merges: "2"},
		{name: "conflict-all", setup: func(c *mtCase) mtRun {
			c.mkpr(1, "shared.txt", "A")
			c.advanceMain()
			return mtRun{prs: plain(1), gate: g}
		},
			rc: 28, has: []string{"kit-merge-train: train-empty"}, hasNot: []string{"GATE"}, merges: ""},
		{name: "rdd-mismatch", setup: func(c *mtCase) mtRun {
			c.mk(1, 2, 3)
			return mtRun{prs: plain(1, 2, 3), gate: g, pinArgs: []string{"--rdd-ok", "1=" + c.head(1)[:12], "--rdd-ok", "2=000000000123", "--rdd-ok", "3=" + c.head(3)[:12]}}
		}, rc: 27, has: []string{"train-refused #2: rdd-head-mismatch"}, merges: "1 3"},
		{name: "rdd-missing", setup: func(c *mtCase) mtRun { c.mk(1, 2); return mtRun{prs: plain(1, 2), gate: g, pinned: []int{1}} },
			rc: 27, has: []string{"train-refused #2: rdd-unconfirmed"}, merges: "1"},
		{name: "notopen", setup: func(c *mtCase) mtRun {
			c.mk(1, 2)
			c.editJSON(2, `"OPEN"`, `"MERGED"`)
			return mtRun{prs: plain(1, 2), gate: g}
		},
			rc: 27, has: []string{"train-refused #2: not-open"}, merges: "1"},
		{name: "draft", setup: func(c *mtCase) mtRun {
			c.mk(1, 2)
			c.editJSON(2, `"isDraft":false`, `"isDraft":true`)
			return mtRun{prs: plain(1, 2), gate: g}
		},
			rc: 27, has: []string{"train-refused #2: draft"}, merges: "1"},
		{name: "head-moved", setup: func(c *mtCase) mtRun {
			c.mk(1, 2)
			tip := c.git("rev-parse", "origin/main")
			p := "pr-2.json"
			c.write(p, regexp.MustCompile(`"headRefOid":"[0-9a-f]*"`).ReplaceAllString(c.read(p), `"headRefOid":"`+tip+`"`)+"\n")
			return mtRun{prs: plain(1, 2), gate: g, pinArgs: []string{"--rdd-ok", "1=" + c.head(1)[:12], "--rdd-ok", "2=" + tip[:12]}}
		}, rc: 27, has: []string{"train-refused #2: head-moved"}, merges: "1"},
		{name: "stacked", setup: func(c *mtCase) mtRun {
			c.mk(1, 2)
			c.editJSON(2, `"baseRefName":"main"`, `"baseRefName":"feat/other"`)
			return mtRun{prs: plain(1, 2), gate: g}
		},
			rc: 27, has: []string{"train-refused #2: base-not-main"}, merges: "1"},
		{name: "gh-view-failed", setup: func(c *mtCase) mtRun { c.mk(1, 2); c.touch("gh-fail-2"); return mtRun{prs: plain(1, 2), gate: g} },
			rc: 27, has: []string{"train-refused #2: gh pr view failed"}, merges: "1", statuses: "merged,refused"},
		{name: "gate-red", setup: func(c *mtCase) mtRun {
			c.mk(1)
			c.mkpr(2, "bad.txt", "")
			c.mk(3)
			return mtRun{prs: plain(1, 2, 3), gate: g}
		},
			rc: 26, has: []string{"kit-merge-train: train-gate-failed"}, merges: "", statuses: "pending,pending,pending",
			check: func(t *testing.T, c *mtCase, r mtResult) {
				if strings.Count(r.calls, "GATE ") != 1 || !strings.Contains(r.receipt, `"rc": 1`) || !strings.Contains(r.receipt, `"culprit": null`) {
					t.Errorf("want one gate call, gate rc 1 and no culprit without --bisect\n%s\n%s", r.calls, r.receipt)
				}
			}},
		{name: "bisect-mid", setup: func(c *mtCase) mtRun {
			c.mk(1, 2)
			c.mkpr(3, "bad.txt", "")
			c.mk(4)
			return mtRun{prs: plain(1, 2, 3, 4), gate: g, extra: []string{"--bisect"}}
		},
			rc: 26, has: []string{"culprit #3"}, merges: "", statuses: "pending,pending,culprit,pending",
			check: func(t *testing.T, c *mtCase, r mtResult) {
				if n := strings.Count(r.calls, "GATE "); n != 3 || !strings.Contains(r.receipt, `"culprit": 3`) {
					t.Errorf("want 3 gate runs and culprit 3 (got %d)\n%s", n, r.receipt)
				}
			}},
		{name: "bisect-first", setup: func(c *mtCase) mtRun {
			c.mkpr(1, "bad.txt", "")
			c.mk(2, 3, 4)
			return mtRun{prs: plain(1, 2, 3, 4), gate: g, extra: []string{"--bisect"}}
		},
			rc: 26, has: []string{"culprit #1"}},
		{name: "bisect-last", setup: func(c *mtCase) mtRun {
			c.mk(1, 2, 3)
			c.mkpr(4, "bad.txt", "")
			return mtRun{prs: plain(1, 2, 3, 4), gate: g, extra: []string{"--bisect"}}
		},
			rc: 26, has: []string{"culprit #4"}},
		{name: "bisect-single", setup: func(c *mtCase) mtRun {
			c.mkpr(1, "bad.txt", "")
			return mtRun{prs: plain(1), gate: g, extra: []string{"--bisect"}}
		},
			rc: 26, has: []string{"culprit #1"}, check: func(t *testing.T, c *mtCase, r mtResult) {
				if n := strings.Count(r.calls, "GATE "); n != 1 {
					t.Errorf("a single-PR batch needs no extra gate run, got %d", n)
				}
			}},
		{name: "bisect-locktimeout", setup: func(c *mtCase) mtRun {
			c.mk(1)
			c.mkpr(2, "bad.txt", "")
			c.mk(3)
			return mtRun{prs: plain(1, 2, 3), gate: `[ -e "$CASE/ran" ] || { touch "$CASE/ran"; sleep 6 & }; ` + g, extra: []string{"--bisect"}}
		}, rc: 26, has: []string{"kit-merge-train: train-gate-failed", "bisect-incomplete: gate-lock-timeout"}, merges: "",
			check: func(t *testing.T, c *mtCase, r mtResult) {
				// the full gate's rc and log are kept, not the bisect run's (old suite: gate.rc 1, gate.log gate-train-<ts>.log)
				var rc struct {
					Gate struct {
						RC  any    `json:"rc"`
						Log string `json:"log"`
					} `json:"gate"`
					Culprit any `json:"culprit"`
				}
				if err := json.Unmarshal([]byte(r.receipt), &rc); err != nil || rc.Gate.RC != float64(1) || rc.Culprit != nil ||
					!strings.HasSuffix(rc.Gate.Log, "/state/gate-train-<TS>.log") {
					t.Errorf("want gate rc 1, the full gate log gate-train-<ts>.log and no culprit: %s (%v)", r.receipt, err)
				}
			}},
		{name: "mgfail-first", setup: func(c *mtCase) mtRun { c.mk(1, 2, 3); c.touch("mg-fail-1"); return mtRun{prs: plain(1, 2, 3), gate: g} },
			rc: 19, has: []string{"kit-merge-train: not-merged"}, merges: "1", statuses: "pending,pending,pending"},
		{name: "mgfail-mid", setup: func(c *mtCase) mtRun { c.mk(1, 2, 3); c.touch("mg-fail-2"); return mtRun{prs: plain(1, 2, 3), gate: g} },
			rc: 19, has: []string{"kit-merge-train: not-merged"}, merges: "1 2", statuses: "merged,pending,pending"},
		{name: "mgfail-last", setup: func(c *mtCase) mtRun { c.mk(1, 2, 3); c.touch("mg-fail-3"); return mtRun{prs: plain(1, 2, 3), gate: g} },
			rc: 19, merges: "1 2 3", statuses: "merged,merged,pending"},
		{name: "cifail-mid", setup: func(c *mtCase) mtRun { c.mk(1, 2, 3); c.touch("ci-fail-2"); return mtRun{prs: plain(1, 2, 3), gate: g} },
			rc: 17, has: []string{"kit-merge-train: ci-failed", "lint fail"}, merges: "1"},
		{name: "mgdegrade", setup: func(c *mtCase) mtRun { c.mk(1, 2); c.touch("mg-degrade-1"); return mtRun{prs: plain(1, 2), gate: g} },
			rc: 18, has: []string{"kit-merge-train: merge-degraded"}, merges: "1"},
		{name: "ci-pending-retry", setup: func(c *mtCase) mtRun {
			c.mk(1)
			c.touch("mg-pending-1")
			return mtRun{prs: plain(1), gate: g, env: []string{"KIT_MERGE_TRIES=2"}}
		}, rc: 0, merges: "1 1", has: []string{"kit-wait-merge: retry 1/2 (pending)"}},
		{name: "base-moved-gate", setup: func(c *mtCase) mtRun {
			c.mk(1, 2)
			return mtRun{prs: plain(1, 2), gate: `bash "$CASE/push-extra.sh" gate-race; ` + g}
		}, rc: 30, has: []string{"kit-merge-train: base-moved"}, merges: ""},
		{name: "main-raced", setup: func(c *mtCase) mtRun { c.mk(1, 2, 3); c.touch("mg-race-2"); return mtRun{prs: plain(1, 2, 3), gate: g} },
			rc: 31, has: []string{"kit-merge-train: main-raced"}, merges: "1 2", statuses: "merged,merged,pending"},
		{name: "tree-mismatch", setup: func(c *mtCase) mtRun {
			c.mk(1, 2, 3)
			c.touch("mg-tweak-3")
			return mtRun{prs: plain(1, 2, 3), gate: g}
		},
			rc: 32, has: []string{"kit-merge-train: tree-mismatch"}, merges: "1 2 3"},
		{name: "tree-mismatch-prefix", setup: func(c *mtCase) mtRun {
			c.mk(1, 2, 3)
			c.touch("mg-tweak-1")
			c.touch("mg-fail-2")
			return mtRun{prs: plain(1, 2, 3), gate: g}
		},
			rc: 32, has: []string{"kit-merge-train: tree-mismatch"}, merges: "1 2"},
		{name: "oob", setup: func(c *mtCase) mtRun {
			c.mk(1, 2, 3)
			c.write("oob-2", "deadbeefdeadbeef\n")
			return mtRun{prs: plain(1, 2, 3), gate: g}
		},
			rc: 33, has: []string{"kit-merge-train: merged-out-of-band"}, merges: "1 2", statuses: "merged,out-of-band,pending"},
		{name: "term", setup: func(c *mtCase) mtRun {
			c.mk(1, 2)
			return mtRun{prs: plain(1, 2), gate: `touch "$CASE/gate-started"; sleep 30`, term: true, wrapTO: true}
		}, rc: 29, has: []string{"train-error: interrupted"}, check: func(t *testing.T, c *mtCase, r mtResult) {
			if !strings.Contains(r.post, "local-branches: \nworktrees-left: \ntrain-refs: \n") || !strings.Contains(r.receipt, `"state": "train-error"`) {
				t.Errorf("interrupted run must clean up and write the receipt\n%s\n%s", r.post, r.receipt)
			}
		}},
		{name: "merge-error", setup: func(c *mtCase) mtRun {
			c.mk(1, 2)
			c.write("repo/.git/hooks/pre-merge-commit", "#!/bin/sh\nexit 1\n")
			return mtRun{prs: plain(1, 2), gate: g}
		}, rc: 29, has: []string{"kit-merge-train: train-error: merging #1 failed without a conflict"}, merges: ""},
		{name: "pr-cwd", setup: func(c *mtCase) mtRun { return prCwdSetup(c, g, "ok") }, rc: 0, merges: "1 2",
			check: func(t *testing.T, c *mtCase, r mtResult) {
				if !strings.Contains(r.calls, "CWD 1 <CASE>/orig-1\n") || !strings.Contains(r.calls, "CWD 2 <CASE>/repo-worktrees/train-<TS>-pr2\n") || !strings.Contains(r.post, "orig-wt: kept") {
					t.Errorf("--pr-cwd: #1 must merge from its RDD worktree (left in place), #2 from the train's\n%s\n%s", r.calls, r.post)
				}
			}},
		{name: "pr-cwd-none", setup: func(c *mtCase) mtRun { return prCwdSetup(c, g, "none") }, rc: 19, has: []string{"review_due"}, merges: "1"},
		{name: "pr-cwd-wronghead", setup: func(c *mtCase) mtRun { return prCwdSetup(c, g, "wronghead") }, rc: 27, has: []string{"train-refused #1: pr-cwd-mismatch"}, merges: "2"},
		{name: "pr-cwd-foreign", setup: func(c *mtCase) mtRun { return prCwdSetup(c, g, "foreign") }, rc: 27, has: []string{"train-refused #1: pr-cwd-mismatch"}, merges: "2"},
		{name: "dry", setup: func(c *mtCase) mtRun {
			c.mk(1, 2)
			return mtRun{prs: plain(1, 2), gate: g, extra: []string{"--dry-run"}}
		}, rc: 0,
			has: []string{"kit-merge-train: plan: PRs 1 2 in order onto origin/main; one gate ("},
			check: func(t *testing.T, c *mtCase, r mtResult) {
				if r.calls != "" || c.has("repo-worktrees") || !strings.HasSuffix(r.post, "state-files: ") {
					t.Errorf("--dry-run must run no gh, make no worktree and write no state\ncalls=%q\n%s", r.calls, r.post)
				}
			}},
		{name: "nojq", setup: func(c *mtCase) mtRun { c.mk(1); _ = os.Remove(c.dir + "/bin/jq"); return mtRun{prs: plain(1), gate: g} }, rc: 3, has: []string{"degraded: missing runtime dependency: jq"}},
		{name: "nogh", setup: func(c *mtCase) mtRun { c.mk(1); _ = os.Remove(c.dir + "/bin/gh"); return mtRun{prs: plain(1), gate: g} }, rc: 3, has: []string{"degraded: missing runtime dependency: gh"}},
		{name: "noflock", setup: func(c *mtCase) mtRun {
			c.mk(1)
			_ = os.Remove(c.dir + "/bin/flock")
			return mtRun{prs: plain(1), gate: g}
		}, rc: 3, has: []string{"degraded: missing runtime dependency: flock"}},
		{name: "nofetch", setup: func(c *mtCase) mtRun {
			c.mk(1)
			_ = os.RemoveAll(c.dir + "/origin.git")
			return mtRun{prs: plain(1), gate: g}
		}, rc: 21, has: []string{"kit-merge-train: fetch-failed"}},
		{name: "usage-none", setup: func(c *mtCase) mtRun { return mtRun{gate: g} }, rc: 2, has: []string{"kit-merge-train: usage"}},
		{name: "usage-nan", setup: func(c *mtCase) mtRun { return mtRun{prs: []string{"x1"}, gate: g} }, rc: 2, has: []string{"usage: pr must be a number: x1"}},
		{name: "usage-dup", setup: func(c *mtCase) mtRun { c.mk(1); return mtRun{prs: plain(1, 1), gate: g} }, rc: 2, has: []string{"usage: a PR is listed twice"}},
		{name: "usage-state-in-repo", setup: func(c *mtCase) mtRun {
			c.mk(1)
			return mtRun{prs: plain(1), gate: g, noState: true, extra: []string{"--state-dir", c.dir + "/repo/state"}}
		}, rc: 2, has: []string{"is inside the repo"}},
		{name: "usage-serial-cmd", setup: func(c *mtCase) mtRun { c.mk(1); return mtRun{prs: plain(1), gate: g, extra: []string{"--serial"}} }, rc: 2, has: []string{"--serial cannot be combined with --gate-cmd"}},
		{name: "usage-badpin", setup: func(c *mtCase) mtRun {
			c.mk(1)
			return mtRun{prs: plain(1), gate: g, pinArgs: []string{"--rdd-ok", "1=zz"}}
		}, rc: 2, has: []string{"--rdd-ok SHA must be hex: 1=zz"}},
		{name: "usage-pin-no-equals", setup: func(c *mtCase) mtRun {
			c.mk(1)
			return mtRun{prs: plain(1), gate: g, pinArgs: []string{"--rdd-ok", "1234567"}}
		}, rc: 2, has: []string{"--rdd-ok wants PR=SHA with 7+ hex chars: 1234567"}},
		{name: "usage-pr-cwd-unlisted", setup: func(c *mtCase) mtRun {
			c.mk(1)
			return mtRun{prs: plain(1), gate: g, extra: []string{"--pr-cwd", "9=" + c.dir + "/repo"}}
		}, rc: 2, has: []string{"--pr-cwd names #9, which is not in the batch"}},
		{name: "usage-pr-cwd-malformed", setup: func(c *mtCase) mtRun {
			c.mk(1)
			return mtRun{prs: plain(1), gate: g, extra: []string{"--pr-cwd", "nodir"}}
		}, rc: 2, has: []string{"--pr-cwd PR must be a number: nodir"}},
		{name: "usage-unknown-option", setup: func(c *mtCase) mtRun { c.mk(1); return mtRun{prs: plain(1), gate: g, extra: []string{"--nope"}} }, rc: 2, has: []string{"usage: unknown option --nope"}},
		{name: "usage-base-ref", setup: func(c *mtCase) mtRun {
			c.mk(1)
			return mtRun{prs: plain(1), gate: g, extra: []string{"--base-ref", "main"}}
		}, rc: 2, has: []string{"--base-ref must be <remote>/<branch>: main"}},
		{name: "help", setup: func(c *mtCase) mtRun { return mtRun{gate: g, extra: []string{"--help"}} }, rc: 0, has: []string{"# kit-merge-train.sh [options] <pr> [<pr>...]", "#   merged-out-of-band 33"}},
	}
}

// prCwdSetup: PR 1's RDD worktree (CASE/orig-1) is the only place its merge gate accepts. mode: ok | none |
// wronghead | foreign.
func prCwdSetup(c *mtCase, g, mode string) mtRun {
	c.mk(1, 2)
	c.git("worktree", "add", "-q", "--detach", c.dir+"/orig-1", c.head(1))
	phys, _ := filepath.EvalSymlinks(c.dir + "/orig-1")
	c.write("only-cwd-1", phys+"\n")
	r := mtRun{prs: plain(1, 2), gate: g}
	switch mode {
	case "ok":
		r.extra = []string{"--pr-cwd", "1=" + c.dir + "/orig-1"}
	case "wronghead":
		c.sh(c.dir+"/orig-1", "git", "checkout", "-q", "--detach", c.git("rev-parse", "origin/main"))
		r.extra = []string{"--pr-cwd", "1=" + c.dir + "/orig-1"}
	case "foreign":
		c.sh(c.dir, "git", "clone", "-q", c.dir+"/origin.git", c.dir+"/foreign")
		c.sh(c.dir+"/foreign", "git", "checkout", "-q", "--detach", c.head(1))
		r.extra = []string{"--pr-cwd", "1=" + c.dir + "/foreign"}
	}
	return r
}

func mergesOf(calls string) string {
	var out []string
	for _, ln := range strings.Split(calls, "\n") {
		if f := strings.Fields(ln); len(f) >= 2 && f[0] == "MERGE" {
			out = append(out, f[1])
		}
	}
	return strings.Join(out, " ")
}

func statusesOf(receipt string) string {
	var rc struct {
		PRs []struct{ Status string }
	}
	if json.Unmarshal([]byte(receipt), &rc) != nil {
		return "<no receipt>"
	}
	var out []string
	for _, p := range rc.PRs {
		out = append(out, p.Status)
	}
	return strings.Join(out, ",")
}

// TestMergeTrain pins the contract of each scenario on the port alone.
func TestMergeTrain(t *testing.T) {
	t.Parallel()
	if testing.Short() {
		t.Skip("builds git repositories and runs processes")
	}
	for _, sc := range mtScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()
			c := newMtCase(t)
			r := c.runGo(sc.setup(c), nil)
			if r.rc != sc.rc {
				t.Fatalf("rc = %d, want %d\nout=%s\nerr=%s\ncalls=%s", r.rc, sc.rc, r.out, r.err, r.calls)
			}
			for _, s := range sc.has {
				if !strings.Contains(r.out, s) {
					t.Errorf("stdout lacks %q\nout=%s", s, r.out)
				}
			}
			for _, s := range sc.hasNot {
				if strings.Contains(r.out+r.calls, s) {
					t.Errorf("run must not contain %q\nout=%s\ncalls=%s", s, r.out, r.calls)
				}
			}
			if sc.merges != "" || sc.rc != 2 && sc.rc != 3 && sc.name != "help" {
				if got := mergesOf(r.calls); got != sc.merges {
					t.Errorf("merge gates ran for %q, want %q\ncalls=%s", got, sc.merges, r.calls)
				}
			}
			if sc.statuses != "" {
				if got := statusesOf(r.receipt); got != sc.statuses {
					t.Errorf("receipt statuses = %s, want %s", got, sc.statuses)
				}
			}
			if sc.rc != 2 && sc.rc != 3 && sc.name != "help" && sc.name != "dry" && sc.name != "nofetch" {
				if !strings.Contains(r.post, "remote-heads: refs/heads/main") || strings.Contains(r.post, "refs/heads/train") {
					t.Errorf("the train branch must never be pushed:\n%s", r.post)
				}
				if !strings.Contains(r.post, "local-branches: \nworktrees-left: \ntrain-refs: \n") {
					t.Errorf("the train branch, worktrees and refs/train must be removed:\n%s", r.post)
				}
			}
			if sc.check != nil {
				sc.check(t, c, r)
			}
		})
	}
}

// TestMergeTrainRealMergeGate: RunMergeTrain wires the real, in-process merge gate. With no gentle-ai on PATH
// RunMerge itself degrades (`merge-gate: degraded:`), which the train maps to merge-degraded, and the
// KIT_MERGE_GATE script (which would log a WRONG call) is never run.
func TestMergeTrainRealMergeGate(t *testing.T) {
	if testing.Short() {
		t.Skip("builds git repositories and runs processes")
	}
	c := newMtCase(t)
	c.mk(1)
	c.write("wrong-gate.sh", "#!/usr/bin/env bash\necho WRONG >> \"$CASE/calls.log\"\nexit 0\n")
	c.env = append(c.env, "KIT_MERGE_GATE="+c.dir+"/wrong-gate.sh")
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: envLookup(c.env), Environ: func() []string { return c.env }, Clock: time.Now, Cwd: c.dir}
	rc := RunMergeTrain((mtRun{prs: plain(1), gate: mtGateRecord}).args(c), s)
	if rc != 18 || !strings.Contains(out.String(), "merge-gate: degraded:") || !strings.Contains(out.String(), "kit-merge-train: merge-degraded") {
		t.Errorf("rc=%d out=%s err=%s", rc, out.String(), errb.String())
	}
	if strings.Contains(c.read("calls.log"), "WRONG") {
		t.Errorf("KIT_MERGE_GATE was executed: the merge gate is in-process\n%s", c.read("calls.log"))
	}
}

// TestMergeTrainDegradedStderr: the rsdd process contract adds `DEGRADED:` on stderr to an exit 3 (the bash printed
// nothing there); usage and every other state print nothing on stderr.
func TestMergeTrainDegradedStderr(t *testing.T) {
	c := newMtCase(t)
	c.mk(1)
	_ = os.Remove(c.dir + "/bin/jq")
	r := c.runGo(mtRun{prs: plain(1), gate: mtGateRecord}, nil)
	if r.rc != 3 || !strings.Contains(r.err, "DEGRADED: missing runtime dependency: jq") {
		t.Errorf("rc=%d err=%q", r.rc, r.err)
	}
	c2 := newMtCase(t)
	r = c2.runGo(mtRun{gate: mtGateRecord}, nil)
	if r.rc != 2 || r.err != "" {
		t.Errorf("usage must not write stderr: rc=%d err=%q", r.rc, r.err)
	}
}

// TestMergeTrainKnobs pins the numeric environment knobs of the inlined kit-wait-merge and kit-gate.
func TestMergeTrainKnobs(t *testing.T) {
	c := newMtCase(t)
	c.mk(1)
	c.env = append(c.env, "KIT_GATE_LOCK_TIMEOUT=abc")
	r := c.runGo(mtRun{prs: plain(1), gate: mtGateRecord}, nil)
	if r.rc != 29 || !strings.Contains(r.out, "kit-gate: usage: --lock-timeout must be a number of seconds") || !strings.Contains(r.out, "train-error: kit-gate.sh exited 2") {
		t.Errorf("rc=%d out=%s", r.rc, r.out)
	}
}

// TestMergeTrainReceiptShape: key order and null handling of the receipt (the jq program's output).
func TestMergeTrainReceiptShape(t *testing.T) {
	c := newMtCase(t)
	c.mk(1)
	r := c.runGo(mtRun{prs: plain(1), gate: mtGateRecord}, nil)
	if r.rc != 0 {
		t.Fatalf("rc=%d out=%s", r.rc, r.out)
	}
	var keys []string
	dec := json.NewDecoder(strings.NewReader(r.receipt))
	_, _ = dec.Token()
	for dec.More() {
		k, _ := dec.Token()
		keys = append(keys, fmt.Sprint(k))
		var skip json.RawMessage
		_ = dec.Decode(&skip)
	}
	if want := "state base_sha train_branch train_sha gate culprit prs"; strings.Join(keys, " ") != want {
		t.Errorf("receipt keys = %v, want %s", keys, want)
	}
	if !strings.HasSuffix(r.receipt, "}\n") {
		t.Errorf("receipt must end with a newline: %q", r.receipt[len(r.receipt)-3:])
	}
}
