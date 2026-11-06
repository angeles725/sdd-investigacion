package gate

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// firstLine is `head -n 1 | cut -c1-200` over captured stderr: the first line, cut to 200 bytes.
func firstLine(b []byte, max int) string {
	l, _, _ := strings.Cut(stripNUL(string(b)), "\n")
	if len(l) > max {
		l = l[:max]
	}
	return l
}

// containsFold is `grep -qi`, ASCII case folding only.
func containsFold(s, sub string) bool {
	return strings.Contains(asciiLower(s), asciiLower(sub))
}

func asciiLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

// assess asks gentle-ai and refuses on review_due. Its own answer is trusted: this gate re-implements none of
// the "this exact range was acknowledged" logic, and a non-zero assess is degraded even when its stdout happens
// to look like an allow.
func (g *mergeGate) assess() (code int, done bool) {
	c := g.r.GentleAI("review", "assess", "--cwd", g.cwd, "--base-ref", g.mb, "--committed-only", "--json")
	if c.RC != 0 {
		// Surface gentle-ai's own first error line, plus our own hint for the common untracked-files cause.
		errLine := cmdSub(firstLine(c.Stderr, 200))
		hint := ""
		if containsFold(string(c.Stderr), "untracked") {
			hint = " — clean or ignore untracked files in " + g.cwd + " and retry"
		}
		why := "gentle-ai review assess failed (exit " + strconv.Itoa(c.RC) + ")"
		if errLine != "" {
			why += ": " + errLine
		}
		return g.degraded(why + hint), true
	}
	headAfter, _ := g.git("rev-parse", "--verify", "HEAD")
	if headAfter != g.head {
		after := headAfter
		if after == "" {
			after = "unknown"
		}
		return g.degraded("HEAD moved during assess (" + g.head + " -> " + after + "); rerun"), true
	}

	vals, ok := jqStream(string(c.Stdout))
	if !hookReadable(vals, ok) { // `jq -e .`
		return g.degraded("assess output is unparseable JSON"), true
	}
	schema := jqEach(vals, jqOptKey("schema"))
	if schema != "gentle-ai.review-assessment/v1" {
		if schema == "" {
			schema = "<none>"
		}
		return g.degraded("unexpected assess schema: " + schema), true
	}
	due := jqEach(vals, func(v json.RawMessage) (string, bool) {
		f, ok := jqIndex(v, "review_due")
		if !ok {
			return "", false
		}
		if jqType(f) == "boolean" {
			return jqRaw(f), true
		}
		return "invalid", true
	})
	if due != "true" && due != "false" {
		return g.degraded("assess review_due is missing or not a boolean"), true
	}
	reason := jqEach(vals, jqOptKey("review_due_reason"))
	if reason == "" {
		return g.degraded("assess review_due_reason is missing"), true
	}
	if due == "true" {
		g.say("refuse: review_due (%s) (head=%s base=%s merge_base=%s) — review this exact head before merging", reason, g.head, g.base, g.mb)
		return cli.ExitOperational, true
	}
	switch reason {
	case "passive", "already_reviewed", "under_budget":
	default:
		return g.degraded("unknown not-due reason from gentle-ai: " + reason + " (refusing to guess)"), true
	}
	g.reason = reason
	return 0, false
}
