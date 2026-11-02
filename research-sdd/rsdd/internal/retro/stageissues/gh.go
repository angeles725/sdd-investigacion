package stageissues

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// The gh surface of --apply: every call carries an explicit --repo (the resolved kit issue repo), search is a
// fuzzy WORD match so every hit is re-checked for the exact signature line, and a reply is never trusted
// without proof it is a JSON array and that it was not cut off by --limit (anti-silent-zero, CLAUDE.md 7).

var (
	reStateOpen   = regexp.MustCompile(`"state":[[:space:]]*"OPEN"`)
	reStateClosed = regexp.MustCompile(`"state":[[:space:]]*"CLOSED"`)
	reStateAny    = regexp.MustCompile(`"state":[[:space:]]*"(OPEN|CLOSED)"`)
	reTotalLine   = regexp.MustCompile(`(?m)^total=([0-9]+)$`)
	reIssueURL    = regexp.MustCompile(`^https?://[^[:space:]]+/issues/([0-9]+)$`)
)

// gh runs `gh args` with stderr merged into the output (`2>&1`), trailing newlines dropped like `$(...)`.
func (a *app) gh(args ...string) (string, int) {
	r := a.exec("gh", args, true)
	return trimNL(r.Out), r.RC
}

// ghQuiet runs `gh args` with stderr discarded (`2>/dev/null`).
func (a *app) ghQuiet(args ...string) (string, int) {
	r := a.exec("gh", args, false)
	return trimNL(r.Out), r.RC
}

// startsArray is `grep -q '^[[:space:]]*\['`: SOME line of the reply opens a JSON array. A reply with no such line
// (an empty one included) is a failure, never "no match".
func startsArray(reply string) bool {
	for _, l := range strings.Split(reply, "\n") {
		if strings.HasPrefix(strings.TrimLeft(l, cSpace), "[") {
			return true
		}
	}
	return false
}

// hasLine is `grep -qxF -- line`: some line of text equals line.
func hasLine(text, line string) bool {
	for _, l := range strings.Split(text, "\n") {
		if l == line {
			return true
		}
	}
	return false
}

func stripCR(s string) string { return strings.ReplaceAll(s, "\r", "") }

// listFilled is _list_filled: the reply held at least --limit issues, so "no exact match in it" proves nothing.
// A scan output with no total= line is not a trustworthy reading either: it counts as filled (fail closed).
func (a *app) listFilled(scan string) bool {
	m := reTotalLine.FindStringSubmatch(scan)
	if m == nil {
		return true
	}
	t, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil {
		return false // bash `[ -ge ]` on an out-of-range number is an error, i.e. false
	}
	return t >= a.listLimitN
}

// exactSigMatches is _exact_sig_matches over a `gh issue list --json state,body` reply.
func exactSigMatches(sig, reply string) (string, error) {
	out, err := jsonIssueScan(scanSig, sig, reply)
	return trimNL(out), err
}

// ---- the target:<name> label (kit issue #1332)

// labelPresent is _label_present: true when the label exists (names compare case-insensitively, as GitHub's do);
// a probe that cannot answer is a typed degraded exit, never a guess.
func (a *app) labelPresent(name string) bool {
	out, rc := a.gh("label", "list", "--repo", a.repo, "--search", name, "--limit", "100", "--json", "name")
	if rc != 0 {
		a.errf("degraded: could not probe label '%s' on %s (gh label list exit %d): %s — no issue was created\n", name, a.repo, rc, out)
		a.exit(1)
	}
	if !startsArray(out) {
		a.errf("degraded: gh label list returned an unexpected reply for '%s' on %s (expected a JSON array): %s — no issue was created\n", name, a.repo, out)
		a.exit(1)
	}
	return strings.Contains(lowerASCII(removeSpace(out)), `"name":"`+lowerASCII(name)+`"`)
}

