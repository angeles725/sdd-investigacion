//go:build !nodiff

package gate

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// The differential test: every scenario of the bash suite (and the jq/awk edge cases the port had to reproduce)
// runs against the frozen original (testdata/legacy, with its own lib/gh-visibility.sh) and against RunMerge,
// each with fresh stubs and a fresh log, and the two must agree on stdout, the exit code, the stderr text
// (minus the `DEGRADED:` lines the rsdd process contract adds on exit 3), the stub's call log (every gh and
// gentle-ai argument and the directory gh ran in) and every file the stubs wrote.
//
// Not compared, by design: jq's own `jq: error (at <stdin>:N): Cannot index ...` stderr lines for an assess answer
// that is not an object (the bash leaves them on the caller's stderr; the port reproduces the verdict, not jq's text), (see RunMerge): the `mktemp failed` degrade, the lib states of
// lib/gh-visibility.sh (watchdog note, CALLER_SIGNALLED, missing lib) and `--merge ""`.

type diffRig struct {
	w     *world
	cases []dsc
}

func (r *diffRig) add(sc dsc) { r.cases = append(r.cases, sc) }

func (r *diffRig) ck(specs ...string) string { return r.w.file(runsJSON(specs...) + "\n") }

// mg is a scenario against `repo` with the usual stub environment.
func (r *diffRig) mg(name, repo, assess string, args []string, extra ...string) dsc {
	env := append([]string{"STUB_JSON=" + assess, "STUB_PR_HEAD={HEAD}", "STUB_PR_BASE={PRB}", "STUB_MERGE_RC=0"}, extra...)
	return dsc{name: name, repo: repo, args: args, env: env}
}

var (
	argsPlain = []string{"--cwd", "{R}", "--base-ref", "base"}
	argsMerge = []string{"--cwd", "{R}", "--base-ref", "base", "--merge", "7"}
)

func with(base []string, more ...string) []string {
	return append(append([]string(nil), base...), more...)
}

func TestDifferentialAgainstLegacy(t *testing.T) {
	t.Parallel()
	if testing.Short() {
		t.Skip("runs the frozen bash original")
	}
	for _, tool := range []string{"bash", "jq", "git", "awk", "sed", "grep"} {
		if _, err := lookPath(tool); err != nil {
			t.Skipf("%s not on PATH", tool)
		}
	}
	w := newWorld(t)
	w.buildRepos()
	r := &diffRig{w: w}
	r.verdicts()
	r.arguments()
	r.repositories()
	r.prAndMerge()
	r.ciGate()
	r.pathFilters()
	r.closure()
	t.Logf("%d scenarios", len(r.cases))
	for _, sc := range r.cases {
		sc := sc
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()
			want, got := w.runLegacy(sc), w.runGo(sc)
			if normMoved(got.out) != normMoved(want.out) || got.rc != want.rc || normMoved(dropDegraded(got.err, got.out)) != normMoved(dropJQ(want.err)) || got.log != want.log || fmt.Sprint(got.side) != fmt.Sprint(want.side) {
				t.Fatalf("legacy and Go differ\nlegacy rc=%d out=%q err=%q\n   go  rc=%d out=%q err=%q\nlegacy log=%q\n   go  log=%q\nlegacy side=%q\n   go  side=%q",
					want.rc, want.out, dropJQ(want.err), got.rc, got.out, got.err, want.log, got.log, want.side, got.side)
			}
		})
	}
}

