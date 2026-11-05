package show

import "strings"

// Group 1: the campaign queue of one focus: the age of last_iteration_ts, the row counts, last_audit,
// campaign_stop, campaign_bounds, the stall WARN and the HTML-comment state machine.

func s7Campaign() []s6Scenario {
	var scs []s6Scenario
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	none := "  campaign        : none (1 active focus, 0 with a queue)\n"
	tsLine := func(ts string) string { return "last_iteration_ts: " + ts }
	age := func(name, ts, want string, flags ...string) s6Scenario {
		return os6(name, none+"  last_iteration_ts: "+want, tsOnly(tsLine(ts)), nil, nil, flags...)
	}
	add(
		os6("c-no-queue-no-timestamp", none+"  last_iteration_ts: absent", tsOnly(), nil, nil),
		os6("c-no-queue-empty-timestamp-is-absent", none+"  last_iteration_ts: absent", tsOnly("last_iteration_ts:"), nil, nil),
		age("c-age-an-hour", "2025-12-31T23:00:00Z", "2025-12-31T23:00:00Z  (age: 60 min)"),
		age("c-age-now-is-zero", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z  (age: 0 min)"),
		age("c-age-seconds-truncate", "2025-12-31T23:58:31Z", "2025-12-31T23:58:31Z  (age: 1 min)"),
		age("c-age-ahead-by-seconds-is-zero", "2026-01-01T00:00:30Z", "2026-01-01T00:00:30Z  (age: 0 min)"),
		age("c-age-fraction", "2025-12-31T23:30:00.5Z", "2025-12-31T23:30:00.5Z  (age: 30 min)"),
		age("c-age-positive-offset", "2026-01-01T01:00:00+02:00", "2026-01-01T01:00:00+02:00  (age: 60 min)"),
		age("c-age-compact-offset", "2025-12-31T22:30:00-0100", "2025-12-31T22:30:00-0100  (age: 30 min)"),
		age("c-age-minutes-only", "2025-12-31T23:30Z", "2025-12-31T23:30Z  (age: 30 min)"),
		age("c-age-a-year-ago", "2025-01-01T00:00:00Z", "2025-01-01T00:00:00Z  (age: 525600 min)"),
		age("c-age-unparseable-is-unknown", "soon", "soon  (age: unknown min)"),
		age("c-age-impossible-date-is-unknown", "2026-02-30T00:00:00Z", "2026-02-30T00:00:00Z  (age: unknown min)"),
		age("c-age-future-is-unknown", "2026-01-01T02:00:00Z", "2026-01-01T02:00:00Z  (age: unknown min)"),
		os6("c-queue-only-first-token-of-the-timestamp", none+"  last_iteration_ts: 2025-12-31T23:00:00Z  (age: 60 min)", tsOnly("last_iteration_ts: 2025-12-31T23:00:00Z extra words"), nil, nil),
	)
	rows := queue(queueHdr, qrow("a", "focus", "pending"), qrow("b", "tier", "active"), qrow("c", "sub-topic", "done"), qrow("d", "focus", "bound-stopped"), qrow("e", "focus", "rejected"), qrow("f", "focus", "done"))
	add(
		cq("c-counts-every-state", "  campaign        : pending=1 active=1 done=2 bound-stopped=1 rejected=1\n  last_audit      : not yet audited", nil, rows),
		cq("c-queue-and-no-timestamp", "last_iteration_ts: absent", nil, queue(queueHdr, qrow("a", "focus", "done"))),
		cq("c-queue-with-timestamp", "last_iteration_ts: 2025-12-31T23:00:00Z  (age: 60 min)", []string{tsOld}, queue(queueHdr, qrow("a", "focus", "done"))),
		cq("c-unrecognised-kind-warns", "pending=1 active=0", nil, queue(queueHdr, qrow("a", "epic", "pending"))),
		cq("c-unrecognised-state-warns", "pending=0 active=0 done=0", nil, queue(queueHdr, qrow("a", "focus", "stuck"))),
		cq("c-state-is-case-sensitive", "pending=0 active=0 done=0", nil, queue(queueHdr, qrow("a", "focus", "Pending"))),
		cq("c-empty-table-warns", "pending=0 active=0 done=0 bound-stopped=0 rejected=0", nil, queue(queueHdr)),
		cq("c-section-without-a-table-warns", "pending=0 active=0 done=0", nil, queue("just prose")),
		cq("c-row-without-a-name-is-skipped", "pending=1 active=0", nil, queue(queueHdr, qrow("", "focus", "pending"), qrow("a", "focus", "pending"))),
		cq("c-short-row-has-an-empty-state", "pending=0 active=0 done=0", nil, queue(queueHdr, "| a | seed | focus |")),
		cq("c-row-without-a-trailing-pipe", "pending=1 active=0", nil, queue(queueHdr, "| a | seed | focus | conv | 1 | pending")),
		cq("c-extra-columns-are-ignored", "pending=1 active=0", nil, queue(queueHdr, "| a | seed | focus | conv | 1 | pending | note | more |")),
		cq("c-indented-row-is-not-a-row", "pending=0 active=0 done=0", nil, queue(queueHdr, "  "+qrow("a", "focus", "pending"))),
		cq("c-cells-are-space-trimmed-only", "pending=0 active=0 done=0", nil, queue(queueHdr, "|\ta\t|\tseed\t|\tfocus\t|\tc\t|\t1\t|\tpending\t|")),
		cq("c-crlf-section", "pending=1 active=0 done=0 bound-stopped=0 rejected=0", nil, strings.ReplaceAll(queue(queueHdr, qrow("a", "focus", "pending")), "\n", "\r\n")),
		cq("c-section-ends-at-the-next-heading", "pending=1 active=0", nil, queue(queueHdr, qrow("a", "focus", "pending"))+"\n## Other\n\n"+qrow("z", "focus", "done")+"\n"),
		cq("c-heading-must-start-the-line", "campaign        : none", nil, " ## Campaign queue\n"+qrow("a", "focus", "pending")+"\n"),
		cq("c-heading-with-a-suffix-counts", "pending=1 active=0", nil, "\n## Campaign queue (scaffold)\n\n"+queueHdr+qrow("a", "focus", "pending")+"\n"),
	)
	audit := func(name, want string, lines ...string) s6Scenario {
		return cq(name, want, nil, queue(append([]string{queueHdr, qrow("a", "focus", "done")}, lines...)...))
	}
	add(
		audit("c-last-audit-shown", "  last_audit      : enqueued=3 partition=\"x\"", "last_audit: enqueued=3 partition=\"x\""),
		audit("c-last-audit-blanks-after-the-colon", "  last_audit      : enqueued=3", "last_audit:    enqueued=3"),
		audit("c-last-audit-first-line-wins", "  last_audit      : first", "last_audit: first", "last_audit: second"),
		audit("c-last-audit-empty-is-not-yet-audited", "  last_audit      : not yet audited", "last_audit:"),
		audit("c-stop-field-wins", "  campaign_stop   : bound reached", "campaign_stop: bound reached", "last_audit: enqueued=0"),
		audit("c-stop-computed", "  campaign_stop   : STOP reached — all entries terminal, last_audit enqueued=0", "last_audit: enqueued=0"),
		audit("c-stop-computed-keeps-the-partition", "campaign_stop   : STOP reached", "last_audit: enqueued=0 partition=\"all\""),
		audit("c-stop-needs-enqueued-zero", "  last_audit      : enqueued=2\n  last_iteration_ts: absent", "last_audit: enqueued=2"),
		audit("c-stop-leading-zero-is-not-zero", "  last_audit      : enqueued=00\n  last_iteration_ts: absent", "last_audit: enqueued=00"),
		audit("c-stop-two-enqueued-tokens-are-not-zero", "  last_audit      : enqueued=0 enqueued=0\n  last_iteration_ts: absent", "last_audit: enqueued=0 enqueued=0"),
		audit("c-stop-needs-a-last-audit", "  last_audit      : not yet audited\n  last_iteration_ts: absent"),
		os6("c-stop-not-while-pending", "  last_audit      : enqueued=0\n  last_iteration_ts: absent", withQueue(nil, queue(queueHdr, qrow("a", "focus", "pending"), "last_audit: enqueued=0")), nil, nil),
		os6("c-stop-not-while-active", "  last_audit      : enqueued=0\n  last_iteration_ts: absent", withQueue(nil, queue(queueHdr, qrow("a", "focus", "active"), "last_audit: enqueued=0")), nil, nil),
		audit("c-stop-field-blank-falls-back", "campaign_stop   : STOP reached", "campaign_stop:", "last_audit: enqueued=0"),
	)
	bounds := func(name, want, b string) s6Scenario {
		return audit(name, want, "campaign_bounds: "+b)
	}
	add(
		bounds("c-bounds-valid", "  campaign_bounds : max-depth=3 iterations=10 wall-clock=1.5h", "max-depth=3 iterations=10 wall-clock=1.5h"),
		bounds("c-bounds-bad-depth", "campaign_bounds : max-depth=x", "max-depth=x"),
		bounds("c-bounds-bad-iterations", "campaign_bounds : iterations=", "iterations="),
		bounds("c-bounds-bad-wall-clock", "campaign_bounds : wall-clock=5", "wall-clock=5"),
		bounds("c-bounds-wall-clock-fraction-needs-digits", "campaign_bounds : wall-clock=1.h", "wall-clock=1.h"),
		bounds("c-bounds-unknown-key", "campaign_bounds : colour=red", "colour=red"),
		bounds("c-bounds-token-without-equals", "campaign_bounds : bare", "bare"),
		bounds("c-bounds-empty-key", "campaign_bounds : =5", "=5"),
		bounds("c-bounds-value-keeps-later-equals", "campaign_bounds : max-depth=1=2", "max-depth=1=2"),
		bounds("c-bounds-repeated-blanks", "campaign_bounds : max-depth=1   iterations=2", "max-depth=1   iterations=2"),
		bounds("c-bounds-tab-joins-tokens", "campaign_bounds : max-depth=1\titerations=2", "max-depth=1\titerations=2"),
	)
	stall := func(name, want string, state string, flags ...string) s6Scenario {
		return os6(name, want, withQueue([]string{tsOld}, state), nil, nil, flags...)
	}
	add(
		stall("c-stall-pending-over-the-default", "(age: 60 min)", queue(queueHdr, qrow("a", "focus", "pending"))),
		stall("c-stall-active-over-the-default", "(age: 60 min)", queue(queueHdr, qrow("a", "focus", "active"))),
		stall("c-stall-at-the-threshold-is-quiet", "(age: 60 min)", queue(queueHdr, qrow("a", "focus", "pending")), "--stall-minutes", "60"),
		stall("c-stall-one-past-the-threshold", "(age: 60 min)", queue(queueHdr, qrow("a", "focus", "pending")), "--stall-minutes", "59"),
		stall("c-stall-flag-raises-the-threshold", "(age: 60 min)", queue(queueHdr, qrow("a", "focus", "pending")), "--stall-minutes", "120"),
		stall("c-stall-terminal-queue-is-quiet", "(age: 60 min)", queue(queueHdr, qrow("a", "focus", "done"), qrow("b", "focus", "rejected"))),
		os6("c-stall-unknown-age-is-quiet", "(age: unknown min)", withQueue([]string{"last_iteration_ts: not-a-date"}, queue(queueHdr, qrow("a", "focus", "pending"))), nil, nil),
	)
	return append(scs, s7Comments()...)
}