// ensureTargetLabel is ensure_target_label: probe ONCE, lazily before the first create; create the label with the
// fleet convention when it is missing; refuse an unregistered target (the basename fallback may be another kit's).
func (a *app) ensureTargetLabel() {
	if a.labelReady {
		return
	}
	lname := "target:" + a.targetName
	if !a.targetRegistered {
		a.errf("degraded: target '%s' is unregistered in %s (basename fallback) — refusing to create label '%s' or any issue on %s; register the target or run from the owning kit\n", a.targetName, a.targetsMD, lname, a.repo)
		a.exit(1)
	}
	if !a.labelPresent(lname) {
		cout, rc := a.gh("label", "create", lname, "--repo", a.repo, "--description", "Fleet target: "+a.targetName, "--color", "d4c5f9")
		if rc != 0 {
			// a concurrent run may have created the label between the probe and the create: look once more
			if !a.labelPresent(lname) {
				a.errf("degraded: label '%s' is missing on %s and could not be created: %s — no issue was created\n", lname, a.repo, cout)
				a.exit(1)
			}
		}
	}
	a.labelReady = true
}

// labelFlags is the `--label` list of gh issue create: the bash splits the comma list with `read -ra` and quotes a
// single quote, then expands the result unquoted, so each label is its own argument.
func labelFlags(labels string) []string {
	parts := strings.Split(labels, ",")
	if n := len(parts); n > 0 && parts[n-1] == "" {
		parts = parts[:n-1]
	}
	var out []string
	for _, l := range parts {
		out = append(out, "--label", strings.ReplaceAll(l, "'", `'\''`))
	}
	return out
}

// ---- re-check after a failed create (kit issue #1261, #1705)

// recheckExists is _recheck_exists: 0 an exact-signature issue (any state) exists NOW, 1 the lookup succeeded and
// found none, 2 the lookup itself failed or could not be parsed. It sets recheckState (found | none | unprovable)
// so the caller can tell "provably nothing written" from "could not look".
func (a *app) recheckExists(sig string) int {
	a.recheckState = "unprovable"
	r, rc := a.ghQuiet("issue", "list", "--state", "all", "--repo", a.repo, "--limit", a.listLimit, "--search", `"`+sig+`"`, "--json", "state,body")
	if rc != 0 || !startsArray(r) {
		return 2
	}
	scan, err := exactSigMatches(sig, r)
	if err != nil {
		return 2
	}
	if reStateAny.MatchString(scan) {
		a.recheckState = "found"
		return 0
	}
	a.recheckState = "none"
	return 1
}

// ---- mutation outcome triad (kit issue #1705)

func (a *app) rowNoWrite(row string) {
	a.mutNoWrite++
	a.outf("mutation_outcome: no_write (row %s)\n", row)
}

// rowUnknown: an unknown outcome may have landed a new issue the cached occurrence list cannot contain, so the
// cache is invalidated and the next row looks live again (kit issue #1753; one extra list call, only here).
func (a *app) rowUnknown(row string) {
	a.mutUnknown++
	a.outf("mutation_outcome: unknown (row %s)\n", row)
	a.occState = ""
}

func (a *app) rowConfirmed(row string) {
	a.mutConfirmed++
	a.outf("mutation_outcome: confirmed (row %s)\n", row)
}

// scrubRefuse: a row the privacy scrub could not clear is refused: typed ERROR, counted failed (exit 2), never written.
func (a *app) scrubRefuse(row, msg string) {
	a.errf("ERROR: %s\n", msg)
	a.failed++
	if a.apply {
		a.rowNoWrite(row)
	}
}

// ---- occurrence comments (kit issue #1708)