func (r *diffRig) verdicts() {
	w := r.w
	rawAssess := func(s string) string { return w.file(s) }
	good := assessJSON("false", "passive")
	cases := map[string]string{
		"passive": good, "already": assessJSON("false", "already_reviewed"), "under": assessJSON("false", "under_budget"),
		"high": assessJSON("true", "high_risk"), "slice": assessJSON("true", "slice_budget_reached"), "weird": assessJSON("false", "something_new"),
		"malformed": "{not json\n", "empty": "", "blank": "\n\n", "null": "null\n", "false": "false\n", "array": "[1]\n", "number": "5\n", "string": `"x"` + "\n",
		"badschema":   `{"schema":"other/v9","review_due":false,"review_due_reason":"passive"}` + "\n",
		"noschema":    `{"review_due":false,"review_due_reason":"passive"}` + "\n",
		"badbool":     `{"schema":"gentle-ai.review-assessment/v1","review_due":"no","review_due_reason":"passive"}` + "\n",
		"nobool":      `{"schema":"gentle-ai.review-assessment/v1","review_due_reason":"passive"}` + "\n",
		"noreason":    `{"schema":"gentle-ai.review-assessment/v1","review_due":false}` + "\n",
		"nullreason":  `{"schema":"gentle-ai.review-assessment/v1","review_due":false,"review_due_reason":null}` + "\n",
		"falsereason": `{"schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":false}` + "\n",
		"truereason":  `{"schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":true}` + "\n",
		"numreason":   `{"schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":5}` + "\n",
		"objreason":   `{"schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":{"a":[1,2]}}` + "\n",
		"nlreason":    `{"schema":"gentle-ai.review-assessment/v1","review_due":false,"review_due_reason":"passive\n"}` + "\n",
		"multireason": `{"schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":"a\nb"}` + "\n",
		"dupkeys":     `{"schema":"x","schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":"a","review_due":false,"review_due_reason":"passive"}` + "\n",
		"twoobjects":  good + good,
		"objthennum":  good + " 5\n",
		"nullthenobj": "null " + good,
		"objthennull": good + " null\n",
		"objgarbage":  good + " garbage\n",
		"objthenarr":  good + " [1]\n",
		"extrafields": `{"schema":"gentle-ai.review-assessment/v1","risk":"low","review_due":false,"review_due_reason":"under_budget","x":{"y":[1,{"z":null}]}}` + "\n",
		"bom":         "\xef\xbb\xbf" + good,
		"spaces":      "  \n" + good + "\n  ",
		"unicode":     `{"schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":"réé😀"}` + "\n",
		"badescape":   `{"schema":"gentle-ai.review-assessment/v1","review_due":true,"review_due_reason":"a\qb"}` + "\n",
		"trailcomma":  `{"schema":"gentle-ai.review-assessment/v1","review_due":false,"review_due_reason":"passive",}` + "\n",
	}
	for name, content := range cases {
		r.add(r.mg("assess "+name, "repo", rawAssess(content), argsPlain))
	}
	allowJSON, dueJSON := w.assessFile("false", "passive"), w.assessFile("true", "high_risk")
	for _, f := range []struct {
		name, json string
		env        []string
	}{
		{"rc1 allow-shaped", allowJSON, []string{"STUB_RC=1"}},
		{"rc2", allowJSON, []string{"STUB_RC=2"}},
		{"untracked", dueJSON, []string{"STUB_RC=1", "STUB_ERR=Error: untracked files require an explicit declaration"}},
		{"UNTRACKED upper", dueJSON, []string{"STUB_RC=1", "STUB_ERR=first\nUNTRACKED later"}},
		{"other error", dueJSON, []string{"STUB_RC=1", "STUB_ERR=Error: something else"}},
		{"long error", dueJSON, []string{"STUB_RC=1", "STUB_ERR=" + strings.Repeat("e", 260)}},
		{"unicode error", dueJSON, []string{"STUB_RC=1", "STUB_ERR=" + strings.Repeat("\u00e9", 150)}},
		{"empty error", allowJSON, []string{"STUB_RC=3"}},
	} {
		r.add(dsc{name: "assess failure " + f.name, repo: "repo", args: argsPlain, env: append([]string{"STUB_JSON=" + f.json}, f.env...)})
	}
	r.add(dsc{name: "HEAD moves during assess", repo: "repo", fresh: true, args: []string{"--cwd", "{R}", "--base-ref", "{BASE}"},
		env: []string{"STUB_JSON=" + w.assessFile("false", "passive"), "STUB_MOVE={R}"}})
	r.add(dsc{name: "assess log shape", repo: "repo", args: argsPlain, env: []string{"STUB_JSON=" + w.assessFile("false", "passive")}})
}

