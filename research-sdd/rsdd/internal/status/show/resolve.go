package show

import (
	"fmt"
	"regexp"
	"strings"
)

// Ports of resolve_next, queue_next and resolve_next_q: which gap --next hands out. Each reads the state file
// named by ctx.state and answers the stdout the function printed (no trailing newline) and its rc: 0, 1 (the queue
// has nothing to serve) or 3 (a blocked-section read failed: no gap is handed out).

const stopExhausted = "STOP | read-only-investigable exhausted (0)"

// relState is _rel_state: the path relative to the target, since split layouts repeat basenames.
func (c *ctx) relState(p string) string {
	rest, ok := strings.CutPrefix(p, strings.TrimSuffix(c.target, "/")+"/")
	if !ok {
		return p
	}
	return rest
}

// degraded is the DEGRADED line every fatal blocked read prints.
func (c *ctx) degraded(gap string) string {
	return fmt.Sprintf("DEGRADED | blocked-rows read failed while resolving %s in %s — no gap is handed out; fix the failure named on stderr, then re-run", gap, c.relState(c.state))
}

// resolveNextWith is resolve_next over a given is_blocked (0 blocked, 1 not, 2 unknown): the first pending,
// non-blocked row of the highest tier that has one.
func (c *ctx) resolveNextWith(isBlocked func(gap string) int) (string, int) {
	rows, warn := backlogRows(c.stateText(), false)
	fmt.Fprint(c.s.Err, warn) // computed ONCE: the WARNs are not repeated per tier
	lines := strings.Split(strings.TrimRight(rows, "\n"), "\n")
	for _, prio := range [...]string{"high", "medium", "low"} {
		for _, line := range lines {
			if first, _, _ := strings.Cut(line, "\t"); first != prio {
				continue
			}
			_, gap, st := tabRead(line)
			// LEADING-TOKEN: bare or decorated `pending`, never "not pending" / "blocked (pending review)".
			if gap == "" || strings.Contains(gap, "~~") || statusToken(st) != "pending" {
				continue
			}
			switch isBlocked(gap) {
			case 0:
				continue
			case 1:
				return "NEXT | " + prio + " | " + gap, 0
			}
			return c.degraded(gap), 3 // RESOLVE-DEGRADED-FATAL (#2024 S3)
		}
	}
	return stopExhausted, 0
}

// resolveNextQ is resolve_next_q: the declared queue first when --queue was given. A degraded queue read never
// falls back to the priority walk.
func (c *ctx) resolveNextQ() (string, int) { return c.resolveNextQWith(c.blocker()) }

// blocker is the is_blocked read of the run: the real one unless a test replaced it.
func (c *ctx) blocker() func(gap string) int {
	if c.blockedHook != nil {
		return c.blockedHook
	}
	return c.isBlocked
}

func (c *ctx) resolveNextQWith(isBlocked func(gap string) int) (string, int) {
	if c.opts.queue {
		if out, rc := c.queueNextWith(isBlocked); rc != 1 {
			return out, rc
		}
	}
	return c.resolveNextWith(isBlocked)
}

var (
	queueFieldRE = regexp.MustCompile(`^(-[ \t\n\v\f\r]+)?next_session_queue:`)
	queueProseRE = regexp.MustCompile(`next[ _-]session[ _-]queue`)
)

// queueHeader is the awk both queue readers share over the header zone: the lines before the first `## `, outside
// HTML comments (a line that holds `<!--` is dropped whole, and so is every line up to the one that holds `-->`).
func queueHeader(text string, keep func(line string) bool) []string {
	var hits []string
	inComment := false
	for _, rec := range splitLines(text) {
		if strings.HasPrefix(rec, "## ") {
			break
		}
		if strings.Contains(rec, "<!--") {
			inComment = true
		}
		if inComment {
			inComment = !strings.Contains(rec, "-->")
			continue
		}
		if keep(rec) {
			hits = append(hits, rec)
		}
	}
	return hits
}

// isGapID is `grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'`.
func isGapID(id string) bool {
	if id == "" || !isAlnum(id[0]) {
		return false
	}
	for i := 1; i < len(id); i++ {
		if b := id[i]; !isAlnum(b) && b != '.' && b != '_' && b != '-' {
			return false
		}
	}
	return true
}

// stripMarks is the two passes of `lead="${lead#\*\*}"; lead="${lead#\~\~}"; lead="${lead#\`}"` over a gap cell.
func stripMarks(gap string) string {
	for range 2 {
		gap = strings.TrimPrefix(strings.TrimPrefix(strings.TrimPrefix(gap, "**"), "~~"), "`")
	}
	return gap
}

// queueClass is the class one matching backlog row puts a queued id in: serve, blocked, terminal (closed or
// parked), deferred, inprogress. rc 3 is a degraded blocked read.
func (c *ctx) queueClass(pri, gap, st string, isBlocked func(gap string) int) (class string, rc int) {
	switch pri {
	case "deferred-open":
		return "deferred", 0
	case "deferred", "~~", "—":
		return "terminal", 0
	}
	if strings.Contains(gap, "~~") {
		return "terminal", 0
	}
	switch tok := statusToken(st); {
	case tok == "pending":
		switch isBlocked(gap) {
		case 0:
			return "blocked", 0
		case 1:
			return "serve", 0
		}
		return "", 3 // QUEUE-DEGRADED-FATAL (#2024)
	case strings.HasPrefix(tok, "blocked"), strings.HasPrefix(tok, "requires-execution"):
		return "blocked", 0
	case tok == "closed", tok == "[closed]", tok == "covered", tok == "[covered]", tok == "done", tok == "[done]",
		tok == "cubierto", tok == "[cubierto]", strings.HasPrefix(tok, "✅"), strings.HasPrefix(tok, "~~"):
		return "terminal", 0
	}
	return "inprogress", 0
}

