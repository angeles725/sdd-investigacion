package stageissues

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var (
	reLeadWS        = regexp.MustCompile(`^[[:space:]]*\|[[:space:]]*`)
	reFirstCellTail = regexp.MustCompile(`[[:space:]]*\|.*$`)
)

// The UNCLASSIFIABLE collector (kit issue #1259). Everything the parser cannot classify (a whole retro section, or
// one row with no usable title) is recorded instead of only counted or warned on stderr, printed as a table on
// stdout and proposed as ONE tracking issue per run (uncReport). A record is (where, head, reason).

type uncRec struct{ where, head, reason string }

// uncLineOf is _unc_line_of: the first line number of the fixed string in the retro, "?" when absent or empty.
func (a *app) uncLineOf(needle string) string {
	if needle != "" {
		for i, l := range a.doc.Raw {
			if strings.Contains(l, needle) {
				return strconv.Itoa(i + 1)
			}
		}
	}
	return "?"
}

// uncRowLine is _unc_row_line: the line of the table row whose FIRST cell is rid and that contains the delta cell,
// searched only in lines that start with `|` (never prose, never another section). "?" when there is no such row
// or more than one (a wrong line number is worse than none).
func (a *app) uncRowLine(rid, delta string) string {
	if rid == "" || delta == "" {
		return "?"
	}
	n, first := 0, 0
	for i, l := range a.doc.Raw {
		if !strings.HasPrefix(strings.TrimLeft(l, cSpace), "|") {
			continue
		}
		// cut the first cell on UNESCAPED pipes only, and match the delta against the unescaped text, exactly as
		// the row parser does (kit issue #2118)
		c := escPipes(l)
		c = reLeadWS.ReplaceAllString(c, "")
		c = reFirstCellTail.ReplaceAllString(c, "")
		c = strings.ReplaceAll(c, sent, "|")
		u := strings.ReplaceAll(escPipes(l), sent, "|")
		if c == rid && strings.Contains(u, delta) {
			n++
			if n == 1 {
				first = i + 1
			}
		}
	}
	if n == 1 {
		return strconv.Itoa(first)
	}
	return "?"
}

// uncAdd is _unc_add: head is flattened to one line, `|` escaped (it lands in a markdown table) and cut at 100
// characters (counted in characters under a UTF-8 locale, bytes otherwise, as bash's ${#h} does).
func (a *app) uncAdd(section bool, where, head, reason string) {
	h := strings.Map(func(r rune) rune {
		if r == '\r' || r == '\n' || r == '\t' {
			return ' '
		}
		return r
	}, head)
	h = strings.ReplaceAll(h, "|", `\|`)
	h = strings.TrimLeft(h, " ")
	h = strings.TrimRight(h, " ")
	if a.charLen(h) > 100 {
		h = a.cutChars(h, 97) + "..."
	}
	a.uncN++
	if section {
		a.uncSec++
	}
	a.uncRecs = append(a.uncRecs, uncRec{where, h, reason})
}