func (r *diffRig) arguments() {
	w := r.w
	p := w.assessFile("false", "passive")
	for name, args := range map[string][]string{
		"no args":            {},
		"cwd only":           {"--cwd", "{R}"},
		"base only":          {"--base-ref", "base"},
		"cwd no value":       {"--cwd"},
		"base no value":      {"--cwd", "{R}", "--base-ref"},
		"head no value":      {"--cwd", "{R}", "--base-ref", "base", "--head"},
		"pr no value":        {"--cwd", "{R}", "--base-ref", "base", "--pr"},
		"merge no value":     {"--cwd", "{R}", "--base-ref", "base", "--merge"},
		"checks no value":    {"--cwd", "{R}", "--base-ref", "base", "--required-checks"},
		"bogus":              {"--cwd", "{R}", "--base-ref", "base", "--bogus"},
		"pr abc":             {"--cwd", "{R}", "--base-ref", "base", "--pr", "abc"},
		"merge abc":          {"--cwd", "{R}", "--base-ref", "base", "--merge", "abc"},
		"merge 7x":           {"--cwd", "{R}", "--base-ref", "base", "--merge", "7x"},
		"merge -1":           {"--cwd", "{R}", "--base-ref", "base", "--merge", "-1"},
		"empty cwd":          {"--cwd", "", "--base-ref", "base"},
		"empty base":         {"--cwd", "{R}", "--base-ref", ""},
		"value looks a flag": {"--cwd", "--base-ref", "--base-ref", "base"},
		"last wins":          {"--cwd", "/nowhere", "--cwd", "{R}", "--base-ref", "x", "--base-ref", "base"},
		"empty pr":           {"--cwd", "{R}", "--base-ref", "base", "--pr", ""},
		"positional":         {"stray"},
	} {
		r.add(r.mg("args "+name, "repo", p, args))
	}
	r.add(r.mg("head matches", "repo", p, with(argsPlain, "--head", "{HEAD}")))
	r.add(r.mg("head abbreviated", "repo", p, with(argsPlain, "--head", "HEAD")))
	r.add(r.mg("head mismatch", "repo", p, with(argsPlain, "--head", "base")))
	r.add(r.mg("head unresolvable", "repo", p, with(argsPlain, "--head", "deadbeefnotacommit")))
	r.add(r.mg("base unresolvable", "repo", p, []string{"--cwd", "{R}", "--base-ref", "no-such-ref"}))
	r.add(r.mg("cwd not a repo", "repo", p, []string{"--cwd", "{ROOT}/not-a-repo", "--base-ref", "base"}))
	r.add(r.mg("cwd relative", "repo", p, []string{"--cwd", "../../../../../../../../../../tmp/none", "--base-ref", "base"}))
	for _, pm := range []struct{ mode, name string }{{"nojq", "jq"}, {"nogentle", "gentle-ai"}, {"nogit", "git"}} {
		sc := r.mg("probe "+pm.name+" missing", "repo", p, argsPlain)
		sc.path = pm.mode
		r.add(sc)
	}
	for _, flag := range []string{"--pr", "--merge"} {
		sc := r.mg("probe gh missing "+flag, "repo", p, with(argsPlain, flag, "7"))
		sc.path = "nogh"
		r.add(sc)
	}
}

func (r *diffRig) repositories() {
	w := r.w
	p := w.assessFile("false", "passive")
	r.add(r.mg("B2 main moved ahead", "r2", p, []string{"--cwd", "{R}", "--base-ref", "main"}))
	r.add(r.mg("N4 empty range", "r2", p, []string{"--cwd", "{R}", "--base-ref", "feat"}))
	r.add(r.mg("no common ancestor", "orphan", p, []string{"--cwd", "{R}", "--base-ref", "other"}))
	r.add(r.mg("unborn HEAD", "r0", p, []string{"--cwd", "{R}", "--base-ref", "HEAD"}))
	r.add(r.mg("narrow base without PR", "r3", p, []string{"--cwd", "{R}", "--base-ref", "HEAD~1"}))
}

