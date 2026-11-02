package stageissues

import (
	"fmt"
	"slices"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/retro/grammar"
)

func sprintf(format string, args ...any) string { return fmt.Sprintf(format, args...) }

// bareTokens are the priority/type words a delta title can never be (a mis-read column, issue #1248 was titled
// `LOW`). It mirrors the vocabulary mapPriority/mapType recognise, exact match only.
var bareTokens = []string{"high", "medium", "low", "feature", "bug", "fix", "bugfix", "defect", "regression", "doc", "docs", "documentation", "doc-fix", "docfix"}

// titleUnusable is title_is_unusable: a bare priority/type token (any length) or a title under 12 CHARACTERS (kit
// issue #1260 / #1492). The token check runs FIRST and is independent of the length floor (#1519). The length is
// counted in characters whatever the caller's locale; the grammar's TitleHasIdentity owns that rule (UTF-8 as glibc
// iconv judges it, bytes otherwise). reason names the clause that fired.
func titleUnusable(title string) (unusable bool, reason string) {
	t := trimSpace(title)
	if slices.Contains(bareTokens, lowerASCII(t)) {
		return true, "a bare priority/type token"
	}
	if !grammar.TitleHasIdentity(t) {
		return true, "a title under 12 characters"
	}
	return false, ""
}

// stageRow handles one delta record: skips, guards, scrub, then the dry-run plan or the --apply writes.
func (a *app) stageRow(r grammar.Row) {
	rid, delta := trimSpace(r.ID), trimSpace(r.Change)
	targetCell, evidence := trimSpace(r.Target), trimSpace(r.Evidence)
	typeCell, priorityCell := trimSpace(r.Type), trimSpace(r.Priority)
	if rid == "" {
		return
	}
	cut60 := func() string { return a.cutChars(delta, 60) }

	// An id holding a pipe (after unescape) cannot round-trip through the `Source retro: … · <id>` signature that
	// reconcile reads back, so it is typed unclassifiable, never staged (kit issue #2118).
	if strings.Contains(rid, "|") {
		a.errf("unclassifiable-row: row %s has a pipe in its id (id-contains-pipe) — needs manual review, no issue staged\n", rid)
		a.unclassifiable++
		a.uncAdd(false, a.uncRowLine(rid, delta), rid+": "+cut60(), "id-contains-pipe")
		return
	}
	// Any other character outside [A-Za-z0-9_-] (a backslash left by a `6\ |` cell, a dot, markup) cannot
	// round-trip either: unclassifiable, never staged (kit issue #2135).
	if !grammar.IDSignatureSafe(rid) {
		a.errf("unclassifiable-row: row %s has a character outside [A-Za-z0-9_-] in its id (id-not-signature-safe) — needs manual review, no issue staged\n", rid)
		a.unclassifiable++
		a.uncAdd(false, a.uncRowLine(rid, delta), rid+": "+cut60(), "id-not-signature-safe")
		return
	}

	// Skip shipped rows for PARTIAL applied retros; all rows open otherwise (fully applied/dismissed without
	// PARTIAL already ended the run).
	if a.isPartial {
		if slices.Contains(a.shipped, rid) {
			a.skippedShipped++
			return
		}
		// Kit issue #1944: a row the marker resolves as DISMISSED (rejected, not shipped) is closed too: never seeded.
		switch grammar.MarkerRowState(a.markerLine, rid) {
		case grammar.RowDismissed:
			a.errf("no-match: dismissed (row %s)\n", rid)
			a.skippedShipped++
			a.skippedDismissed++
			return
		case grammar.RowMalformed: // never seeded, never dropped silently
			a.errf("unclassifiable-row: row %s cannot be told shipped, dismissed or open — the review-status marker carries a DISMISSED: list with no usable id — needs manual review, no issue staged\n", rid)
			a.unclassifiable++
			a.uncAdd(false, a.uncRowLine(rid, delta), rid+": "+cut60(), "marker DISMISSED: list is malformed (empty or only a parenthetical)")
			return
		}
	}

	// Wrong-kit check: skip rows targeting a different kit
	if isWrongKit(targetCell) {
		a.errf("skipped-wrong-kit: row %s targets another kit ('%s') — skipping\n", rid, targetCell)
		a.skippedWrongKit++
		return
	}
	a.open++

	// The title is scrubbed BEFORE it is truncated, so a cut can never leave a half-redacted email or path in the
	// public title (kit issue #1707).
	titleRaw := stripMDBold(delta)
	title, titleN := scrubText(titleRaw)
	if a.charLen(title) > 120 {
		title = a.cutChars(title, 117) + "..."
	}
	// A bare priority/type token is a mis-read column, never a real delta summary. Not created, not silently
	// dropped: typed `unclassifiable-row:` line + summary count, exit 0.
	if bad, why := titleUnusable(title); bad {
		a.errf("unclassifiable-row: row %s has no usable title (got '%s': %s) — needs manual review, no issue staged\n", rid, title, why)
		a.open--
		a.unclassifiable++
		a.uncAdd(false, a.uncRowLine(rid, delta), rid+": "+titleRaw, "no usable title ("+why+")")
		return
	}

	typeLabel, priorityLabel := mapType(typeCell), mapPriority(priorityCell)
	sourceLine := "Source retro: " + a.targetName + "/retros/" + a.retroBase + " · " + rid
	body := sprintf("%s\n\n**Target:** %s\n**Evidence:** %s\n\n---\n%s\n%s", delta, targetCell, evidence, sourceLine, "Part of backlog-first rollout #557")
	// Scrub the whole body before ANY gh call, count what was redacted (title + body), and refuse the row when the
	// scrub altered the signature line: dedup and the read-back both key on it. The count is "how many replacements
	// the scrub performed on what would be written", not "distinct secrets": a datum in both fields counts twice.
	body, bodyN := scrubText(body)
	redactions := titleN + bodyN
	if !hasLine(body, sourceLine) {
		a.scrubRefuse(rid, "scrub altered the signature line for row "+rid+" — refusing to write (dedup and read-back key on it)")
		return
	}

	labels := "status:needs-review,target:" + a.targetName + ",type:" + typeLabel
	if priorityLabel != "" {
		labels += ",priority:" + priorityLabel
	}
	if !a.apply {
		a.outf("planned-issue: %s\n", title)
		a.outf("  labels: %s\n", labels)
		a.outf("  body:\n")
		a.outf("%s\n", indent4(body))
		a.outf("  redactions: %d\n", redactions)
		a.outf("\n")
		return
	}
	a.outf("redactions: %d (row %s)\n", redactions, rid)
	a.applyRow(rid, title, labels, body, sourceLine)
}