// occFetch is _occ_fetch: the ONE occurrence lookup per retro (kit issue #1753): the OPEN issues carrying the
// target label, listed once with no --search (so it is not a rate-limited search call) and cached; exact titles
// are matched locally. A failed call, a reply that is not a parseable array, or a page that fills --limit is a
// failed lookup: the typed ERROR is cached with an @ROW@ placeholder and replayed for every row.
func (a *app) occFetch() {
	a.occState = "failed"
	o, rc := a.gh("issue", "list", "--repo", a.repo, "--state", "open", "--label", "target:"+a.targetName, "--limit", a.listLimit, "--json", "number,state,title")
	if rc != 0 {
		a.occMsg = "ERROR: gh issue list (occurrence lookup) failed for row @ROW@: " + o
		return
	}
	if !startsArray(o) {
		a.occMsg = "ERROR: gh issue list (occurrence lookup) returned an unexpected reply for row @ROW@ (expected a JSON array): " + o
		return
	}
	m, err := jsonIssueScan(scanOcc, "", o)
	if err != nil {
		a.occMsg = "ERROR: gh issue list (occurrence lookup) reply could not be parsed for row @ROW@: " + o
		return
	}
	tm := reTotalLine.FindStringSubmatch(m)
	if tm == nil {
		a.occMsg = "ERROR: gh issue list (occurrence lookup) reply could not be counted for row @ROW@: " + o
		return
	}
	if total, perr := strconv.ParseInt(tm[1], 10, 64); perr == nil && total >= a.listLimitN {
		a.occMsg = fmt.Sprintf("ERROR: gh issue list (occurrence lookup) returned %d results = the --limit %s cap for row @ROW@ — this cap now covers ALL open issues of the target:%s label (not one title search), so the result may be truncated; refusing to create or comment (raise STAGE_RETRO_ISSUES_LIST_LIMIT)", total, a.listLimit, a.targetName)
		return
	}
	a.occReply, a.occState = o, "ok"
}

// jsonEscape is _json_str_escape: the body of a strict-JSON string literal. It escapes \ and " and every control
// byte 0x01-0x1f (\n \r \t \b \f short, the rest \u00XX); bytes >= 0x80 pass through unchanged.
func jsonEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\\':
			b.WriteString(`\\`)
		case c == '"':
			b.WriteString(`\"`)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c == '\b':
			b.WriteString(`\b`)
		case c == '\f':
			b.WriteString(`\f`)
		case c >= 1 && c <= 31:
			fmt.Fprintf(&b, `\u%04x`, c)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

var reEmptyArray = regexp.MustCompile(`^[[:space:]]*\[[[:space:]]*$`)

// occCacheAdd is _occ_cache_add: after a CONFIRMED create, the new issue joins the cached list so a later row of the
// same retro with the same exact title gets an occurrence comment instead of a duplicate create.
func (a *app) occCacheAdd(num, title string) {
	r := strings.TrimRight(a.occReply, cSpace)
	r = strings.TrimSuffix(r, "]")
	sep := ","
	if reEmptyArray.MatchString(r) {
		sep = ""
	}
	a.occReply = r + sep + `{"number":` + num + `,"state":"OPEN","title":"` + jsonEscape(title) + `"}]`
}

// occFind is _occ_find: occNums = the OPEN same-target issues whose title equals title exactly; false when the
// lookup could not be made (the typed ERROR is printed).
func (a *app) occFind(title, row string) bool {
	a.occNums = nil
	if a.occState == "" {
		a.occFetch()
	}
	if a.occState != "ok" {
		a.errf("%s\n", strings.ReplaceAll(a.occMsg, "@ROW@", row))
		return false
	}
	m, err := jsonIssueScan(scanOcc, title, a.occReply)
	if err != nil {
		a.errf("ERROR: gh issue list (occurrence lookup) reply could not be parsed for row %s\n", row)
		return false
	}
	first, _, _ := strings.Cut(trimNL(m), "\n")
	a.occNums = strings.Fields(first)
	return true
}

