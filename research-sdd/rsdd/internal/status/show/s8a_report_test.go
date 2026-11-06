package show

import (
	"regexp"
	"strings"
	"testing"
)

// S8a: the default-report cases of the bash suites that the case map marks UNMAPPED. Every scenario is in the S6
// table (differential against the frozen script, replay golden); TestS8aReport states what the bash case asserted
// beyond the `want` line: absent text, the number of WARN lines and the gh calls.

type reportExp struct {
	notOut  []string // regexes stdout must not match
	count   map[string]int
	ghCalls []string // the exact gh argv lines ("" slice = none expected when ghNone)
	ghNone  bool
	notAll  []string // regexes neither stdout nor stderr may match
}

var s8aReportExp = map[string]reportExp{}

func s8aRep(sc s6Scenario, e reportExp) s6Scenario {
	s8aReportExp[sc.name] = e
	return sc
}

const outlineParity = `# Table Reader Parity — Outline Fixture
> Document-cycle state: nine Outline rows, each a variant of GFM-escaped pipes in the middle and last cells.
<!-- research-state.v1 -->
schema: research-state.v1
method: document-cycle
covered_blocks: 0
gaps_closed: 0
known_gaps: 0
investigable_open: 0
requires_execution_open: 0
blocked_open: 0
<!-- /research-state.v1 -->

## Coverage
- **Covered blocks**: 0
- **Coverage metric**: — (blank)

## Outline (the work-list)

| # | Outline item | Genre | Block | Status |
|---|---|---|---|---|
| 1 | item\|a | g | | covered |
| 2 | item\\|a | g | | covered |
| 3 | item\\\|a | g | | covered |
| 4 | i | g\|x | | covered |
| 5 | i | g\\|x | | covered |
| 6 | i | g\\\|x | | covered |
| 7 | i | g | | covered \| x |
| 8 | i | g | | covered \\| x |
| 9 | i | g | | covered \\\| x |

## Gap-backlog

## Iteration history

| # | Date | Item | Block | Delegated | New gaps uncovered |
|---|---|---|---|---|---|

## Blocked gaps

## Stop control
`

