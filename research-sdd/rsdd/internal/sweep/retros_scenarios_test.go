package sweep

import (
	"strings"
	"testing"
	"time"
)

// The behaviour table of `sweep retros`. Every row is one fixture world, one run and its expectations; the
// same rows run against the frozen script in retros_diff_test.go (stdout, stderr and exit code must be equal),
// so an expectation written here is also what the script printed. `old` names the case of the pre-port
// sweep-retros.test.sh the row replaces (the removed-case map is in the commit message of the port).

type scenario struct {
	name   string
	old    string
	setup  func(w *world)
	env    map[string]string
	args   []string
	rc     int
	has    []string // substrings of stdout
	lacks  []string // substrings that stdout must not hold
	errHas []string // substrings of stderr
}

const (
	pendingMarker = "<!-- review-status: pending -->"
	appliedMarker = "<!-- review-status: applied 2026-01-01 · kit deadbeef -->"
)

// one retro in targetA, registered.
func oneRetro(marker string, n int) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		w.retro(a, "r1.md", marker, n)
		w.wire(a)
		w.targets(a)
	}
}

// bodyRetro writes a retro with the given full text.
func bodyRetro(text string) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		w.put(a+"/retros/r1.md", text)
		w.wire(a)
		w.targets(a)
	}
}

// blockTarget is a wired target with a retro dated retroAgo and a block file dated blockAgo (mtime).
func blockTarget(retroAgo, blockAgo time.Duration) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		w.retro(a, "r1.md", pendingMarker, 1)
		w.wire(a)
		w.put(a+"/t-block1.md", "# b\n")
		w.touch(a+"/retros/r1.md", retroAgo)
		w.touch(a+"/t-block1.md", blockAgo)
		w.targets(a)
	}
}

