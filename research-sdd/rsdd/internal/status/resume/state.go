package resume

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/envelope"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

const (
	stateSchema = "research-sdd.resume-state/v1"
	stateUsage  = "usage: resume-state.sh [--cwd DIR] [--base-ref REF] [--no-gh] [--json]"
	stateProg   = "resume-state.sh"
)

// stateArgs is the parsed command line of resume-state.sh.
type stateArgs struct {
	cwd, baseRef string
	useGH, json  bool
}

// parseStateArgs is the argument loop of the script, message for message. A non-negative rc ends the run with it.
func parseStateArgs(args []string, s cli.Stdio) (a stateArgs, rc int) {
	a = stateArgs{cwd: ".", useGH: true}
	usage := func() (stateArgs, int) { fmt.Fprintln(s.Err, stateUsage); return a, cli.ExitUsage }
	for i := 0; i < len(args); {
		switch arg := args[i]; arg {
		case "--cwd", "--base-ref":
			if i+1 >= len(args) {
				return usage()
			}
			if arg == "--cwd" {
				a.cwd = args[i+1]
			} else {
				a.baseRef = args[i+1]
			}
			i += 2
		case "--no-gh":
			a.useGH = false
			i++
		case "--json":
			a.json = true
			i++
		case "-h", "--help":
			fmt.Fprintln(s.Out, stateUsage)
			return a, cli.ExitOK
		default:
			fmt.Fprintf(s.Err, "%s: unknown argument: %s\n", stateProg, arg)
			return usage()
		}
	}
	return a, -1
}

// degradedState is the typed DEGRADED state: a line on stderr, exit 3, and with --json a degraded envelope on stdout
// so that a machine caller reads a typed state instead of an empty stdout.
func degradedState(s cli.Stdio, asJSON bool, reason string) int {
	fmt.Fprintf(s.Err, "DEGRADED: %s\n", reason)
	if asJSON {
		if b, err := envelope.Degraded(stateSchema, reason).Compact(envelope.ReasonBeforeCounts); err == nil {
			_, _ = s.Out.Write(b)
		}
	}
	return cli.ExitDegraded
}

// RunState is `rsdd status resume-state`: the port of resume-state.sh.
func RunState(args []string, s cli.Stdio) int {
	a, rc := parseStateArgs(args, s)
	if rc >= 0 {
		return rc
	}
	env := environ(s)
	if !onPath(env, s.Cwd, "git") {
		return degradedState(s, a.json, "git not found; cannot derive resume state")
	}
	if !onPath(env, s.Cwd, "jq") {
		return degradedState(s, a.json, "jq not found; cannot build the JSON document")
	}
	fail := func(format string, v ...any) int {
		fmt.Fprintf(s.Err, stateProg+": "+format+"\n", v...)
		return cli.ExitUsage
	}
	dir := abs(s.Cwd, a.cwd)
	if st, err := os.Stat(dir); a.cwd == "" || err != nil || !st.IsDir() {
		return fail("not a directory: %s", a.cwd)
	}
	g := git.Runner{Env: gitEnv(env), Now: s.Clock}
	out, err := g.Run(dir, "rev-parse", "--show-toplevel")
	if err != nil {
		return fail("not a git repository: %s", a.cwd)
	}
	top := strings.TrimRight(string(out), "\n")
	st := &stateRun{g: g, top: top, s: s, env: gitEnv(env)}
	if strings.HasPrefix(a.baseRef, "-") {
		return fail("--base-ref must not start with '-': %s", a.baseRef)
	}
	baseRef, baseSHA, msg := st.resolveBase(a.baseRef)
	if msg != "" {
		return fail("%s", msg)
	}
	st.baseRef = baseRef
	remote, _ := g.Run(top, "config", "--get", "remote.origin.url")
	if err := st.collectWorktrees(); err != nil {
		return fail("git worktree list failed")
	}
	st.collectBranches()
	prs, status, truncated := st.openPRs(a.useGH)
	doc := stateDoc{
		generatedAt: s.Clock().UTC().Format("2006-01-02T15:04:05Z"), top: top, remote: strings.TrimRight(string(remote), "\n"),
		baseRef: baseRef, baseSHA: baseSHA, wt: st.wt, br: st.br, prs: prs, prsStatus: status, prsTruncated: truncated,
	}
	var b []byte
	if a.json {
		b, err = doc.envelope()
		if err != nil {
			return fail("--json envelope build failed")
		}
	} else {
		b = doc.document()
	}
	_, _ = s.Out.Write(b)
	return cli.ExitOK
}