// uncReport is _unc_report: the `unclassifiable-items: N (...)` count line (zeroState names WHY a 0 is a 0), then
// for N > 0 the table, and ONE tracking issue per run (dry-run: planned-tracking-issue; --apply: the same create /
// dedup / occurrence-comment / read-back machinery as a delta row, row id `tracker`).
func (a *app) uncReport(zeroState string) {
	if a.uncN == 0 {
		a.outf("unclassifiable-items: 0 (%s)\n", zeroState)
		return
	}
	a.outf("unclassifiable-items: %d (retro-level=%d row-level=%d)\n", a.uncN, a.uncSec, a.uncN-a.uncSec)
	table := "| # | where | head | reason |\n|---|---|---|---|"
	for i, r := range a.uncRecs {
		table += fmt.Sprintf("\n| %d | %s:%s | %s | %s |", i+1, a.retroBase, r.where, r.head, r.reason)
	}
	fp := strconv.FormatUint(uint64(cksum(a.fingerprintInput())), 10)
	sig := "Unclassifiable tracker: " + a.targetName + "/retros/" + a.retroBase
	sigfp := "Unclassifiable item set: " + fp
	title := "Unclassifiable retro deltas in " + a.targetName + "/retros/" + a.retroBase
	body := fmt.Sprintf("stage-retro-issues.sh could not classify %d item(s) in this retro, so no delta issue was staged for them (they would otherwise be lost). Each needs manual review: restate it in the canonical row-table or `### D<N> —` entry form, or dismiss it.\n\n%s\n\n---\n%s\n%s\nPart of backlog-first rollout #557", a.uncN, table, sig, sigfp)
	// Scrub first (kit issue #1707), exactly like a delta row: stdout, the dry-run and every gh call see the scrubbed text.
	title, red := scrubText(title)
	body, tn := scrubText(body)
	red += tn
	if !hasLine(body, sig) || !hasLine(body, sigfp) {
		a.scrubRefuse("tracker", "scrub altered the signature line of the unclassifiable tracker — refusing to write (dedup and read-back key on it)")
		return
	}
	// The table the operator reads is the SCRUBBED one (it is what would be published).
	a.outf("%s\n", sedTable(body))
	labels := "status:needs-review,target:" + a.targetName + ",type:docs,priority:medium"
	if !a.apply {
		a.outf("planned-tracking-issue: %s\n", title)
		a.outf("  labels: %s\n", labels)
		a.outf("  body:\n")
		a.outf("%s\n", indent4(body))
		a.outf("  redactions: %d\n\n", red)
		return
	}
	a.outf("redactions: %d (row tracker)\n", red)
	marker := "<!-- stage-retro-issues:occurrence " + sig + " #" + fp + " -->"
	// Lookup order (kit issue #1259 RDD rounds 1-2). Trackers are found by the BODY signature line, never by title,
	// so a title suffix can never hide an open tracker (that fan-out would open a new issue per changed set):
	//   1. the exact item-set line in ANY state          -> skipped-duplicate (this set is already tracked)
	//   2. one OPEN tracker for this retro (any suffix)   -> ONE occurrence comment on it, keyed by the set checksum
	//   3. several OPEN trackers                          -> typed WARN naming them, comment on the newest, create nothing
	//   4. only CLOSED trackers (a closed one dismissed only the set it listed) -> ONE new tracker, title suffixed
	//   5. no tracker at all                              -> create (base title)
	lk, ok := a.uncLookup(scanSig, sigfp)
	if !ok {
		return
	}
	if reStateAny.MatchString(lk) {
		a.outf("skipped-duplicate: tracking issue for %s already exists for this item set (search matched '%s')\n", sig, sigfp)
		a.skippedDedup++
		a.rowNoWrite("tracker")
		return
	}
	lk, ok = a.uncLookup(scanSigs, sig)
	if !ok {
		return
	}
	var openNums []int
	closedAny := false
	for _, l := range strings.Split(lk, "\n") {
		if n, st, found := strings.Cut(l, " "); found && isDigits(n) {
			switch st {
			case "OPEN":
				v, _ := strconv.Atoi(n)
				openNums = append(openNums, v)
			case "CLOSED":
				closedAny = true
			}
		}
	}
	if len(openNums) > 0 {
		sortInts(openNums)
		newest := strconv.Itoa(openNums[len(openNums)-1])
		if len(openNums) > 1 {
			var sb strings.Builder
			for _, n := range openNums {
				sb.WriteString("#" + strconv.Itoa(n) + " ")
			}
			a.errf("WARN: tracker-multiple-open: %s has several OPEN trackers (%s) — commenting on the newest (#%s), creating nothing; close the extras\n", sig, sb.String(), newest)
		}
		stable := trimNL(sedTable(body)) // the already-scrubbed table
		text, _ := scrubText(fmt.Sprintf("The unclassifiable item set of this retro changed (%d item(s)):\n\n%s\n\n%s\n%s\n%s", a.uncN, stable, sig, sigfp, marker))
		if !hasLine(text, marker) {
			a.scrubRefuse("tracker", "scrub altered the occurrence marker of the unclassifiable tracker — refusing to write (idempotency and the read-back key on it)")
			return
		}
		a.occNums = []string{newest}
		a.occRowCommentAll("tracker", marker, text)
		return
	}
	if closedAny {
		title += " (item set " + fp + ")"
		a.outf("tracker-set-changed: every earlier tracker for %s is closed and lists a different item set — creating a new tracker\n", sig)
	}
	// NOTE (kit issue #1259 R2-001, deferred): the create + read-back below duplicates the delta-row create path.
	a.ensureTargetLabel()
	a.createIssue("tracker", title, labels, body, sig, sigfp, true)
}

