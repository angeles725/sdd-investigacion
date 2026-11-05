package flakehunt

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// ghRunner runs gh the way every other kit tool does: inside the repo, with the caller's environment (GH_TOKEN).
func (h *hunt) ghRunner() *kitmaint.Runner {
	return &kitmaint.Runner{Env: h.env, Cwd: h.s.Cwd, Now: h.s.Clock, Err: io.Discard, Getenv: h.s.Env}
}

// filenameSafe is true for a name made only of [A-Za-z0-9._-].
func filenameSafe(s string) bool {
	return strings.Trim(s, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-") == ""
}

// openIssue looks for an open issue whose title starts with `flake: <base> ` (a search hit alone is not a match, so
// `flake: myflaky.test.sh` never swallows `flaky.test.sh`). ok is false when the search itself failed.
func (h *hunt) openIssue(gh *kitmaint.Runner, base string) (number string, ok bool) {
	r := gh.Gh(h.repo, "issue", "list", "--state", "open", "--search", base+" in:title", "--limit", "100",
		"--json", "number,title", "-q", `.[] | "\(.number)\t\(.title)"`)
	if !r.OK() {
		return "", false
	}
	for _, line := range strings.Split(r.Out, "\n") {
		num, title, _ := strings.Cut(line, "\t")
		if strings.HasPrefix(strings.Trim(title, "\t"), "flake: "+base+" ") {
			return num, true
		}
	}
	return "", true
}

// issueBody is the text of the issue (or comment) for one finding.
func (h *hunt) issueBody(f finding) string {
	prove := 0
	if h.c.o.prove {
		prove = 1
	}
	body := fmt.Sprintf("Load %s found by kit-flake-hunt (kit issue #2209).\n\nsuite: %s\nclassification: %s\nfailed: %d/%d runs under load=%d (prove-teeth=%d)\nfirst failing line: %s\nresults: %s\n",
		f.kind, f.suite, f.kind, h.fails[f.suite], h.c.runs, h.c.load, prove, h.first[f.suite], h.results)
	if h.c.o.evidence != "" {
		body += "evidence: " + h.c.o.evidence + "\n"
	}
	return body
}

// fileIssues prints (dry) or runs (=apply) the gh command per flaky or broken suite: a comment on the open issue of
// that suite, else a new issue labelled type:bug. A failed search files nothing for the suite. rc is the exit code so
// far; the result is the final one (2 once anything was degraded) and, when a signal ended the work, its code.
func (h *hunt) fileIssues(found []finding, rc int) (code, interrupted int) {
	mode := h.c.o.fileMode
	if mode == fileNone || len(found) == 0 {
		return rc, 0
	}
	haveGH := len(kitmaint.MissingDeps(h.env, h.s.Cwd, "gh")) == 0
	if !haveGH && mode == fileApply {
		fmt.Fprint(h.s.Err, "degraded: kit-flake-hunt: gh not found; --file-issues=apply cannot file anything\n")
		return 2, 0
	}
	gh := h.ghRunner()
	for _, f := range found {
		if sig := h.intr.pending(); sig != 0 {
			return rc, sig
		}
		base := f.suite[strings.LastIndexByte(f.suite, '/')+1:]
		if !filenameSafe(base) {
			fmt.Fprintf(h.s.Err, "degraded: kit-flake-hunt: suite name '%s' is not filename-safe; not filing\n", base)
			rc = 2
			continue
		}
		existing, checked := "", false
		if haveGH {
			var ok bool
			if existing, ok = h.openIssue(gh, base); ok {
				checked = true
			} else if mode == fileApply {
				fmt.Fprintf(h.s.Err, "degraded: kit-flake-hunt: gh issue search failed for %s; nothing filed for it\n", base)
				rc = 2
				continue
			}
		}
		bodyFile := fmt.Sprintf("%s/issue-%s.md", h.out, base)
		_ = os.WriteFile(bodyFile, []byte(h.issueBody(f)), 0o644)
		cmd := []string{"gh", "issue", "create", "--title", fmt.Sprintf("flake: %s failed %d/%d under CPU load", base, h.fails[f.suite], h.c.runs),
			"--label", "type:bug", "--body-file", bodyFile}
		if existing != "" {
			cmd = []string{"gh", "issue", "comment", existing, "--body-file", bodyFile}
		}
		if mode != fileApply { // dry: never reach the mutating call
			fmt.Fprint(h.s.Out, "would run: "+shJoin(cmd))
			if !checked {
				fmt.Fprint(h.s.Out, "# dedupe not checked: gh unavailable or search failed")
			}
			fmt.Fprintln(h.s.Out)
			continue
		}
		fmt.Fprintln(h.s.Out, "running: "+shJoin(cmd))
		r := gh.Gh(h.repo, cmd[1:]...)
		fmt.Fprint(h.s.Out, r.Out)
		fmt.Fprint(h.s.Err, r.Err)
		if !r.OK() {
			fmt.Fprintf(h.s.Err, "degraded: kit-flake-hunt: gh failed for %s\n", base)
			rc = 2
		}
	}
	return rc, 0
}