func scenarios() []scenario {
	renamed := func(renames string) func(w *world) {
		return func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "orig.md", pendingMarker, 1)
			w.wire(a)
			w.commit(a, 20*365*day, "add orig")
			w.git(a, nil, "config", "diff.renames", renames)
			w.git(a, nil, "mv", "retros/orig.md", "retros/renamed.md")
			w.commit(a, 20*365*day-365*day, "rename")
			w.targets(a)
		}
	}
	offRoot := func(settings string) func(w *world) {
		return func(w *world) {
			root := w.tgt("gitroot")
			w.git(root, nil, "init", "-q")
			n := root + "/nested"
			w.put(n+"/.claude/settings.json", settings)
			w.targets(n)
		}
	}
	const stop = `{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}` + "\n"
	return []scenario{
		{name: "pending marker is surfaced", old: "1", setup: oneRetro(pendingMarker, 3),
			has: []string{"PENDING", "r1.md", "status: pending", "~3 proposed deltas", "Summary: 1 pending / 1 retros"}},
		{name: "applied marker is not pending", old: "2, 121", setup: oneRetro(appliedMarker, 4),
			has: []string{"Summary: 0 pending / 1 retros", "Nothing to review."}, lacks: []string{"PENDING"}},
		{name: "dismissed marker is not pending", old: "3", setup: oneRetro("<!-- review-status: dismissed 2026-01-01 -->", 2),
			has: []string{"Summary: 0 pending / 1 retros"}, lacks: []string{"PENDING"}},
		{name: "delta count is exact", old: "4", setup: oneRetro(pendingMarker, 7), has: []string{"~7 proposed deltas"}},
		{name: "canonical section without rows warns", old: "5", setup: oneRetro(pendingMarker, 0),
			has: []string{"~? proposed deltas", "WARN: delta section present but not in countable form — count by hand"}},
		{name: "absent marker is pending with status none", old: "6, 16e, 67", setup: oneRetro("", 1),
			has:   []string{"status: none", "WARN: no review-status marker in r1.md — add '<!-- review-status: pending -->'"},
			lacks: []string{"out-of-scope-marker"}},
		{name: "unknown status word stays pending", old: "7", setup: oneRetro("<!-- review-status: wip -->", 1),
			has: []string{"status: wip", "WARN: unrecognized review-status 'wip' in r1.md — only 'applied' or 'dismissed' close a retro"}},
		{name: "unrecognized status accepted", old: "28", setup: oneRetro("<!-- review-status: accepted -->", 1),
			has: []string{"PENDING", "unrecognized review-status 'accepted'"}},
		{name: "multi-target totals", old: "8", setup: func(w *world) {
			a, b := w.tgt("targetA"), w.tgt("targetB")
			w.retro(a, "p.md", pendingMarker, 2)
			w.retro(a, "done.md", "<!-- review-status: applied 2026-01-01 -->", 5)
			w.retro(b, "p.md", pendingMarker, 1)
			w.targets(a, b)
		}, has: []string{"Summary: 2 pending / 3 retros", "Wiring: 0 wired / 0 wired-off-root / 0 unwired / 2 absent-settings"}},
		{name: "target without retros is silent", old: "9", setup: func(w *world) {
			a, b := w.tgt("targetA"), w.tgt("targetB")
			w.retro(a, "r1.md", pendingMarker, 1)
			w.targets(a, b)
		}, has: []string{"Summary: 1 pending / 1 retros"}},
		{name: "empty retros dir adds nothing", old: "13", setup: func(w *world) {
			a, b := w.tgt("targetA"), w.tgt("targetB")
			w.retro(a, "r1.md", pendingMarker, 1)
			w.tgt("targetB/retros")
			w.targets(a, b)
		}, has: []string{"Summary: 1 pending / 1 retros"}},
		{name: "truncated path is dropped even when it exists", old: "10, 54", setup: func(w *world) {
			a, d := w.tgt("targetA"), w.tgt("real...dots")
			w.retro(a, "r1.md", appliedMarker, 1)
			w.retro(d, "r1.md", pendingMarker, 1)
			w.targets(a, d)
		}, has: []string{"Summary: 0 pending / 1 retros", "WARN: 1 target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: real...dots"},
			lacks: []string{"Nothing to review."}},
		{name: "missing TARGETS.md", old: "11", setup: func(w *world) {}, rc: 1, errHas: []string{"sweep-retros: cannot find {kit}/TARGETS.md"}},
		{name: "no usable path", old: "49", setup: func(w *world) {
			w.put(w.kit+"/TARGETS.md", "# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | /no/backticks |\n")
		}, rc: 1, errHas: []string{"sweep-retros: ERROR — no usable target paths in {kit}/TARGETS.md", "check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths"}},
		{name: "RESEARCH_HOME path form", old: "48", setup: func(w *world) {
			base := w.tgt("rh_base")
			w.retro(base+"/rh_target", "r1.md", pendingMarker, 3)
			w.env["RESEARCH_HOME"] = base
			w.put(w.kit+"/TARGETS.md", "# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | `$RESEARCH_HOME/rh_target` |\n")
		}, has: []string{"PENDING", "Summary: 1 pending / 1 retros"}},
		{name: "marker status is case-insensitive", old: "12", setup: oneRetro("<!-- review-status: Applied 2026-01-01 -->", 3),
			has: []string{"Summary: 0 pending / 1 retros", "Nothing to review."}, lacks: []string{"PENDING"}},
		{name: "marker in the body is ignored", old: "14, 16", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/retros/r1.md", retroText("", 2)+"\nnote: <!-- review-status: applied 2026-01-01 -->\n\nreview-status: applied 2026-01-01\n")
			w.targets(a)
		}, has: []string{"PENDING", "status: none", "Summary: 1 pending / 1 retros"}},
		{name: "marker on line 2 of the leading block", old: "15", setup: bodyRetro("<!-- RECONSTRUCTED note -->\n<!-- review-status: applied 2026-07-07 -->\n" + retroText("", 2)),
			has: []string{"Summary: 0 pending / 1 retros"}, lacks: []string{"PENDING"}},
		{name: "H1, blank, marker on line 3", old: "16b", setup: bodyRetro("# §18 Retro — focus: apis — 2026-08-25\n\n<!-- review-status: applied 2026-09-24 · kit c10f9d9 -->\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | delta 1 | because |\n"),
			has: []string{"Summary: 0 pending / 1 retros"}, lacks: []string{"PENDING"}},
		{name: "marker after a second heading is out of scope", old: "16c, 16f", setup: bodyRetro("# §18 Retro — focus: apis\n\n## Notes\n\n<!-- review-status: applied 2026-09-24 · kit c10f9d9 -->\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | delta 1 | because |\n"),
			has:   []string{"WARN: out-of-scope-marker: r1.md — a review-status marker exists but sits outside the leading-block scope (kit issue #1099); move it into the leading block", "Summary: 1 pending / 1 retros"},
			lacks: []string{"add '<!-- review-status: pending"}},
		{name: "out-of-scope marker on the last line without newline", old: "16d", setup: bodyRetro("# §18 Retro — focus: apis\n\n## Notes\n\n<!-- review-status: applied 2026-09-24 -->"),
			has: []string{"PENDING", "out-of-scope-marker"}},
		{name: "aged retro is escalated and listed first", old: "18", setup: func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "fresh.md", pendingMarker, 1)
			w.retro(a, "old.md", pendingMarker, 1)
			w.touch(a+"/retros/old.md", deepPast)
			w.touch(a+"/retros/fresh.md", 0)
			w.targets(a)
		}, env: map[string]string{"RSDD_RETRO_AGE_DAYS": "1"}, has: []string{"ESCALATED (aged "}},
		{name: "age comes from the git add date", old: "18a", setup: func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "old.md", pendingMarker, 1)
			w.commit(a, deepPast, "add old")
			w.touch(a+"/retros/old.md", 0)
			w.targets(a)
		}, env: map[string]string{"RSDD_RETRO_AGE_DAYS": "1"}, has: []string{"ESCALATED (aged "}},
		{name: "a rename does not date the retro from its original add", old: "52, 144", setup: renamed("true"),
			env: map[string]string{"RSDD_RETRO_AGE_DAYS": "7"}, has: []string{"PENDING", "ESCALATED (aged "}},
		{name: "a rename is dated identically with diff.renames off", old: "144b", setup: renamed("false"),
			env: map[string]string{"RSDD_RETRO_AGE_DAYS": "7"}, has: []string{"PENDING", "ESCALATED (aged "}},
		{name: "corpus advanced past the newest retro", old: "19", setup: blockTarget(deepPast, 2*day),
			has: []string{"MISSING-RETRO: {A} advanced with no retro for the latest run"}, lacks: []string{"Nothing to review."}},
		{name: "retro newer than every block", old: "20", setup: blockTarget(0, deepPast), lacks: []string{"MISSING-RETRO"}},
		{name: "nested retros directory is walked and aged", old: "21", setup: func(w *world) {
			a := w.tgt("targetA")
			w.retro(a+"/research", "n1.md", pendingMarker, 2)
			w.touch(a+"/research/retros/n1.md", deepPast)
			w.targets(a)
		}, env: map[string]string{"RSDD_RETRO_AGE_DAYS": "1"},
			has: []string{"research/retros/n1.md", "~2 proposed deltas", "Summary: 1 pending / 1 retros", "ESCALATED (aged "}},
		{name: "index files are not retros", old: "22", setup: func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "r1.md", pendingMarker, 2)
			w.put(a+"/retros/RETROS-INDEX.md", "# Retros index\n\n| # | file |\n|---|---|\n| 1 | r1.md |\n")
			w.targets(a)
		}, has: []string{"r1.md", "Summary: 1 pending / 1 retros"}, lacks: []string{"RETROS-INDEX.md"}},
		{name: "excluded retro is not counted", old: "23", setup: oneRetro("<!-- kit-retro: exclude -->", 3),
			has: []string{"Summary: 0 pending / 0 retros", "Nothing to review."}, lacks: []string{"PENDING"}},
		{name: "an unmarked retro is still counted", old: "24", setup: func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "client.md", "<!-- kit-retro: exclude -->", 2)
			w.retro(a, "normal.md", "", 1)
			w.targets(a)
		}, has: []string{"normal.md", "Summary: 1 pending / 1 retros"}, lacks: []string{"client.md"}},
		{name: "only excluded retros, old block", old: "25", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/retros/client.md", "<!-- kit-retro: exclude -->\n# client retro - not §18\n")
			w.put(a+"/t-block1.md", "# b\n")
			w.touch(a+"/t-block1.md", deepPast)
			w.targets(a)
		}, has: []string{"MISSING-RETRO: {A} advanced", "Summary: 0 pending / 0 retros"}},
		{name: "garbled exclude marker fails open", old: "26", setup: oneRetro("<!-- kit-retro: excluded -->", 2),
			has: []string{"PENDING", "Summary: 1 pending / 1 retros"}},
		{name: "exclude marker in the body is ignored", old: "27", setup: bodyRetro(retroText("", 2) + "\n<!-- kit-retro: exclude -->\n"),
			has: []string{"PENDING", "status: none", "Summary: 1 pending / 1 retros"}},
		{name: "block just written is inside the grace window", old: "30", setup: blockTarget(2*hour, 0),
			env: map[string]string{"RSDD_MISSING_RETRO_GRACE_HOURS": "4"}, lacks: []string{"MISSING-RETRO"}},
		{name: "block older than the grace window", old: "31", setup: blockTarget(2*hour, hour),
			env: map[string]string{"RSDD_MISSING_RETRO_GRACE_HOURS": "0"}, has: []string{"MISSING-RETRO: {A} advanced"}},
		{name: "waived target suppresses MISSING-RETRO", old: "32", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/retros/retro-waived.md", "<!-- kit-retro: exclude -->\n<!-- retro-waived: 2026-07-27 · dormant -->\n# waiver\n")
			w.put(a+"/t-block1.md", "# b\n")
			w.touch(a+"/t-block1.md", 2*day)
			w.targets(a)
		}, has: []string{"waived: 1 target(s) — MISSING-RETRO suppressed: {A}"}, lacks: []string{"MISSING-RETRO: {A}"}},
		{name: "same fixture without the waiver fires", old: "32b", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/retros/retro-old.md", "<!-- kit-retro: exclude -->\n# not a waiver\n")
			w.put(a+"/t-block1.md", "# b\n")
			w.touch(a+"/t-block1.md", 2*day)
			w.targets(a)
		}, has: []string{"MISSING-RETRO: {A}"}, lacks: []string{"waived:"}},
		{name: "invalid grace hours warn and use 24h", old: "35", setup: blockTarget(2*hour, 0),
			env: map[string]string{"RSDD_MISSING_RETRO_GRACE_HOURS": "foo"}, lacks: []string{"MISSING-RETRO"},
			errHas: []string{"WARN: RSDD_MISSING_RETRO_GRACE_HOURS='foo' is not a non-negative integer — using default 24h"}},
		{name: "marker note when something is pending", old: "50", setup: oneRetro(pendingMarker, 1),
			has: []string{"Note: the count above tracks the review-status MARKER, not whether each delta is open work.", "then set the top marker to '<!-- review-status: applied <date> · kit <sha> -->'."}},
		{name: "no marker note on a clean run", old: "51", setup: oneRetro(appliedMarker, 1),
			has: []string{"Nothing to review."}, lacks: []string{"Note: the count above"}},
		{name: "MISSING-RETRO withholds the clean sentinel", old: "53", setup: func(w *world) {
			a, b := w.tgt("targetA"), w.tgt("targetB")
			w.retro(a, "r1.md", appliedMarker, 1)
			w.put(b+"/t-block1.md", "# b\n")
			w.touch(b+"/t-block1.md", 2*day)
			w.targets(a, b)
		}, has: []string{"MISSING-RETRO: {B} advanced"}, lacks: []string{"Nothing to review."}},
		{name: "absent target is disclosed once", old: "62, 64", setup: func(w *world) { w.targets(w.root + "/nonexistent-target") },
			has: []string{"INFO: corpus not found (absent-input): {root}/nonexistent-target"}},
		{name: "mixed present and absent targets", old: "63", setup: func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "r1.md", pendingMarker, 2)
			w.targets(a, w.root+"/targetB")
		}, has: []string{"PENDING", "Summary: 1 pending / 1 retros", "INFO: corpus not found (absent-input): {B}", "INFO: 1 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above."}},
		{name: "U19 first add wins over a re-add", old: "71", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/t-block1.md", "# block\n")
			w.commit(a, 20*365*day, "add block")
			w.git(a, nil, "rm", "-q", "t-block1.md")
			w.commit(a, 19*365*day, "delete block")
			w.put(a+"/t-block1.md", "# block\n")
			w.commit(a, 3*day, "re-add block")
			w.retro(a, "r1.md", pendingMarker, 1)
			w.commit(a, 2*365*day, "add retro")
			w.targets(a)
		}, lacks: []string{"MISSING-RETRO"}},
		{name: "U19 untracked block is dated by mtime", old: "72", setup: func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "r1.md", pendingMarker, 1)
			w.commit(a, deepPast, "add retro")
			w.put(a+"/t-block1.md", "# block\n")
			w.touch(a+"/t-block1.md", 2*day)
			w.targets(a)
		}, has: []string{"MISSING-RETRO: {A}"}},
		{name: "wired target", old: "73", setup: func(w *world) {
			a := w.tgt("targetA")
			w.retro(a, "r1.md", appliedMarker, 1)
			w.wire(a)
			w.targets(a)
		}, has: []string{"Wiring: 1 wired / 0 wired-off-root / 0 unwired / 0 absent-settings / 0 unreadable — 1 targets checked."}, lacks: []string{"WARN"}},
		{name: "unwired target", old: "74, 78, 79", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/.claude/settings.json", `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"retro-gate"}]}],"Stop":[]},"permissions":{"deny":["retro-gate"]}}`+"\n")
			w.targets(a)
		}, has: []string{"WARN: retro-gate not wired in {A}/.claude/settings.json", "Wiring: 0 wired / 0 wired-off-root / 1 unwired / 0 absent-settings"}},
		{name: "absent settings", old: "75", setup: func(w *world) { w.targets(w.tgt("targetA")) },
			has: []string{"WARN: retro-gate hook absent-settings — no .claude/settings.json: {A}"}},
		{name: "non-directory path is skipped by the wiring pass", old: "76", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/.claude/settings.json", stop)
			w.targets(a, "/mrdoob/three.js")
		}, has: []string{"Wiring: 1 wired", "INFO: corpus not found (absent-input): /mrdoob/three.js"}, lacks: []string{"WARN: retro-gate hook absent-settings — no .claude/settings.json: /mrdoob"}},
		{name: "multi-target wiring", old: "77", setup: func(w *world) {
			a, b, c := w.tgt("targetA"), w.tgt("targetB"), w.tgt("targetC")
			w.put(a+"/.claude/settings.json", stop)
			w.put(b+"/.claude/settings.json", "{\"hooks\":{}}\n")
			w.targets(a, b, c)
		}, has: []string{"Wiring: 1 wired / 0 wired-off-root / 1 unwired / 1 absent-settings / 0 unreadable — 3 targets checked."}},
		{name: "wired off its git root", old: "80a", setup: offRoot(stop),
			has: []string{"WARN: retro-gate hook wired-off-root — {root}/gitroot/nested is not its own git root", "Wiring: 0 wired / 1 wired-off-root"}},
		{name: "off-root and unwired stays unwired", old: "80b", setup: offRoot("{\"hooks\":{}}\n"),
			has: []string{"Wiring: 0 wired / 0 wired-off-root / 1 unwired"}, lacks: []string{"wired-off-root —"}},
		{name: "four wiring states, off-root first", old: "80c, 80d", setup: func(w *world) {
			root := w.tgt("gitroot")
			w.git(root, nil, "init", "-q")
			off := root + "/nested"
			w.put(off+"/.claude/settings.json", stop)
			wd, un, ab := w.tgt("targetA"), w.tgt("targetB"), w.tgt("targetC")
			w.put(wd+"/.claude/settings.json", stop)
			w.put(un+"/.claude/settings.json", "{\"hooks\":{}}\n")
			w.targets(off, wd, un, ab)
		}, has: []string{"Wiring: 1 wired / 1 wired-off-root / 1 unwired / 1 absent-settings / 0 unreadable — 4 targets checked."}},
		{name: "off-root target last in the list", old: "80e", setup: func(w *world) {
			root := w.tgt("gitroot")
			w.git(root, nil, "init", "-q")
			off := root + "/nested"
			w.put(off+"/.claude/settings.json", stop)
			wd, un := w.tgt("targetA"), w.tgt("targetB")
			w.put(wd+"/.claude/settings.json", stop)
			w.put(un+"/.claude/settings.json", "{\"hooks\":{}}\n")
			w.targets(wd, un, off)
		}, has: []string{"Wiring: 1 wired / 1 wired-off-root / 1 unwired / 0 absent-settings / 0 unreadable — 3 targets checked."}},
		{name: "profile on stderr", old: "68", setup: oneRetro(pendingMarker, 1), env: map[string]string{"RSDD_PROFILE": "1"},
			has: []string{"Summary: 1 pending / 1 retros"},
			errHas: []string{"profile: pending-pass 0.000000\n", "profile: waiver-pass 0.000000\n", "profile: retro-newest-pass ", "profile: block-newest-pass ",
				"profile: wiring-pass ", "profile: total 0.000000\n"}},
		{name: "profile off prints nothing extra", old: "69", setup: oneRetro(pendingMarker, 1), env: map[string]string{"RSDD_PROFILE": "0"},
			has: []string{"Summary: 1 pending / 1 retros"}},
		{name: "json envelope ok", old: "JSON ok", setup: oneRetro(pendingMarker, 3), args: []string{"--json"},
			has:   []string{"\"schema\": \"research-sdd.sweep-retros/v1\"", "\"state\": \"ok\"", "\"reason\": null", "\"deltas\": 3", "\"deltas_state\": \"counted\""},
			lacks: []string{"PENDING"}},
		{name: "json no-match", old: "JSON no-match", setup: oneRetro(appliedMarker, 1), args: []string{"--json"},
			has: []string{"\"state\": \"no-match\"", "\"reason\": \"retros found but none pending and no missing retro\"", "\"items\": []"}},
		{name: "json empty-input", old: "JSON empty-input", setup: func(w *world) { w.targets(w.tgt("targetA")) }, args: []string{"--json"},
			has: []string{"\"state\": \"empty-input\"", "target corpora found but no retro files under them"}},
		{name: "json absent-input", old: "JSON absent-input", setup: func(w *world) { w.targets(w.root + "/nope") }, args: []string{"--json"},
			has: []string{"\"state\": \"absent-input\"", "\"targets_absent\": 1"}},
		{name: "json missing-retro beside no retros", old: "JSON precedence", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/t-block1.md", "# b\n")
			w.touch(a+"/t-block1.md", 2*day)
			w.targets(a)
		}, args: []string{"--json"}, has: []string{"\"state\": \"ok\"", "\"kind\": \"missing-retro\"", "\"missing_retro\": 1"}},
		{name: "json fields", old: "JSON fields", setup: func(w *world) {
			a := w.tgt("targetA")
			w.put(a+"/retros/r1.md", pendingMarker+"\n# retro\n\n## 1. Notes\n\nnothing\n")
			w.put(a+"/retros/r2.md", retroText(pendingMarker, 1))
			w.touch(a+"/retros/r2.md", deepPast)
			w.targets(a, "/trunc...ated")
		}, args: []string{"--json"}, env: map[string]string{"RSDD_RETRO_AGE_DAYS": "7"},
			has: []string{"\"targets_skipped\": 1", "\"deltas\": null", "\"deltas_state\": \"uncountable\"", "\"warning\": \"non-conforming delta declaration — count by hand\"", "\"escalated\": true", "\"escalated\": false"}},
		{name: "json deltas_state no-section", old: "JSON deltas_state", setup: bodyRetro(pendingMarker + "\n# retro\n\nplain text\n"), args: []string{"--json"},
			has: []string{"\"deltas\": null", "\"deltas_state\": \"no-section\"", "\"warning\": null"}},
		{name: "json mode keeps stderr", old: "JSON", setup: blockTarget(2*hour, 0), args: []string{"--json"},
			env: map[string]string{"RSDD_MISSING_RETRO_GRACE_HOURS": "x"}, errHas: []string{"WARN: RSDD_MISSING_RETRO_GRACE_HOURS='x'"}, lacks: []string{"Summary:"}},
	}
}

func TestRetrosScenarios(t *testing.T) {
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			w := newWorld(t)
			for k, v := range sc.env {
				w.env[k] = v
			}
			sc.setup(w)
			r := w.run(sc.args...)
			if r.rc != sc.rc {
				t.Errorf("exit %d, want %d\nstdout:\n%s\nstderr:\n%s", r.rc, sc.rc, r.out, r.err)
			}
			for _, h := range sc.has {
				if !strings.Contains(r.out, w.expand(h)) {
					t.Errorf("stdout lacks %q\n%s", h, r.out)
				}
			}
			for _, l := range sc.lacks {
				if strings.Contains(r.out, w.expand(l)) {
					t.Errorf("stdout holds %q\n%s", l, r.out)
				}
			}
			for _, h := range sc.errHas {
				if !strings.Contains(r.err, w.expand(h)) {
					t.Errorf("stderr lacks %q\n%s", h, r.err)
				}
			}
		})
	}
}