func sortInts(v []int) {
	for i := 1; i < len(v); i++ {
		for j := i; j > 0 && v[j] < v[j-1]; j-- {
			v[j], v[j-1] = v[j-1], v[j]
		}
	}
}

// fingerprintInput is the `awk -F'\037' 'NF { print $2 "\037" $3 }'` stream cksum reads: each record's head and
// reason, one line each.
func (a *app) fingerprintInput() []byte {
	var b strings.Builder
	for _, r := range a.uncRecs {
		b.WriteString(r.head + "\x1f" + r.reason + "\n")
	}
	return []byte(b.String())
}

// sedTable is `sed -n '/^| # | where/,/^$/p'`: from the table header line through the first empty line.
func sedTable(body string) string {
	var out []string
	in := false
	for _, l := range strings.Split(body, "\n") {
		if !in && strings.HasPrefix(l, "| # | where") {
			in = true
			out = append(out, l)
			continue
		}
		if in {
			out = append(out, l)
			if l == "" {
				break
			}
		}
	}
	return strings.Join(out, "\n")
}

// indent4 is `sed 's/^/    /'` over printf '%s\n' text.
func indent4(text string) string {
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		lines[i] = "    " + l
	}
	return strings.Join(lines, "\n")
}

// uncLookup is _unc_lookup: search ALL states for issues whose body carries needle as a whole line. Mode scanSig
// answers `[{"state":..}]` (is there a hit?), mode scanSigs also the number (which issues?). One helper, so the gh
// error / bad-reply / parse / --limit-truncation handling cannot drift between the two lookups. ok is false when
// the lookup could not be made (typed ERROR printed, failed counted): never "no match".
func (a *app) uncLookup(mode scanMode, needle string) (string, bool) {
	fields, hit := "state,body", `"state":`
	if mode == scanSigs {
		fields = "number,state,body"
	}
	x, rc := a.gh("issue", "list", "--repo", a.repo, "--state", "all", "--limit", a.listLimit, "--search", `"`+needle+`"`, "--json", fields)
	if rc != 0 || !startsArray(x) {
		a.errf("ERROR: gh issue list (tracker lookup) failed or returned an unexpected reply for row tracker: %s\n", x)
		a.failed++
		a.rowNoWrite("tracker")
		return "", false
	}
	lk, err := jsonIssueScan(mode, needle, x)
	if err != nil {
		a.errf("ERROR: gh issue list (tracker lookup) reply could not be parsed for row tracker: %s\n", x)
		a.failed++
		a.rowNoWrite("tracker")
		return "", false
	}
	lk = trimNL(lk)
	found := false
	if mode == scanSigs {
		for _, l := range strings.Split(lk, "\n") {
			if n, _, ok := strings.Cut(l, " "); ok && isDigits(n) {
				found = true
			}
		}
	} else {
		found = strings.Contains(lk, hit)
	}
	if !found && a.listFilled(lk) {
		a.errf("ERROR: gh issue list (tracker lookup) returned %s results = the --limit cap for row tracker — the result may be truncated, refusing to create (raise STAGE_RETRO_ISSUES_LIST_LIMIT)\n", a.listLimit)
		a.failed++
		a.rowNoWrite("tracker")
		return "", false
	}
	return lk, true
}