func (r *diffRig) prAndMerge() {
	w := r.w
	p, high, mal := w.assessFile("false", "passive"), w.assessFile("true", "high_risk"), w.file("{bad\n")
	r.add(r.mg("merge", "repo", p, argsMerge))
	r.add(r.mg("merge no evidence", "repo", p, with(argsMerge, "--no-closure-evidence"), "STUB_CHECKS_JSON="+r.ck("shellcheck:completed:success", "toolbelt-tests:completed:success")))
	r.add(r.mg("merge refused", "repo", high, argsMerge))
	r.add(r.mg("merge degraded", "repo", mal, argsMerge))
	r.add(r.mg("pr head differs", "repo", p, argsMerge, "STUB_PR_HEAD={BASE}"))
	r.add(r.mg("pr head unreadable", "repo", p, argsMerge, "STUB_PR_HEAD="))
	r.add(r.mg("merge rc 1", "repo", p, argsMerge, "STUB_MERGE_RC=1"))
	r.add(r.mg("api fails", "repo", p, argsMerge, "STUB_API_FAIL=1"))
	r.add(r.mg("--pr", "repo", p, with(argsPlain, "--pr", "7")))
	r.add(r.mg("--pr head differs", "repo", p, with(argsPlain, "--pr", "7"), "STUB_PR_HEAD={BASE}"))
	r.add(r.mg("--pr then --merge", "repo", p, with(argsPlain, "--pr", "7", "--merge", "8"), "STUB_CHECKS_JSON="+r.ck("shellcheck:completed:success", "toolbelt-tests:completed:success")))
	r.add(r.mg("--merge then --pr", "repo", p, with(argsPlain, "--merge", "7", "--pr", "8"), "STUB_CHECKS_JSON="+r.ck("shellcheck:completed:success", "toolbelt-tests:completed:success")))
	for _, kv := range []struct{ name, msg string }{
		{"not mergeable", "X Pull request is not mergeable"},
		{"head modified", "Head branch was modified. Review and try the merge again."},
		{"deprecation first", "GraphQL: Projects (classic) is being deprecated in favor of the new Projects experience\nX Pull request is not mergeable"},
		{"deprecation then head", "GraphQL: Projects (classic) is being deprecated\nHead branch was modified. Review and try the merge again."},
		{"later line head", "X Merge failed\nHead branch was modified. Review and try the merge again."},
		{"warning first", "Warning: x\nreal"},
		{"only noise", "deprecated\nWARNING: y"},
		{"long", strings.Repeat("z", 250)},
		{"match-head-commit", "--match-head-commit mismatch"},
		{"head sha upper", "bad HEAD SHA"},
	} {
		r.add(r.mg("merge failure "+kv.name, "repo", p, argsMerge, "STUB_MERGE_RC=1", "STUB_MERGE_ERR="+kv.msg, "MERGE_GATE_REQUIRED_CHECKS=", "STUB_CHECKS_JSON="+r.ck("pr-validation:completed:success")))
	}
	// B1: a narrow base cannot hide earlier PR commits
	narrow := []string{"--cwd", "{R}", "--base-ref", "HEAD~1"}
	r.add(r.mg("B1 narrow base --merge", "r3", p, with(narrow, "--merge", "7")))
	r.add(r.mg("B1 narrow base --pr", "r3", p, with(narrow, "--pr", "7")))
	r.add(r.mg("B1 base is the branch point", "r3", p, []string{"--cwd", "{R}", "--base-ref", "c0", "--merge", "7"}, "STUB_CHECKS_JSON="+r.ck("shellcheck:completed:success", "toolbelt-tests:completed:success")))
	r.add(r.mg("PR base absent locally", "r3", p, []string{"--cwd", "{R}", "--base-ref", "c0", "--merge", "7"}, "STUB_PR_BASE=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"))
	r.add(r.mg("PR base unreadable", "r3", p, []string{"--cwd", "{R}", "--base-ref", "c0", "--merge", "7"}, "STUB_PR_BASE="))
	r.add(r.mg("PR base without common ancestor", "r3", p, []string{"--cwd", "{R}", "--base-ref", "c0", "--merge", "7"}, "STUB_PR_BASE={ORPHAN}"))
}