// applyRow is the --apply half of one row: dedup (exact signature, all states, then the legacy signature), the
// occurrence comment, and the create.
func (a *app) applyRow(rid, title, labels, body, sourceLine string) {
	// Dedup: search ALL states (open + closed) for the exact source signature (kit issue #949 item 2). A closed
	// issue for this row must still suppress a re-create. --json state,body lets one gh call classify a match's
	// state, and the body is checked for the exact signature line because GitHub's search is a fuzzy WORD match.
	scan, ok := a.dedupLookup("dedup", rid, sourceLine)
	if !ok {
		return
	}
	pageFilled := ""
	if a.listFilled(scan) {
		pageFilled = "primary"
	}
	if reStateOpen.MatchString(scan) {
		a.outf("skipped-duplicate: issue for row %s already exists (open; search matched '%s')\n", rid, sourceLine)
		a.skippedDedup++
		a.rowNoWrite(rid)
		return
	}
	if reStateClosed.MatchString(scan) {
		a.outf("skipped-duplicate: issue for row %s already exists (closed; search matched '%s')\n", rid, sourceLine)
		a.skippedDedup++
		a.rowNoWrite(rid)
		return
	}
	// Issues created before #1286 carry the legacy `<path basename>/retros/<file>` signature. When the registered
	// name differs from the basename, search that signature too (all states, same failure guards) so a re-marked
	// pending retro cannot duplicate (kit issue #1287 item 2). Skipped when they are equal: no extra gh traffic.
	if a.legacyTargetName != a.targetName {
		legacySig := "Source retro: " + a.legacyTargetName + "/retros/" + a.retroBase + " · " + rid
		lscan, ok := a.dedupLookup("legacy-signature dedup", rid, legacySig)
		if !ok {
			return
		}
		if a.listFilled(lscan) {
			pageFilled = "legacy-signature"
		}
		if reStateOpen.MatchString(lscan) {
			a.outf("skipped-duplicate: issue for row %s already exists (open; legacy signature matched '%s')\n", rid, legacySig)
			a.skippedDedup++
			a.rowNoWrite(rid)
			return
		}
		if reStateClosed.MatchString(lscan) {
			a.outf("skipped-duplicate: issue for row %s already exists (closed; legacy signature matched '%s')\n", rid, legacySig)
			a.skippedDedup++
			a.rowNoWrite(rid)
			return
		}
	}
	// No exact match, but a lookup filled its --limit, so the match may have been cut off. Not "no match": a typed
	// failure, nothing created (kit issue #1369 c).
	if pageFilled != "" {
		a.errf("ERROR: gh issue list (dedup) returned %s results = the --limit %s cap for row %s (%s lookup) — the result may be truncated, refusing to create (raise STAGE_RETRO_ISSUES_LIST_LIMIT or narrow the repo)\n", a.listLimit, a.listLimit, rid, pageFilled)
		a.failed++
		a.rowNoWrite(rid)
		return
	}

	// Occurrence (kit issue #1708): the exact signature is NOT tracked, but the same delta may be (an OPEN same-target
	// issue with this exact title, filed from an earlier retro): comment there, never duplicate.
	if !a.occFind(title, rid) {
		a.failed++
		a.rowNoWrite(rid)
		return
	}
	if len(a.occNums) > 0 {
		marker := "<!-- stage-retro-issues:occurrence " + sourceLine + " -->"
		text, _ := scrubText("Another retro carries this exact delta.\n\n" + sourceLine + "\n" + marker)
		if !hasLine(text, marker) {
			a.scrubRefuse(rid, "scrub altered the occurrence marker for row "+rid+" — refusing to write (idempotency and the read-back key on it)")
			return
		}
		// ONE mutation_outcome per ROW (kit issue #1705 contract: mutation-summary counts rows), however many issues matched.
		a.occRowCommentAll(rid, marker, text)
		return
	}

	a.ensureTargetLabel() // once, before the first create
	a.createIssue(rid, title, labels, body, sourceLine, sourceLine, false)
}