func s8aReportScenarios() []s6Scenario {
	var scs []s6Scenario
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	base := st6(1, "", row("high", "the gap", "pending"))
	pubGH := func(repo string) files { return spec("gh.o_"+repo+".out", "PUBLIC", "gh.out", "PRIVATE") }

	// main suite 970: split layout (one focus per sibling subdirectory): the default report's next step is not STOP.
	done := st4("", "0", 0, "", row("high", "done gap", "covered"))
	open := st4("", "0", 1, "", row("high", "open beta gap", "pending"))
	add(ws6("s8a-L970-split-layout-default-report-next-step", "next step       : NEXT | high | open beta gap",
		files{"corpus/alpha/RESEARCH-STATE.md": done, "corpus/beta/RESEARCH-STATE.md": open}, nil))

	// main suite 479 (#476): a `—` reopen row's form must not enter the saturation window forms.
	hist := "\n## Iteration history\n\n| # | New gaps uncovered |\n|---|---|\n| 1 | 0 |\n| 2 | BAD-ITER-form |\n| 3 | 0 |\n| — | REOPEN-form |\n"
	add(s8aRep(os6("s8a-L479-476-reopen-form-is-absent-from-the-window-forms", "unreadable window — 1 of last 3 rows unrecognised",
		st6(1, hist, row("high", "the gap", "pending")), nil, nil), reportExp{notOut: []string{`saturation.*REOPEN-form`}}))

	// visibility 6: a PUBLIC remote FIRST/MIDDLE/LAST among three PRIVATE ones is exactly one WARN, at its position.
	urls := map[string]string{"a": "https://github.com/o/a.git", "b": "https://github.com/o/b.git", "c": "https://github.com/o/c.git"}
	for pos, pub := range map[string]string{"first": "a", "middle": "b", "last": "c"} {
		u := map[string]string{}
		for k, v := range urls {
			u[k] = v
		}
		u[pub] = "https://github.com/o/PUB.git"
		add(s8aRep(os6("s8a-vis-6-public-remote-"+pos+"-of-three", "WARN public-remote: "+pub+" is PUBLIC", base,
			merge(gitRepo("a", u["a"], "b", u["b"], "c", u["c"]), pubGH("PUB")), nil), reportExp{count: map[string]int{`(?m)^WARN public-remote:`: 1}}))
	}
	add(s8aRep(os6("s8a-vis-6-single-public-remote", "WARN public-remote: only is PUBLIC", base,
		merge(gitRepo("only", "https://github.com/o/PUB.git"), pubGH("PUB")), nil), reportExp{count: map[string]int{`(?m)^WARN public-remote:`: 1}}))

	// visibility 9 and 10: only owner/repo reaches gh; an empty remote URL is degraded and gh is not called.
	add(s8aRep(os6("s8a-vis-9-https-token-only", pubWarn, base, merge(gitRepo("origin", "https://SECRETTOKEN@github.com/o/r"), spec("gh.out", "PUBLIC")), nil),
		reportExp{ghCalls: []string{"repo view o/r --json visibility --jq .visibility"}, notAll: []string{`SECRETTOKEN`}}))
	empty := files{"corpus/.git/HEAD": "ref: refs/heads/main\n", "corpus/.git/objects/": "", "corpus/.git/refs/": "", "corpus/.git/config": "[core]\n\trepositoryformatversion = 0\n[remote \"origin\"]\n\turl = \n"}
	add(s8aRep(os6("s8a-vis-10-empty-remote-url-is-degraded-and-gh-not-called", "degraded: remote-visibility: origin", base, merge(empty, spec("gh.out", "PUBLIC")), nil),
		reportExp{ghNone: true, notOut: []string{`(?m)^WARN public-remote`}}))

	// table-reader-parity 152: the Outline line counts nine covered rows with escaped pipes in middle and last cells.
	add(ws6("s8a-L152-outline-nine-of-nine-with-escaped-pipes", "outline         : 9/9 covered · drafted=0 · pending=0", files{"corpus/RESEARCH-STATE.md": outlineParity}, nil))

	// T-CQ-BSD-TZ: the age of a `Z` timestamp is UTC-correct under a non-UTC TZ (the port parses Z natively).
	none := "  campaign        : none (1 active focus, 0 with a queue)\n"
	add(os6("s8a-L5870-CQ-BSD-TZ-z-timestamp-age-under-a-non-utc-tz", none+"  last_iteration_ts: 2025-12-31T23:55:00Z  (age: 5 min)",
		tsOnly("last_iteration_ts: 2025-12-31T23:55:00Z"), nil, map[string]string{"TZ": "America/Los_Angeles"}))

	// T-W2-READONLY-TMPDIR-NO-WRITE-ATTEMPT: no filesystem write is attempted under an unusable TMPDIR.
	add(s8aRep(os6("s8a-L5984-W2-unwritable-tmpdir-never-written", "next step       : NEXT", base,
		files{"corpus/FOCUSES.md": fcHeader + fcRoot("", "")}, map[string]string{"TMPDIR": "/nonexistent-readonly-tmpdir"}),
		reportExp{notAll: []string{`(?i)permission denied|no such file`}}))
	return scs
}

func TestS8aReport(t *testing.T) {
	for _, sc := range s8aReportScenarios() {
		e := s8aReportExp[sc.name]
		t.Run(sc.name, func(t *testing.T) {
			root := sc.build(t)
			calls := &s6Calls{}
			tb := t.TempDir()
			env := s5Env{environ: sc.environ(root, t.TempDir(), "/nonexistent-bin"), toolbelt: tb}
			o := runGoS6(t, sc, root, env, &s6Replay{root: root, calls: calls})[0]
			out := strings.ReplaceAll(o.out, root, "<ROOT>")
			if sc.want != "" && !strings.Contains(out, sc.want) {
				t.Errorf("stdout lacks %q:\n%s", sc.want, out)
			}
			for _, re := range e.notOut {
				if regexp.MustCompile(re).MatchString(out) {
					t.Errorf("stdout must not match /%s/:\n%s", re, out)
				}
			}
			for _, re := range e.notAll {
				if regexp.MustCompile(re).MatchString(out + o.err) {
					t.Errorf("output must not match /%s/:\n%s%s", re, out, o.err)
				}
			}
			for re, n := range e.count {
				if got := len(regexp.MustCompile(re).FindAllString(out, -1)); got != n {
					t.Errorf("/%s/ matched %d times, want %d:\n%s", re, got, n, out)
				}
			}
			if e.ghNone && len(calls.gh) != 0 {
				t.Errorf("gh was called: %v", calls.gh)
			}
			if len(e.ghCalls) > 0 && strings.Join(calls.gh, "|") != strings.Join(e.ghCalls, "|") {
				t.Errorf("gh calls %v, want %v", calls.gh, e.ghCalls)
			}
		})
	}
}