func (r *diffRig) ciGate() {
	w := r.w
	p := w.assessFile("false", "passive")
	run := func(name, req string, specs []string, extra ...string) {
		env := []string{"MERGE_GATE_REQUIRED_CHECKS=" + req, "STUB_CHECKS_JSON=" + r.ck(specs...)}
		args := with(argsMerge, "--no-closure-evidence")
		sc := r.mg("ci "+name, "repo", p, args, append(env, extra...)...)
		r.add(sc)
	}
	both := "shellcheck,toolbelt-tests"
	green := []string{"shellcheck:completed:success", "toolbelt-tests:completed:success", "pr-validation:completed:success"}
	run("green", both, green)
	run("skipped neutral", both, []string{"shellcheck:completed:success", "toolbelt-tests:completed:skipped", "pr-validation:completed:neutral"})
	names := []string{"shellcheck", "toolbelt-tests", "pr-validation"}
	for _, st := range []string{"queued:", "in_progress:", "waiting:", "completed:failure", "completed:cancelled", "completed:timed_out", "completed:action_required", "completed:stale", "completed:"} {
		for pos, n := range names {
			specs := append([]string(nil), green...)
			specs[pos] = n + ":" + st
			run(fmt.Sprintf("%s offender %d", st, pos), both, specs)
		}
		run("single "+st, "shellcheck", []string{"shellcheck:" + st})
	}
	run("failed outranks pending", both, []string{"shellcheck:in_progress:", "toolbelt-tests:completed:failure"})
	run("missing first", "a,b,c", []string{"b:completed:success", "c:completed:success"})
	run("missing middle", "a,b,c", []string{"a:completed:success", "c:completed:success"})
	run("missing last", "a,b,c", []string{"a:completed:success", "b:completed:success"})
	run("missing single", "a", []string{"other:completed:success"})
	run("missing literal", "a.b", []string{"axb:completed:success"})
	run("missing duplicates", "a,b,a", []string{"x:completed:success"})
	run("spaces and trailing comma", " shellcheck , toolbelt-tests ,", []string{"shellcheck:completed:success", "toolbelt-tests:completed:success"})
	run("opt-out env", "", []string{"pr-validation:completed:success"})
	run("opt-out pending", "", []string{"pr-validation:in_progress:"})
	run("opt-out failed", "", []string{"pr-validation:completed:failure"})
	run("opt-out zero checks", "", nil)
	run("flag overrides env", both, []string{"pr-validation:completed:success"}, "STUB_NOOP=1")
	r.add(r.mg("ci flag empty", "repo", p, with(argsMerge, "--no-closure-evidence", "--required-checks", ""), "MERGE_GATE_REQUIRED_CHECKS="+both, "STUB_CHECKS_JSON="+r.ck("pr-validation:completed:success")))
	r.add(r.mg("ci flag adds a name", "repo", p, with(argsMerge, "--no-closure-evidence", "--required-checks", "shellcheck,nope"), "STUB_CHECKS_JSON="+r.ck(green...)))
	r.add(r.mg("ci default set", "repo", p, with(argsMerge, "--no-closure-evidence"), "STUB_CHECKS_JSON="+r.ck("pr-validation:completed:success")))
	r.add(r.mg("ci default set passes", "repo", p, with(argsMerge, "--no-closure-evidence"), "STUB_CHECKS_JSON="+r.ck(green...)))
	r.add(r.mg("ci gh error", "repo", p, with(argsMerge, "--no-closure-evidence"), "STUB_CHECKS_FAIL=1", "STUB_CHECKS_JSON="+r.ck(green...)))
	for name, raw := range map[string]string{
		"malformed": "{not json", "off-shape": `{"total_count":1}`, "no name": `{"check_runs":[{"status":"completed","conclusion":"success"}]}`,
		"empty": "", "no id": `{"total_count":1,"check_runs":[{"name":"shellcheck","status":"completed","conclusion":"success"}]}`,
		"string id":         `{"check_runs":[{"id":"7","name":"shellcheck","status":"completed","conclusion":"success"}]}`,
		"two pages":         runsJSON("pr-validation:completed:success") + "\n" + runsJSON("shellcheck:completed:success"),
		"two pages failure": runsJSON("shellcheck:completed:success") + "\n" + runsJSON("toolbelt-tests:completed:failure"),
		"page garbage":      runsJSON("shellcheck:completed:success") + " garbage",
		"array page":        `[]`,
		"conclusion number": `{"check_runs":[{"id":1,"name":"shellcheck","status":"completed","conclusion":5}]}`,
		"conclusion true":   `{"check_runs":[{"id":1,"name":"shellcheck","status":"completed","conclusion":true}]}`,
		"app string":        `{"check_runs":[{"id":1,"name":"shellcheck","status":"completed","conclusion":"success","app":"x"},{"id":2,"name":"shellcheck","status":"completed","conclusion":"cancelled","app":null}]}`,
		"app false id":      `{"check_runs":[{"id":1,"name":"shellcheck","status":"completed","conclusion":"success","app":{"id":false}},{"id":2,"name":"shellcheck","status":"completed","conclusion":"cancelled"}]}`,
		"app object ids":    `{"check_runs":[{"id":1,"name":"s","status":"completed","conclusion":"cancelled","app":{"id":{"a":1}}},{"id":2,"name":"s","status":"completed","conclusion":"success","app":{"id":{"a":1}}}]}`,
		"float ids":         `{"check_runs":[{"id":1.5,"name":"s","status":"completed","conclusion":"cancelled"},{"id":2.5,"name":"s","status":"completed","conclusion":"success"}]}`,
		"equal ids":         `{"check_runs":[{"id":5,"name":"s","status":"completed","conclusion":"failure"},{"id":5,"name":"s","status":"completed","conclusion":"success"}]}`,
		"unicode names":     `{"check_runs":[{"id":1,"name":"é","status":"completed","conclusion":"failure"},{"id":2,"name":"z","status":"completed","conclusion":"failure"},{"id":3,"name":"B","status":"completed","conclusion":"failure"}]}`,
	} {
		r.add(r.mg("ci raw "+name, "repo", p, with(argsMerge, "--no-closure-evidence"), "MERGE_GATE_REQUIRED_CHECKS=shellcheck", "STUB_CHECKS_JSON="+w.file(raw+"\n")))
	}
	dedup := [][]string{
		{"shellcheck:completed:failure:1:10", "shellcheck:completed:success:1:20"},
		{"shellcheck:completed:success:1:20", "shellcheck:completed:failure:1:10"},
		{"shellcheck:completed:success:1:10", "shellcheck:completed:failure:1:20"},
		{"pr-validation:completed:success:1:1", "shellcheck:completed:success:1:10", "shellcheck:in_progress::1:20"},
		{"shellcheck:completed:failure:1:10", "shellcheck:queued::1:20"},
		{"shellcheck:completed:success:1:20", "shellcheck:completed:failure:2:10"},
		{"shellcheck:completed:failure:1:10", "shellcheck:completed:success:1:20", "shellcheck:completed:success:2:11"},
		{"shellcheck:completed:failure:1:9", "shellcheck:completed:success:1:10"},
		{"shellcheck:completed:cancelled:1:10", "shellcheck:completed:success:1:20", "pr-validation:completed:success:1:1"},
		{"shellcheck:completed:success:1:20", "shellcheck:completed:cancelled:1:10"},
		{"shellcheck:completed:success:1:10", "shellcheck:completed:cancelled:1:20"},
		{"shellcheck:completed:cancelled:1:10"},
		{"shellcheck:completed:cancelled:2:10", "shellcheck:completed:success:1:20"},
		{"shellcheck:completed:cancelled:1:10", "shellcheck:completed:success:1:20", "pr-validation:completed:failure:1:1"},
		{"b:completed:cancelled:1:1", "b:completed:success:1:2", "a:completed:cancelled:1:3", "a:completed:success:1:4"},
		{"s:completed:cancelled::1", "s:completed:cancelled:3:2", "s:completed:success:3:5", "s:completed:success::9"},
	}
	for i, specs := range dedup {
		r.add(r.mg(fmt.Sprintf("ci dedup %d", i), "repo", p, with(argsMerge, "--no-closure-evidence"), "MERGE_GATE_REQUIRED_CHECKS=shellcheck", "STUB_CHECKS_JSON="+r.ck(specs...)))
	}
	r.add(r.mg("ci review_due refuses before any read", "repo", w.assessFile("true", "high_risk"), with(argsMerge, "--no-closure-evidence")))
}

// movedSHA is the commit the stub's STUB_MOVE creates mid-run; its id depends on the clock, so only its shape is compared.
var movedSHA = regexp.MustCompile(` -> [0-9a-f]{40}\)`)

func normMoved(s string) string { return movedSHA.ReplaceAllString(s, " -> NEWHEAD)") }
