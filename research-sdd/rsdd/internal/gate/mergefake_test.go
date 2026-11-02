package gate

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// This file is the hermetic rig of the merge-gate unit tests: a scripted mgRunner (no process is started) and a
// scenario that answers like a healthy repository, gentle-ai and GitHub until a test breaks one answer.
// Nothing here may live behind the `nodiff` build tag: gremlins builds the package with it.

const (
	hHead   = "1111111111111111111111111111111111111111"
	hBase   = "2222222222222222222222222222222222222222"
	hPRBase = "3333333333333333333333333333333333333333"
	hMerge  = "0123456789abcdef0123456789abcdef01234567"
)

func okOut(s string) mgCmd            { return mgCmd{Stdout: []byte(s)} }
func failWith(rc int, e string) mgCmd { return mgCmd{RC: rc, Stderr: []byte(e)} }

func assessJSON(due, reason string) string {
	return `{"schema":"gentle-ai.review-assessment/v1","risk":"high","review_due":` + due + `,"review_due_reason":"` + reason + `"}` + "\n"
}

// scn is one scripted world. The maps override single answers: gitAns is keyed by the space-joined git
// arguments, ghAns by the first two gh arguments, and a missing key falls back to the healthy default.
type scn struct {
	t       *testing.T
	environ []string
	missing map[string]bool
	gitAns  map[string]mgCmd
	ghAns   map[string]mgCmd
	ghbAns  map[string]mgCmd
	assess  mgCmd
	// workflows maps a tree id to its workflow files (path -> text); showFail lists unreadable ones.
	workflows     map[string]map[string]string
	showFail      map[string]bool
	prHead        string
	prBase        string
	checks        string
	files         string
	gql           string
	repoView      string
	calls         []string
	gitCalls      int
	moveHead      string // after the assess, HEAD answers this instead
	headAfterFail bool   // after the assess, HEAD cannot be read
	assessRan     bool
}

func newScn(t *testing.T) *scn {
	t.Helper()
	return &scn{
		t:        t,
		environ:  []string{"PATH=/bin"},
		missing:  map[string]bool{},
		showFail: map[string]bool{},
		gitAns:   map[string]mgCmd{},
		ghAns:    map[string]mgCmd{},
		ghbAns:   map[string]mgCmd{},
		assess:   okOut(assessJSON("false", "passive")),
		prHead:   hHead,
		prBase:   hPRBase,
		checks:   checkRuns(`{"id":5,"name":"shellcheck","status":"completed","conclusion":"success"}`, `{"id":6,"name":"toolbelt-tests","status":"completed","conclusion":"success"}`),
		files:    `[]`,
		repoView: "o/r\n",
	}
}

func checkRuns(runs ...string) string {
	return `{"total_count":` + fmt.Sprint(len(runs)) + `,"check_runs":[` + strings.Join(runs, ",") + `]}`
}

func (sc *scn) Has(name string) bool { return !sc.missing[name] }

func (sc *scn) Git(dir string, args ...string) mgCmd {
	sc.gitCalls++
	key := strings.Join(args, " ")
	sc.calls = append(sc.calls, "git "+key)
	if a, ok := sc.gitAns[key]; ok {
		return a
	}
	switch {
	case key == "rev-parse --git-dir":
		return okOut(".git\n")
	case key == "rev-parse --verify HEAD":
		if sc.assessRan && sc.headAfterFail {
			return failWith(128, "fatal")
		}
		if sc.assessRan && sc.moveHead != "" {
			return okOut(sc.moveHead + "\n")
		}
		return okOut(hHead + "\n")
	case strings.HasPrefix(key, "rev-parse --verify --quiet "):
		return okOut(hHead + "\n")
	case key == "merge-base HEAD main", key == "merge-base HEAD base":
		return okOut(hBase + "\n")
	case key == "merge-base HEAD "+hPRBase:
		return okOut(hBase + "\n")
	case strings.HasPrefix(key, "merge-base --is-ancestor "):
		return okOut("")
	case strings.HasPrefix(key, "rev-list --count "):
		return okOut("1\n")
	case strings.HasPrefix(key, "cat-file -e "):
		return okOut("")
	case strings.HasPrefix(key, "ls-tree --name-only "):
		tree := strings.Fields(key)[2]
		var names []string
		for p := range sc.workflows[tree] {
			names = append(names, p)
		}
		sortStrings(names)
		return okOut(strings.Join(names, "\n") + "\n")
	case strings.HasPrefix(key, "show "):
		tree, path, _ := strings.Cut(strings.TrimPrefix(key, "show "), ":")
		if sc.showFail[tree+":"+path] {
			return failWith(128, "fatal")
		}
		return okOut(sc.workflows[tree][path])
	}
	sc.t.Fatalf("unscripted git call: %s", key)
	return mgCmd{}
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

func (sc *scn) GentleAI(args ...string) mgCmd {
	sc.calls = append(sc.calls, "gentle-ai "+strings.Join(args, " "))
	sc.assessRan = true
	return sc.assess
}

func (sc *scn) GH(dir string, args ...string) mgCmd {
	sc.calls = append(sc.calls, "gh "+strings.Join(args, " "))
	key := args[0] + " " + args[1]
	if a, ok := sc.ghAns[key]; ok {
		return a
	}
	switch {
	case args[0] == "api" && strings.Contains(args[1], "/check-runs"):
		return okOut(sc.checks)
	case args[0] == "api" && strings.Contains(args[1], "/files"):
		return okOut(sc.files)
	case args[0] == "api" && strings.Contains(args[1], "/pulls/"):
		return okOut(fmt.Sprintf(`{"headRefOid":"%s","baseRefOid":"%s","baseRefName":"main"}`, sc.prHead, sc.prBase) + "\n")
	case args[0] == "pr" && args[1] == "merge":
		return okOut("")
	case args[0] == "issue" && args[1] == "comment":
		return okOut("")
	}
	sc.t.Fatalf("unscripted gh call: %v", args)
	return mgCmd{}
}

func (sc *scn) GHBounded(dir string, args ...string) mgCmd {
	sc.calls = append(sc.calls, "ghb "+strings.Join(args, " "))
	key := args[0] + " " + args[1]
	if a, ok := sc.ghbAns[key]; ok {
		return a
	}
	switch key {
	case "repo view":
		return okOut(sc.repoView)
	case "api graphql":
		return okOut(sc.gql)
	}
	sc.t.Fatalf("unscripted bounded gh call: %v", args)
	return mgCmd{}
}

// run executes the gate and returns stdout, stderr and the exit code.
func (sc *scn) run(args ...string) (out, errOut string, rc int) {
	var o, e bytes.Buffer
	s := cli.Stdio{Out: &o, Err: &e, Env: func(k string) string {
		v, _ := environLookup(sc.environ, k)
		return v
	}, Environ: func() []string { return sc.environ }, Cwd: "/work"}
	rc = runMerge(args, s, sc)
	return o.String(), e.String(), rc
}

// called reports whether some recorded call has the given prefix.
func (sc *scn) called(prefix string) bool {
	for _, c := range sc.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func mgArgs(extra ...string) []string {
	return append([]string{"--cwd", "/repo", "--base-ref", "main"}, extra...)
}