// dedupLookup is one `gh issue list --state all --search "<sig>"` and its guards, shared by the primary and the
// legacy-signature lookups (kit issues #949 item 2, #1093 item 1, #1304 item 1): a failed call (network, rate
// limit) must NOT fall through to create (that risks the duplicate the check exists to prevent), an empty reply with
// exit 0 is not a no-match, and a reply that cannot be parsed is a failure. kind names the lookup in the messages.
// scan is the exact-signature reading of the reply (see exactSigMatches).
func (a *app) dedupLookup(kind, rid, sig string) (scan string, ok bool) {
	raw, rc := a.gh("issue", "list", "--repo", a.repo, "--state", "all", "--limit", a.listLimit, "--search", `"`+sig+`"`, "--json", "state,body")
	if rc != 0 {
		a.errf("ERROR: gh issue list (%s) failed for row %s: %s\n", kind, rid, raw)
		a.failed++
		a.rowNoWrite(rid)
		return "", false
	}
	if !startsArray(raw) {
		a.errf("ERROR: gh issue list (%s) returned an unexpected reply for row %s (expected a JSON array): %s\n", kind, rid, raw)
		a.failed++
		a.rowNoWrite(rid)
		return "", false
	}
	scan, err := exactSigMatches(sig, raw)
	if err != nil {
		a.errf("ERROR: gh issue list (%s) reply could not be parsed for row %s: %s\n", kind, rid, raw)
		a.failed++
		a.rowNoWrite(rid)
		return "", false
	}
	return scan, true
}