// occComment is _occ_comment: the guarded write for ONE issue. It sets the per-row flags (documented at the call
// site) and the per-issue counters; the caller emits the row's single mutation_outcome. Flags are only ever set.
func (a *app) occComment(n, row, marker, body string) {
	cm, rc := a.gh("issue", "view", n, "--repo", a.repo, "--json", "comments", "--jq", ".comments[].body")
	cm = stripCR(cm)
	if rc != 0 {
		a.errf("ERROR: gh issue view (occurrence comments) failed for row %s (#%s): %s\n", row, n, cm)
		a.occRowFailed = true
		return
	}
	if hasLine(cm, marker) { // idempotency: a retro comments ONCE per issue
		a.outf("occurrence-exists: #%s already carries this retro (row %s)\n", n, row)
		a.occPresent++
		return
	}
	co, corc := a.gh("issue", "comment", n, "--repo", a.repo, "--body", body)
	if corc != 0 {
		// a failed comment can still have been written (timeout after the write): look before counting a failure
		rb, rbrc := a.gh("issue", "view", n, "--repo", a.repo, "--json", "comments", "--jq", ".comments[].body")
		rb = stripCR(rb)
		if rbrc == 0 && hasLine(rb, marker) {
			a.errf("unknown-outcome: gh issue comment failed for row %s (#%s) but the marker is present on re-read: %s\n", row, n, co)
			a.occRowUnknownCounted, a.occRowUnknown = true, true
			return
		}
		a.errf("ERROR: gh issue comment failed for row %s (#%s): %s\n", row, n, co)
		if rbrc != 0 {
			a.occRowUnknown = true
		}
		a.occRowFailed = true
		return
	}
	cl := lastLine(co)
	if !regexp.MustCompile(`^https?://[^[:space:]]+/issues/` + regexp.QuoteMeta(n) + `#issuecomment-[0-9]+$`).MatchString(cl) {
		a.errf("unknown-outcome: gh issue comment exited 0 for row %s (#%s) but printed no comment URL (output: %s) — a write is not inferred from output text\n", row, n, co)
		a.occRowUnknownCounted, a.occRowUnknown = true, true
		return
	}
	rb, rbrc := a.gh("issue", "view", n, "--repo", a.repo, "--json", "comments", "--jq", ".comments[].body")
	rb = stripCR(rb)
	if rbrc != 0 {
		a.errf("unknown-outcome: gh issue comment returned %s for row %s (#%s) but the read-back failed (gh issue view exit %d): %s\n", cl, row, n, rbrc, rb)
		a.occRowUnknownCounted, a.occRowUnknown = true, true
		return
	}
	if !hasLine(rb, marker) {
		a.errf("unknown-outcome: gh issue comment on #%s returned a URL for row %s but the read-back lacks the occurrence marker '%s'\n", n, row, marker)
		a.occRowUnknownCounted, a.occRowUnknown = true, true
		return
	}
	a.outf("occurrence-commented: #%s (row %s)\n", n, row)
	a.occCommented++
	a.occRowConfirmed = true
}

func lastLine(s string) string {
	if i := strings.LastIndex(s, "\n"); i >= 0 {
		return s[i+1:]
	}
	return s
}

// occRowCommentAll is _occ_row_comment_all: comment on every issue in occNums and emit the row's ONE
// mutation_outcome. PRECEDENCE (the only place it is defined): unknown > confirmed > no_write.
//
//	unknown    any issue's write may have happened and is unproven (a write is never retried);
//	confirmed  no unknown, and at least one comment was confirmed by read-back: a write DID happen, so no_write
//	           would be false even when another issue of the row failed cleanly;
//	no_write   nothing was written (clean failures, or every issue already carried the marker).
//
// A clean failure still counts in failed= (exit 2) whatever the outcome. The row flags (set by occComment, reset
// per row): occRowConfirmed (>=1 comment confirmed by read-back), occRowFailed (>=1 issue ended in a failed
// lookup/view/comment: failed= +1 for the row), occRowUnknown (>=1 issue's write is unproven), and
// occRowUnknownCounted (the unproven write is also reported by an `unknown-outcome:` line: unknown-outcome= +1; a
// failed comment whose re-read ALSO failed is unknown but is counted in failed=, like a failed create).
func (a *app) occRowCommentAll(row, marker, body string) {
	a.occRowConfirmed, a.occRowFailed, a.occRowUnknown, a.occRowUnknownCounted = false, false, false, false
	for _, n := range a.occNums {
		a.occComment(n, row, marker, body)
	}
	if a.occRowFailed {
		a.failed++
	}
	if a.occRowUnknownCounted {
		a.summaryUnknown++
	}
	switch {
	case a.occRowUnknown:
		a.rowUnknown(row)
	case a.occRowConfirmed:
		a.rowConfirmed(row)
	default:
		a.rowNoWrite(row)
	}
}