// queueNextWith is queue_next over a given is_blocked: the first pending, non-blocked gap of this state file's `next_session_queue`, or a
// typed note on stderr and rc 1 saying why the priority order is used instead.
func (c *ctx) queueNextWith(isBlocked func(gap string) int) (string, int) {
	e := c.s.Err
	slug := strings.TrimSuffix(c.state[strings.LastIndexByte(c.state, '/')+1:], ".md")
	slug = strings.TrimPrefix(strings.TrimPrefix(slug, "RESEARCH-STATE"), "-")
	if slug == "" {
		slug = "root"
	}
	text := c.stateText()
	hits := queueHeader(text, queueFieldRE.MatchString)
	if len(hits) == 0 {
		if len(queueHeader(text, func(l string) bool { return queueProseRE.MatchString(lowerASCII(l)) })) > 0 {
			fmt.Fprintf(e, "INFO: queue-prose-only [%s]: header names a next-session queue in prose but declares no `next_session_queue:` field — priority order used\n", slug)
		} else {
			fmt.Fprintf(e, "INFO: queue-absent [%s]: no next_session_queue field in the header — priority order used\n", slug)
		}
		return "", 1
	}
	if len(hits) > 1 {
		fmt.Fprintf(e, "WARN: queue-malformed [%s]: next_session_queue declared more than once — field ignored, priority order used\n", slug)
		return "", 1
	}
	_, val, _ := strings.Cut(hits[0], "next_session_queue:")
	val = strings.Trim(val, cSpace)
	switch lowerASCII(val) {
	case "", "none", "[]":
		fmt.Fprintf(e, "INFO: queue-empty [%s]: next_session_queue is declared with no gap ids — priority order used\n", slug)
		return "", 1
	}
	if strings.HasSuffix(val, ",") {
		fmt.Fprintf(e, "WARN: queue-malformed [%s]: trailing comma in next_session_queue — field ignored, priority order used\n", slug)
		return "", 1
	}
	var ids []string
	for _, item := range strings.Split(val, ",") {
		id := strings.Trim(item, cSpace)
		if !isGapID(id) {
			fmt.Fprintf(e, "WARN: queue-malformed [%s]: item [%s] is not a gap id (want G1, G2, ... comma-separated) — field ignored, priority order used\n", slug, id)
			return "", 1
		}
		if contains(ids, id) {
			fmt.Fprintf(e, "WARN: queue-duplicate-id [%s]: id [%s] is queued more than once — later occurrence ignored\n", slug, id)
			continue
		}
		ids = append(ids, id)
	}
	// ONE parse with the closed-class rows, plus the OPEN deferred rows that parse leaves to count_deferred: a queued
	// gap that is closed or parked is KNOWN, never "unknown".
	closed, warn := backlogRows(text, true)
	fmt.Fprint(e, warn)
	open, warn := deferredScan(text, true)
	fmt.Fprint(e, warn)
	rows := strings.TrimRight(closed, "\n") + "\n" + strings.TrimRight(open, "\n") + "\n"
	var served string
	counts := map[string]int{}
	unknown := 0
	for n, id := range ids {
		cls, matched := "", 0
		var failed string
		readRows(rows, func(pri, gap, st string) {
			if gap == "" || failed != "" || pri == "UNCOUNTED" || pri == "INVALID_PRIORITY" || !queueMatches(stripMarks(gap), id) {
				return
			}
			matched++
			class, rc := c.queueClass(pri, gap, st, isBlocked)
			if rc != 0 {
				failed = gap
				return
			}
			if class == "serve" {
				if served == "" {
					served = "NEXT | " + pri + " | " + gap
				}
				cls = "serve"
			} else if cls == "" {
				cls = class
			}
		})
		if failed != "" {
			return c.degraded(failed), 3
		}
		counts[cls]++
		if matched > 1 {
			fmt.Fprintf(e, "WARN: queue-ambiguous-id [%s]: queued id [%s] (%d rows) matches several backlog rows — a servable one wins\n", slug, id, matched)
		}
		if matched == 0 {
			unknown++
			fmt.Fprintf(e, "WARN: queue-unknown-gap [%s]: queued id [%s] (position %d) matches no backlog row — skipped\n", slug, id, n+1)
		}
	}
	if served != "" {
		return served, 0
	}
	fmt.Fprintf(e, "INFO: queue-exhausted [%s]: next_session_queue (%d ids: %d done, %d deferred, %d blocked, %d in-progress, %d unknown) has no pending gap — priority order used\n",
		slug, len(ids), counts["terminal"], counts["deferred"], counts["blocked"], counts["inprogress"], unknown)
	return "", 1
}

// queueMatches is `case "$lead" in "$id") ;; "$id"[!A-Za-z0-9._-]*) ;;`: the id itself, or the id followed by a
// character that cannot continue an id (so G1 never matches G10 or G1-b).
func queueMatches(lead, id string) bool {
	rest, ok := strings.CutPrefix(lead, id)
	if !ok {
		return false
	}
	return rest == "" || !isAlnum(rest[0]) && rest[0] != '.' && rest[0] != '_' && rest[0] != '-'
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
