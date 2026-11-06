package show

// Group 2: the HTML-comment state machine of the section readers, and group 3: several focuses (labels, the
// aggregate STOP, FOCUSES.md skips, --focus and --root).

func s7Comments() []s6Scenario {
	var scs []s6Scenario
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	row1 := qrow("a", "focus", "pending")
	tbl := queueHdr + row1
	none := "campaign        : none"
	add(
		cq("m-template-comment-hides-the-section", none, nil, "\n<!--\n## Campaign queue\n\n"+tbl+"\n-->\n"),
		cq("m-comment-then-a-real-section", "pending=1 active=0", nil, "\n<!--\n## Campaign queue\n-->\n\n## Campaign queue\n\n"+tbl+"\n"),
		cq("m-one-line-comment-opens-nothing", "pending=1 active=0", nil, "\n<!-- a -> b -->\n"+queue(tbl)),
		cq("m-comment-closes-with-trailing-text", "pending=1 active=0", nil, "\n<!-- review-status: pending\nnote\n--> see note\n"+queue(tbl)),
		cq("m-close-marker-anywhere-in-the-line", "pending=1 active=0", nil, "\n<!--\nline --> (end)\n"+queue(tbl)),
		cq("m-comment-inside-the-section-hides-its-rows", "pending=1 active=0", nil, queue(queueHdr, "<!--", qrow("hidden", "focus", "done"), "-->", row1)),
		cq("m-indented-comment-opener-counts", "pending=1 active=0", nil, queue(queueHdr, "   <!-- note", qrow("hidden", "focus", "done"), "   -->", row1)),
		cq("m-marker-inside-a-row-is-not-a-comment", "pending=1 active=0 done=1", nil, queue(queueHdr, "| <!-- | seed | focus | c | 1 | pending |", "| x --> | seed | focus | c | 1 | done |")),
		cq("m-unclosed-comment-warns", "pending=1 active=0", nil, queue(tbl)+"\n<!-- never closed\nlast_audit: hidden\n"),
		cq("m-unclosed-comment-before-the-section-hides-it", none, nil, "<!-- open\n"+queue(tbl)),
		cq("m-unclosed-comment-warns-once-per-focus-read", "pending=1 active=0", nil, queue(tbl, "<!-- open")),
	)
	return scs
}

func s7Multi() []s6Scenario {
	var scs []s6Scenario
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	focus := func(done bool, env ...string) string { // a state file with a queue, terminal or not
		st := "pending"
		if done {
			st = "done"
		}
		return withQueue(env, queue(queueHdr, qrow("a", "focus", st), "last_audit: enqueued=0"))
	}
	bare := tsOnly()
	ws := func(name, want string, f files, flags ...string) { add(ws6(name, want, f, nil, flags...)) }
	ws("g-two-queues-are-labelled", "  campaign[act]   : pending=0 active=0 done=1", twoFocus(focus(false), focus(true), nil))
	ws("g-two-queues-label-the-root-too", "  campaign[RESEARCH-STATE]", twoFocus(focus(false), focus(true), nil))
	ws("g-all-terminal-aggregate-stop", "  campaign_stop   : STOP reached — all 2 queue-bearing focuses terminal", twoFocus(focus(true), focus(true), nil))
	ws("g-one-live-focus-blocks-the-aggregate-stop", "campaign_stop[act]", twoFocus(focus(false), focus(true), nil))
	ws("g-explicit-stop-fields-count-for-the-aggregate", "all 2 queue-bearing focuses terminal", twoFocus(
		withQueue(nil, queue(queueHdr, qrow("a", "focus", "pending"), "campaign_stop: bound")),
		withQueue(nil, queue(queueHdr, qrow("a", "focus", "pending"), "campaign_stop: bound")), nil))
	ws("g-a-focus-without-a-queue-is-silent", "  campaign        : pending=0 active=0 done=1", twoFocus(focus(true), bare, nil))
	ws("g-no-label-when-only-one-focus-has-a-queue", "  last_audit      : enqueued=0", twoFocus(focus(true), bare, nil))
	ws("g-single-queue-never-prints-the-aggregate-stop", "campaign_stop   : STOP reached — all entries terminal", twoFocus(focus(true), bare, nil))
	ws("g-no-queue-anywhere-is-one-line", "  campaign        : none (2 active focuses, 0 with a queue)", twoFocus(bare, bare, nil))
	ws("g-no-queue-anywhere-has-no-timestamp-line", "none (2 active focuses, 0 with a queue)\n  next step", twoFocus(bare, bare, nil))
	stopped := func(status string) files { return files{"corpus/FOCUSES.md": focusRows("act", status)} }
	ws("g-stopped-focus-is-skipped", "  campaign        : none (1 active focus, 0 with a queue)", twoFocus(bare, focus(false), stopped("stopped")))
	ws("g-paused-focus-is-skipped", "none (1 active focus, 0 with a queue)", twoFocus(bare, focus(false), stopped("paused")))
	ws("g-open-focus-is-not-skipped", "campaign[act]", twoFocus(focus(false), focus(false), stopped("open")))
	ws("g-skipped-focus-queue-does-not-block-the-stop", "campaign_stop   : STOP reached — all entries terminal", twoFocus(focus(true), focus(false), stopped("stopped")))
	both := files{"corpus/FOCUSES.md": focusRows("act", "stopped", "RESEARCH-STATE", "paused")}
	ws("g-every-focus-skipped", "  campaign        : no active focus (2 declared stopped/paused in FOCUSES.md)", twoFocus(focus(false), focus(false), both))
	ws("g-focus-flag-reports-only-that-focus", "  campaign        : pending=0 active=0 done=1", twoFocus(focus(false), focus(true), nil), "--focus", "act")
	ws("g-focus-flag-never-labels", "last_audit      : enqueued=0", twoFocus(focus(false), focus(true), nil), "--focus", "act")
	ws("g-focus-flag-does-not-skip-a-stopped-focus", "  campaign        : pending=0 active=0 done=1", twoFocus(bare, focus(true), stopped("stopped")), "--focus", "act")
	ws("g-focus-flag-without-a-queue", "  campaign        : none (1 active focus, 0 with a queue)", twoFocus(focus(true), bare, nil), "--focus", "act")
	ws("g-focus-flag-timestamp-is-that-focus", "(age: 60 min)", twoFocus(bare, tsOnly(tsOld), nil), "--focus", "act")
	ws("g-root-flag-lists-every-focus", "campaign[act]", twoFocus(focus(false), focus(false), nil), "--root")
	ws("g-queue-timestamps-are-per-focus", "last_iteration_ts[act]: 2025-12-31T23:00:00Z  (age: 60 min)", twoFocus(focus(false), focus(false, tsOld), nil))
	ws("g-stall-warn-names-the-focus", "last_iteration_ts[act]", twoFocus(focus(true), focus(false, tsOld), nil))
	ws("g-row-warns-name-the-focus", "campaign[act]", twoFocus(focus(false), withQueue(nil, queue(queueHdr, qrow("a", "epic", "pending"))), nil))
	ws("g-bounds-warns-name-the-focus", "campaign_bounds[act]", twoFocus(focus(false), withQueue(nil, queue(queueHdr, qrow("a", "focus", "done"), "campaign_bounds: iterations=x")), nil))
	ws("g-focuses-md-without-a-row-warns", "campaign[act]", twoFocus(focus(false), focus(false), files{"corpus/FOCUSES.md": focusRows("other", "open")}))
	return scs
}