// stateRun is one collection: the repository, the base ref and what has been read from git so far.
type stateRun struct {
	g       git.Runner
	top     string
	baseRef string
	s       cli.Stdio
	env     []string
	wt      []worktree
	br      []branch
}

// resolveBase is the base-ref block of the script: the explicit ref, else origin/main, else main; and its commit.
func (r *stateRun) resolveBase(ref string) (baseRef, sha, msg string) {
	if ref == "" {
		for _, cand := range []string{"origin/main", "main"} {
			if _, ok, err := r.g.ResolveCommit(r.top, cand); err == nil && ok {
				ref = cand
				break
			}
		}
		if ref == "" {
			return "", "", "no origin/main or main to measure against; pass --base-ref REF"
		}
	}
	sha, ok, err := r.g.ResolveCommit(r.top, ref)
	if err != nil || !ok {
		return "", "", "cannot resolve base ref: " + ref
	}
	return ref, sha, ""
}

// counts is ab_json: ahead/behind of ref relative to the base ref, nil when git cannot count them.
func (r *stateRun) counts(ref string) (ahead, behind *int) {
	out, err := r.g.Run(r.top, "rev-list", "--left-right", "--count", r.baseRef+"..."+ref)
	if err != nil {
		return nil, nil
	}
	f := strings.Fields(string(out))
	if len(f) != 2 {
		return nil, nil
	}
	be, e1 := strconv.Atoi(f[0])
	ah, e2 := strconv.Atoi(f[1])
	if e1 != nil || e2 != nil {
		return nil, nil
	}
	return &ah, &be
}

type worktree struct {
	path, head, branch string
	exists, prunable   bool
	dirty, untracked   *int
	ahead, behind      *int
}

type branch struct {
	name, head    string
	ahead, behind *int
}

// collectWorktrees reads `git worktree list --porcelain` line by line, as the script does: a block ends at a blank line.
func (r *stateRun) collectWorktrees() error {
	out, err := r.g.Run(r.top, "worktree", "list", "--porcelain")
	if err != nil {
		return err
	}
	var path, head, br string
	var prunable bool
	flush := func() {
		if path != "" {
			r.addWorktree(path, head, br, prunable)
		}
		path = ""
	}
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		switch {
		case strings.HasPrefix(line, "worktree "):
			path, head, br, prunable = strings.TrimPrefix(line, "worktree "), "", "", false
		case strings.HasPrefix(line, "HEAD "):
			head = strings.TrimPrefix(line, "HEAD ")
		case strings.HasPrefix(line, "branch "):
			br = strings.TrimPrefix(strings.TrimPrefix(line, "branch "), "refs/heads/")
		case strings.HasPrefix(line, "prunable"):
			prunable = true
		case line == "":
			flush()
		}
	}
	flush()
	return nil
}

func (r *stateRun) addWorktree(path, head, br string, prunable bool) {
	w := worktree{path: path, head: head, branch: br, prunable: prunable}
	if st, err := os.Stat(path); err == nil && st.IsDir() {
		w.exists = true
		if out, err := r.g.Run(path, "--no-optional-locks", "status", "--porcelain"); err == nil {
			w.dirty, w.untracked = new(int), new(int)
			if status := strings.TrimRight(string(out), "\n"); status != "" {
				for _, line := range strings.Split(status, "\n") {
					if strings.HasPrefix(line, "??") {
						*w.untracked++
					} else {
						*w.dirty++
					}
				}
			}
		}
	}
	if head != "" {
		w.ahead, w.behind = r.counts(head)
	}
	r.wt = append(r.wt, w)
}

// collectBranches lists the local branches that no worktree has checked out, by full refname: a short name can be
// ambiguous with a tag and resolve elsewhere.
func (r *stateRun) collectBranches() {
	checkedOut := map[string]bool{}
	for _, w := range r.wt {
		if w.branch != "" {
			checkedOut[w.branch] = true
		}
	}
	out, err := r.g.Run(r.top, "for-each-ref", "--format=%(refname)", "refs/heads")
	if err != nil {
		return
	}
	for _, full := range strings.Split(string(out), "\n") {
		name := strings.TrimPrefix(full, "refs/heads/")
		if name == "" || checkedOut[name] {
			continue
		}
		sha, ok, err := r.g.ResolveCommit(r.top, "refs/heads/"+name)
		if err != nil || !ok {
			continue
		}
		b := branch{name: name, head: sha}
		b.ahead, b.behind = r.counts("refs/heads/" + name)
		r.br = append(r.br, b)
	}
}
