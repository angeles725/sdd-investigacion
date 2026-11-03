package show

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Ports of the counters and envelope readers of research-sdd-status.sh (count_investigable .. pick, section,
// stopctl). Each reads the state file named by ctx.state, as the script's functions read the global $state.

// stateText is the state file as awk reads it. A file that cannot be read yields no records (awk prints its own
// diagnostic and the pipeline sees nothing).
func (c *ctx) stateText() string {
	b, err := os.ReadFile(c.abs(c.state))
	if err != nil {
		return ""
	}
	return string(b)
}

// rows is `backlog_rows [want_closed] 2>/dev/null`.
func (c *ctx) rows(wantClosed bool) string {
	out, _ := backlogRows(c.stateText(), wantClosed)
	return out
}

// countDeferred is count_deferred: the number of open deferred rows.
func (c *ctx) countDeferred() string {
	out, warn := deferredScan(c.stateText(), false)
	fmt.Fprint(c.s.Err, warn)
	return out
}

// statusToken is `lead="${st#\*\*}"; lead="${lead/\*\*/}"; tok="${lead%% *}"`: the leading status token with one
// leading `**` and the first closing pair removed.
func statusToken(st string) string {
	lead := strings.Replace(strings.TrimPrefix(st, "**"), "**", "", 1)
	tok, _, _ := strings.Cut(lead, " ")
	return tok
}

// countInvestigable is count_investigable: the pending, non-blocked backlog rows, and its rc (3 when any
// blocked read failed, so the count is inflated). WARNs for rows whose status token is not recognised go to
// stderr.
func (c *ctx) countInvestigable() (n, rc int) { return c.countInvestigableWith(c.isBlocked) }

// countInvestigableWith is count_investigable over a given is_blocked (0 blocked, 1 not, 2 unknown).
func (c *ctx) countInvestigableWith(isBlocked func(gap string) int) (n, rc int) {
	readRows(c.rows(false), func(_, gap, st string) {
		if gap == "" || strings.Contains(gap, "~~") {
			return
		}
		tok := statusToken(st)
		if tok != "pending" {
			switch {
			case hasAnyPrefix(tok, "requires-execution", "blocked-on-", "~~", "✅") ||
				tok == "blocked" || tok == "blocked:" || tok == "blocked," ||
				tok == "closed" || tok == "[closed]" || tok == "covered" || tok == "[covered]" || tok == "done" || tok == "[done]" ||
				tok == "cubierto" || tok == "[cubierto]":
			case hasAnyPrefix(tok, "re-typed", "retyped"):
				fmt.Fprintf(c.s.Err, "WARN: re-typed row still carries \"re-typed\" — write its Status as the re-typed form \"blocked (requires-<what>)\" per METHODOLOGY §8b (or move it to the Blocked-gaps section) [gap: %s]\n", gap)
			default:
				fmt.Fprintf(c.s.Err, "WARN: unrecognised Status token [%s] in gap: %s\n", tok, gap)
			}
			return
		}
		switch isBlocked(gap) {
		case 0:
			return
		case 1:
		default:
			rc = 3
		}
		n++
	})
	return n, rc
}

// countRetyped is count_retyped_in_table: open rows whose leading status token is re-typed / retyped.
func (c *ctx) countRetyped() int {
	n := 0
	readRows(c.rows(false), func(_, gap, st string) {
		if gap == "" || strings.Contains(gap, "~~") {
			return
		}
		if hasAnyPrefix(statusToken(st), "re-typed", "retyped") {
			n++
		}
	})
	return n
}

// warnInplaceBlocked is warn_inplace_blocked FILE N: the typed WARN for the in-place blocked bucket.
func (c *ctx) warnInplaceBlocked(file string, n int) {
	if n <= 0 {
		return
	}
	fmt.Fprintf(c.s.Err, "sync-state: WARN: %s: %d in-place blocked row(s) (Status blocked / blocked-on-*) are open but not in blocked_open (section-derived) — NOT counted as closed in gaps_closed; move them to ## Blocked gaps (METHODOLOGY §21.1) so blocked_open and the known_gaps identity (verify-state CHECK H) agree.\n", file, n)
}

// inplaceBlocked is `backlog_rows 2>/dev/null | inplace_blocked_count "$(blocked_body)"`: the count and the
// pipeline's status, which under pipefail is awk's 2 when the state file cannot be read.
func (c *ctx) inplaceBlocked() (n, rc int) {
	if _, err := os.ReadFile(c.abs(c.state)); err != nil {
		rc = 2
	}
	return kit.InplaceBlockedCount(blockedBody(c.stateText()), c.rows(false)), rc
}

// countRequiresExecution is count_requires_execution: open rows anchored to the leading token requires-execution.
func (c *ctx) countRequiresExecution() int {
	n := 0
	readRows(c.rows(false), func(_, gap, st string) {
		if gap == "" {
			return
		}
		lead := strings.TrimPrefix(st, "**")
		if rest, ok := strings.CutPrefix(lead, "requires-execution"); !ok || rest != "" && isLowerAlnum(rest[0]) {
			return
		}
		if strings.Contains(gap, "~~") || strings.Contains(st, "~~") || strings.Contains(st, "✅") {
			return
		}
		n++
	})
	return n
}

func isLowerAlnum(b byte) bool { return isLower(b) || isDigit(b) }

// closedClassWarn are the WARNs of the closed-class parse that count_all_known_gaps lets through.
var closedClassWarn = regexp.MustCompile(`em-dash priority on an OPEN row|malformed closed-class backlog row|em-dash row whose Gap cell is not a gap id|near-miss backlog heading has no Priority header`)

// countAllKnownGaps is count_all_known_gaps: every backlog row incl. the closed-class ones, INVALID_PRIORITY and
// UNCOUNTED lines excluded. The closed-class WARNs of the parse reach stderr.
func (c *ctx) countAllKnownGaps() int {
	out, warn := backlogRows(c.stateText(), true)
	for _, l := range splitLines(warn) {
		if closedClassWarn.MatchString(l) {
			fmt.Fprintln(c.s.Err, l)
		}
	}
	n := 0
	for _, l := range splitLines(strings.TrimRight(out, "\n")) {
		if l != "" && !strings.HasPrefix(l, "INVALID_PRIORITY") && !strings.HasPrefix(l, "UNCOUNTED") {
			n++
		}
	}
	return n
}

// countUncountedRows is count_uncounted_rows: the UNCOUNTED lines of the closed-class parse.
func (c *ctx) countUncountedRows() int {
	n := 0
	for _, l := range splitLines(c.rows(true)) {
		if strings.HasPrefix(l, "UNCOUNTED") {
			n++
		}
	}
	return n
}

// blockIDs is `grep -oE '\bB[0-9]+\b'` over text: every B<digits> that is not part of a longer word.
func blockIDs(text string) []string {
	isWord := func(b byte) bool {
		return b == '_' || isAlnum(b)
	}
	var out []string
	for _, line := range strings.Split(text, "\n") {
		for i := 0; i < len(line); {
			if line[i] != 'B' || i > 0 && isWord(line[i-1]) {
				i++
				continue
			}
			j := i + 1
			for j < len(line) && isDigit(line[j]) {
				j++
			}
			if j > i+1 && (j == len(line) || !isWord(line[j])) {
				out = append(out, line[i:j])
				i = j
				continue
			}
			i++
		}
	}
	return out
}

// distinct is `sort -u | wc -l`.
func distinct(ids []string) int {
	seen := map[string]bool{}
	for _, id := range ids {
		seen[id] = true
	}
	return len(seen)
}

// blockColumnValues is the awk over the Iteration history body: the Block column's value of every row after the
// header. The reader splits the UNTRIMMED line on unescaped pipes (a leading pipe makes cell 1 the text before it,
// so a row without a leading pipe numbers its cells one lower than a row with one): internal/core/gfm.SplitRow
// strips both outer pipes and has no unstripped split, so the column index of this one reader is computed here
// (READERS.md, "Block column").
func blockColumnValues(body string) []string {
	var out []string
	col := 0
	for _, line := range splitLines(body) {
		if !strings.Contains(line, "|") {
			continue
		}
		line = strings.TrimSuffix(line, "\r")
		a := strings.Split(strings.ReplaceAll(line, `\|`, "\x01"), "|")
		if col == 0 {
			for i, v := range a {
				if lowerASCII(trimBlanks(v)) == "block" {
					col = i + 1
				}
			}
			continue
		}
		if len(a) >= col {
			out = append(out, trimBlanks(a[col-1]))
		}
	}
	return out
}

// countAttributedSG is count_attributed_sg: the distinct B<n> ids of ## Covered blocks, else of the Block column
// of ## Iteration history.
func (c *ctx) countAttributedSG() int {
	text := c.stateText()
	ids := blockIDs(sectionBody(text, "## Covered blocks"))
	if len(ids) == 0 {
		ids = blockIDs(strings.Join(blockColumnValues(sectionBody(text, "## Iteration history")), "\n"))
	}
	return distinct(ids)
}

// stopctl is the body of ## Stop control.
func (c *ctx) stopctl() string { return sectionBody(c.stateText(), "## Stop control") }

// stripParens is `sed -E 's/\([^)]*\)//g'` on one line.
func stripParens(s string) string {
	var b strings.Builder
	for {
		open := strings.IndexByte(s, '(')
		if open < 0 {
			break
		}
		end := strings.IndexByte(s[open+1:], ')')
		if end < 0 {
			break
		}
		b.WriteString(s[:open])
		s = s[open+1+end+1:]
	}
	b.WriteString(s)
	return b.String()
}

// reqProse is req_prose: the first integer after the token requires-execution in ## Stop control, parenthesised
// asides stripped first and the token matched case-blind; "" when there is none.
func (c *ctx) reqProse() string {
	for _, line := range splitLines(c.stopctl()) {
		line = stripParens(line)
		i := strings.Index(lowerASCII(line), "requires-execution")
		if i < 0 {
			continue
		}
		rest := line[i+len("requires-execution"):]
		d := strings.IndexAny(rest, "0123456789")
		if d < 0 {
			continue
		}
		e := d
		for e < len(rest) && isDigit(rest[e]) {
			e++
		}
		return rest[d:e]
	}
	return ""
}

// envField returns the envelope block of the state file: the lines between the research-state.v1 markers (the
// markers are regexes in the script, their dots match any byte).
var (
	envOpen  = regexp.MustCompile(`(?s)<!-- research-state.v1 -->`)
	envClose = regexp.MustCompile(`(?s)<!-- /research-state.v1 -->`)
)

// envLines is the lines of the CURRENT envelope.
func envLines(text string) []string {
	var out []string
	in := false
	for _, line := range splitLines(text) {
		if envOpen.MatchString(line) {
			in = true
			continue
		}
		if envClose.MatchString(line) {
			in = false
		}
		if in {
			out = append(out, line)
		}
	}
	return out
}

// envGet is env_get <key>: the second field of the first envelope line whose first field is `key:`, CR removed.
// found is false when no line matches (the script prints nothing).
func (c *ctx) envGet(key string) (val string, found bool) {
	for _, line := range envLines(c.stateText()) {
		f := awkFields(line)
		if len(f) > 0 && f[0] == key+":" {
			if len(f) > 1 {
				val = strings.TrimSuffix(f[1], "\r")
			}
			return val, true
		}
	}
	return "", false
}

// envRaw is env_raw <key>: everything after `key:` on the first envelope line that starts with it (indent
// tolerated), blanks and CR trimmed; found is false when the key is absent.
func (c *ctx) envRaw(key string) (val string, found bool) {
	for _, line := range envLines(c.stateText()) {
		l := strings.TrimLeft(line, cSpace)
		if strings.HasPrefix(l, key+":") {
			return strings.TrimRight(strings.TrimLeft(l[len(key)+1:], cSpace), cSpace), true
		}
	}
	return "", false
}

var (
	covLabel = regexp.MustCompile(`(?i)^[ \t\n\v\f\r]*([-*+][ \t\n\v\f\r]+)?\*{0,2}coverage metric\*{0,2}[ \t\n\v\f\r]*(\([^)]*\))?\*{0,2}[ \t\n\v\f\r]*[:=]`)
	covRatio = regexp.MustCompile(`[0-9]+[ \t\n\v\f\r]*/[ \t\n\v\f\r]*[0-9]+`)
)

// covRatioOf is cov_ratio: the N/M of the Coverage metric field of ## Coverage ("" when none), with the spaces
// of the match removed. A line that mentions the phrase and a ratio but does not carry the label draws a typed WARN
// when no line carries the label at all.
func (c *ctx) covRatioOf() string {
	lines := splitLines(sectionBody(c.stateText(), "## Coverage"))
	r, labelled := "", false
	for _, l := range lines {
		if covLabel.MatchString(l) {
			labelled = true
			if r == "" {
				r = strings.ReplaceAll(covRatio.FindString(l), " ", "")
			}
		}
	}
	if r == "" && !labelled {
		for _, l := range lines {
			if strings.Contains(lowerASCII(l), "coverage metric") && covRatio.MatchString(l) {
				l = l[:min(len(l), 100)]
				fmt.Fprintf(c.s.Err, "WARN: %s: unrecognised coverage label — a line mentions the coverage metric with a ratio but does not start with the \"Coverage metric:\" label, so it is NOT read as the metric: %s\n", filepath.Base(c.state), l)
				break
			}
		}
	}
	return r
}

// pick is pick <parsed> <previous>: a freshly parsed integer, else the previous envelope value, else 0.
func pick(parsed, previous string) string {
	isInt := func(s string) bool { return s != "" && strings.Trim(s, "0123456789") == "" }
	switch {
	case isInt(parsed):
		return parsed
	case isInt(previous):
		return previous
	}
	return "0"
}
