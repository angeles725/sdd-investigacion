package show

// The S3 scenario table: full `--sync-state` runs over crafted corpora. The groups follow the branches of the
// frozen block (status-sync.sh): where the envelope goes, which file is targeted, the refusals, the carried-forward
// preamble, covered_blocks in each of its four shapes, the known_gaps/gaps_closed reconciliation, undocumented_findings,
// --only, and the CHANGED / WARN lines. The groups of the main suite that issue #2549 names for S3 (envelope and
// sync-state) are these cases as state files.

const (
	fOpen  = "<!-- research-state.v1 -->"
	fClose = "<!-- /research-state.v1 -->"
)

// fence is an envelope block holding exactly the given lines.
func fence(lines ...string) string {
	return ln(append(append([]string{fOpen}, lines...), fClose)...)
}

// stale is a complete envelope with every owned counter at a wrong value.
var stale = []string{"schema: research-state.v1", "covered_blocks: 9", "gaps_closed: 9", "known_gaps: 9", "investigable_open: 9", "requires_execution_open: 9", "blocked_open: 9", "deferred_open: 9", "undocumented_findings: 9"}

// backlog is a Gap-backlog section with the given rows (the 4-column layout).
func backlog(rows ...string) string {
	return ln(append([]string{"## Gap-backlog (prioritized)", h4}, rows...)...)
}

var (
	rowPending = "| high | live gap | web | pending |"
	rowMedium  = "| medium | m gap | web | pending |"
	rowDone    = "| low | done gap | web | ✅ covered |"
	rowReq     = "| medium | needs hw | web | requires-execution |"
	rowBlocked = "| low | stuck gap | web | blocked (requires-hw) |"
	rowDefer   = "| deferred | parked gap | web | parked |"
	bq         = "> intro one\n> intro two"
)

// fcHeader/fcRoot build FOCUSES.md: the root row carries the given prefix and range cells.
const fcHeader = "| Focus | Status | State | Block prefix | Blocks |\n|---|---|---|---|---|\n"

func fcRoot(prefix, rng string) string {
	return "| (root) | open | `RESEARCH-STATE.md` | " + prefix + " | " + rng + " |\n"
}

func fcRow(slug, prefix, rng string) string {
	return "| " + slug + " | open | `RESEARCH-STATE-" + slug + ".md` | " + prefix + " | " + rng + " |\n"
}

func blockFiles(names ...string) files {
	f := files{}
	for _, n := range names {
		f["corpus/"+n] = "# block\n"
	}
	return f
}

func merge(a files, more ...files) files {
	out := files{}
	for _, m := range append([]files{a}, more...) {
		for k, v := range m {
			out[k] = v
		}
	}
	return out
}

func s3Scenarios() []s3Scenario {
	var scs []s3Scenario
	add := func(s ...s3Scenario) { scs = append(scs, s...) }
	std := backlog(rowPending, rowMedium, rowDone)

	// --- where the envelope goes, and what the rewrite keeps ----------------------------------------------
	add(
		ss("seed-after-blockquote", ln("# T", bq, "", "## Notes", "text", std), nil),
		ss("seed-no-blockquote-appends", ln("# T", "", "## Notes", "text", std), nil),
		ss("seed-blockquote-to-eof", ln("# T", "> a", "> b"), nil),
		ss("seed-blockquote-first-line", ln("> a", "text", std), nil),
		ss("seed-two-blockquotes-first-only", ln("# T", "> a", "", "> b", std), nil),
		ss("seed-empty-file", "", nil),
		ss("seed-no-trailing-newline", "# T\n> q\ntext", nil),
		ss("seed-gt-inside-line-is-not-quote", ln("# T", "a > b", "text"), nil),
		ss("seed-stray-close-marker-only", ln("# T", fClose, "> q", "x"), nil),
		ss("replace-keeps-prose", ln("# T", bq, fence(stale...), "tail", std), nil),
		ss("replace-no-trailing-newline", "# T\n"+fOpen+"\nschema: research-state.v1\n"+fClose+"\ntail", nil),
		ss("replace-two-fences", ln("# T", fence("a: 1"), "mid", fence("b: 2"), "end"), nil),
		ss("replace-unclosed-fence-drops-to-eof", ln("# T", fOpen, "schema: research-state.v1", "tail", std), nil),
		ss("replace-open-inside-fence", ln(fOpen, "x", fOpen, "y", fClose, "z"), nil),
		ss("replace-marker-dot-is-a-wildcard", ln("# T", "<!-- research-stateXv1 -->", "a: 1", "<!-- /research-stateXv1 -->", "tail"), nil),
		ss("replace-marker-with-trailing-text", ln("# T", fOpen+" trailing", "a: 1", fClose+" more", "tail"), nil),
		ss("replace-crlf-lines", "# T\r\n"+fOpen+"\r\nblock_scope: per-focus\r\nundocumented_findings: 3\r\n"+fClose+"\r\ntail\r\n", nil),
		s3Scenario{name: "idempotent-seed-three-runs", files: files{stateRel: ln("# T", bq, "", std)},
			runs: [][]string{{"{ROOT}/corpus", "--sync-state"}, {"{ROOT}/corpus", "--sync-state"}, {"{ROOT}/corpus", "--sync-state"}}},
		s3Scenario{name: "idempotent-replace-two-runs", files: files{stateRel: ln("# T", fence(stale...), std)},
			runs: [][]string{{"{ROOT}/corpus", "--sync-state"}, {"{ROOT}/corpus", "--sync-state"}}},
		s3Scenario{name: "other-modes-reach-the-tail", files: files{stateRel: ln("# T", std)},
			runs: [][]string{{"{ROOT}/corpus", "--next"}, {"{ROOT}/corpus"}}},
	)

	// --- which file is targeted -----------------------------------------------------------------------------
	two := files{"corpus/RESEARCH-STATE-b.md": ln("# B", "> q", backlog("| high | b1 | x | pending |"))}
	add(
		ss("guard-two-states-refused", ln("# R", std), two),
		ss("guard-three-states-refused", ln("# R", std), merge(two, files{"corpus/RESEARCH-STATE-c.md": "# C\n"})),
		ss("guard-nested-state-counts", ln("# R", std), files{"corpus/sub/RESEARCH-STATE-x.md": "# X\n"}),
		ss("focus-writes-only-that-file", ln("# R", std), two, "--sync-state", "--focus", "b"),
		s3Scenario{name: "focus-ambiguous-takes-the-first-pick", files: files{"corpus/a/RESEARCH-STATE-b.md": ln("# A", std), "corpus/c/RESEARCH-STATE-b.md": ln("# C", std)},
			runs: [][]string{{"{ROOT}/corpus", "--sync-state", "--focus", "b"}}},
		ss("focus-absent", ln("# R", std), two, "--sync-state", "--focus", "zzz"),
		ss("focus-on-a-lone-root", ln("# R", std), nil, "--sync-state", "--focus", "b"),
		ss("focus-and-block-prefix", ln("# R", std), merge(two, blockFiles("b-block1.md", "b-block2.md", "r-block1.md", "b-note.md")), "--sync-state", "--focus", "b"),
		ss("root-beside-siblings", ln("# R", std), merge(two, blockFiles("a-block1.md")), "--sync-state", "--root"),
		ss("root-absent-under-siblings", ln("# R", std), nil, "--sync-state", "--root"),
		s3Scenario{name: "root-nested-beside-siblings", files: files{"corpus/sub/RESEARCH-STATE.md": ln("# R", std), "corpus/sub/RESEARCH-STATE-q.md": "# Q\n", stateRel: ""}, runs: [][]string{{"{ROOT}/corpus", "--sync-state", "--root"}}},
		s3Scenario{name: "no-state-file-bootstraps", files: files{"corpus/notes.md": "x\n"}, runs: [][]string{{"{ROOT}/corpus", "--sync-state"}}},
		ss("template-is-not-a-state-file", ln("# R", std), files{"corpus/RESEARCH-STATE.template.md": "# T\n"}),
		s3Scenario{name: "relative-target", files: files{stateRel: ln("# R", bq, std)}, runs: [][]string{{"corpus", "--sync-state"}}},
		s3Scenario{name: "relative-target-from-inside", files: files{stateRel: ln("# R", bq, std)}, cwd: "corpus", runs: [][]string{{".", "--sync-state"}}},
		s3Scenario{name: "target-trailing-slash", files: files{stateRel: ln("# R", bq, std)}, runs: [][]string{{"{ROOT}/corpus/", "--sync-state"}}},
		s3Scenario{name: "state-is-a-symlink", files: files{"real/shared.md": ln("# R", bq, std)}, links: map[string]string{stateRel: "{ROOT}/real/shared.md"}, runs: [][]string{{"{ROOT}/corpus", "--sync-state"}}},
		s3Scenario{name: "state-is-a-relative-symlink", files: files{"real/shared.md": ln("# R", bq, std)}, links: map[string]string{stateRel: "../real/shared.md"}, runs: [][]string{{"{ROOT}/corpus", "--sync-state"}}},
		s3Scenario{name: "unreadable-state", files: files{stateRel: ln("# R", std)}, unreadable: []string{stateRel}, needsUser: true, runs: [][]string{{"{ROOT}/corpus", "--sync-state"}}},
		s3Scenario{name: "unreadable-sibling-focus", files: files{stateRel: ln("# R", std), "corpus/RESEARCH-STATE-b.md": "# B\n"}, unreadable: []string{"corpus/RESEARCH-STATE-b.md"}, needsUser: true,
			runs: [][]string{{"{ROOT}/corpus", "--sync-state", "--focus", "b"}}},
		s3Scenario{name: "nested-state-counts-its-own-dir", files: files{"corpus/sub/RESEARCH-STATE.md": ln("# R", std), "corpus/sub/a-block1.md": "x", "corpus/top-block1.md": "x", "corpus/top-block2.md": "x"}, runs: [][]string{{"{ROOT}/corpus", "--sync-state"}}},
	)

	// --- refusals before any write ---------------------------------------------------------------------------
	add(
		ss("invalid-priority-refused", ln("# R", bq, fence(stale...), backlog("| urgent | g1 | x | pending |", rowPending)), nil),
		ss("invalid-priority-warns-once-from-backlog-rows", ln("# R", bq, "## Gap backlog", h4, "| bogus | g1 | x | pending |"), nil),
		ss("near-miss-heading-warning-passes-through", ln("# R", bq, "## Gap backlog", h4, rowPending), nil),
		ss("unrecognised-status-token-warning", ln("# R", bq, backlog("| high | g1 | x | pendng |", rowPending)), nil),
		ss("retyped-row-warning", ln("# R", bq, backlog("| high | g1 | x | re-typed (needs hw) |", rowPending)), nil),
	)

	// --- block_scope and the carried-forward preamble ---------------------------------------------------------
	sg := ln("## Covered blocks", "- B1 done", "- B2 done B2 again", "- B7: x")
	add(
		ss("bs-per-focus-carried", ln("# R", bq, fence("schema: research-state.v1", "block_scope: per-focus")), nil),
		ss("bs-indented-form-read", ln("# R", fence("  block_scope: shared-global"), sg), nil),
		ss("bs-no-space-form-probed", ln("# R", fence("block_scope:shared-global"), sg), nil),
		ss("bs-illegal-value-carried-not-used", ln("# R", fence("block_scope: bogus"), sg), nil),
		ss("bs-per-focus-no-space-probed", ln("# R", fence("block_scope:per-focus"), sg), blockFiles("a-block1.md", "a-block2.md")),
		ss("bs-illegal-no-space-probed-then-ignored", ln("# R", fence("block_scope:bogus"), sg), nil),
		ss("bs-probe-first-line-wins", ln("# R", fence("block_scope:shared-global", "block_scope:per-focus"), sg), nil),
		ss("bs-probe-tab-and-spaces", ln("# R", fence("\tblock_scope:\t shared-global"), sg), nil),
		ss("bs-outside-the-fence-ignored", ln("# R", "block_scope: shared-global", fence("schema: research-state.v1"), sg), nil),
		ss("sg-attributed-from-covered-blocks", ln("# R", fence("block_scope: shared-global"), sg), blockFiles("a-block1.md", "a-block2.md", "a-block3.md")),
		ss("sg-attributed-from-iteration-history", ln("# R", fence("block_scope: shared-global"),
			"## Iteration history", "| Iter | Block | Note |", "|---|---|---|", "| 1 | B3 | x |", "| 2 | B4, B3 | y |"), nil),
		ss("sg-none-attributed-warns-and-seeds-zero", ln("# R", fence("block_scope: shared-global"), "## Covered blocks", "- none yet"), blockFiles("a-block1.md")),
		ss("sg-first-seed-has-no-scope-so-counts-disk", ln("# R", bq, sg), blockFiles("a-block1.md", "a-block2.md")),
		ss("preamble-carried-in-order", ln("# R", fence("method: sweep", "future_field: 7", "schema: research-state.v1", "  indented: yes", "no colon here", "novalue:", ": odd", "key : spaced", "Schema: cased", "note: a: b: c", "gaps_closed: 1")), nil),
		ss("preamble-owned-keys-never-carried", ln("# R", fence(stale...)), nil),
		ss("preamble-only-unowned-trailing-spaces", ln("# R", fence("method:   x y   ", "other:\t\tz\t")), nil),
		ss("preamble-backslash-escapes-are-awk-v-escapes", ln("# R", fence("method: a\\tb\\\\c\\qd\\101e\\x41f\\x414 g\\/h\\\"i", "second: \\n|\\r|\\a|\\b|\\f|\\v|\\8|\\18")), nil),
		ss("preamble-backslash-at-end", ln("# R", fence("method: trailing\\", "x: 1")), nil),
		ss("preamble-empty-envelope-carries-nothing", ln("# R", fence()), nil),
		ss("preamble-only-colon-lines", ln("# R", fence(":", "::")), nil),
	)

	// --- covered_blocks in its four shapes ---------------------------------------------------------------------
	disk := blockFiles("a-block1.md", "a-block2.md", "b-bloque3-extra.md", "notes.md", "c-block4.txt", ".h-block5.md", "d-block-x.md", "e-block7-a_b-c.md")
	add(
		ss("cb-unprefixed-counts-canonical-block-files", ln("# R", bq, std), disk),
		s3Scenario{name: "cb-ignores-symlinked-md-and-directories", files: merge(files{stateRel: ln("# R", std), "corpus/a-block1.md": "x", "corpus/dir-block9.md/inner": "x", "real/z-block2.md": "x"}),
			links: map[string]string{"corpus/z-block2.md": "{ROOT}/real/z-block2.md"}, runs: [][]string{{"{ROOT}/corpus", "--sync-state"}}},
		ss("cb-prefix-from-focuses-md", ln("# R", std), merge(blockFiles("base-block1.md", "base-block2.md", "other-block1.md", "xbase-block3.md"), files{"corpus/FOCUSES.md": fcHeader + fcRoot("base-", "")})),
		ss("cb-prefix-regex-dot-matches-any-char", ln("# R", std), merge(blockFiles("aXb-block1.md", "a.b-block2.md", "ab-block3.md"), files{"corpus/FOCUSES.md": fcHeader + fcRoot("a.b-", "")})),
		ss("cb-prefix-from-focus-slug", ln("# R", std), merge(blockFiles("zed-block1.md", "zed-block2.md", "zed-bloque3.md", "o-block1.md"), files{"corpus/RESEARCH-STATE-zed.md": ln("# Z", std)}), "--sync-state", "--focus", "zed"),
		ss("cb-prefix-slug-with-dot-wildcard", ln("# R", std), merge(blockFiles("aXb-block1.md", "a.b-block2.md"), files{"corpus/RESEARCH-STATE-a.b.md": "# Z\n"}), "--sync-state", "--focus", "a.b"),
		ss("cb-prefix-slug-bad-ere-counts-zero", ln("# R", std), merge(blockFiles("a(-block1.md"), files{"corpus/RESEARCH-STATE-a(.md": "# Z\n"}), "--sync-state", "--focus", "a("),
		ss("cb-prefix-slug-unmatched-close-paren", ln("# R", std), merge(blockFiles("a)-block1.md"), files{"corpus/RESEARCH-STATE-a).md": "# Z\n"}), "--sync-state", "--focus", "a)"),
		ss("cb-prefix-slug-balanced-group", ln("# R", std), merge(blockFiles("ab-block1.md", "a(b)-block2.md"), files{"corpus/RESEARCH-STATE-a(b).md": "# Z\n"}), "--sync-state", "--focus", "a(b)"),
		ss("cb-range-counts-numbers-in-range", ln("# R", std), merge(blockFiles("x-block1.md", "x-block2.md", "x-block3.md", "x-block4.md", "x-bloque2-dup.md", "y-block9.md"), files{"corpus/FOCUSES.md": fcHeader + fcRoot("x", "B1–B3")})),
		ss("cb-range-other-rows-claim-theirs", ln("# R", std), merge(blockFiles("x-block1.md", "x-block2.md", "x-block3.md", "p-block4.md", "x-block5.md"), files{"corpus/FOCUSES.md": fcHeader + fcRoot("x", "B1–B6") + fcRow("p", "p-", "") + fcRow("q", "q", "B5–B5")})),
		ss("cb-range-reports-missing-ids", ln("# R", std), merge(blockFiles("x-block1.md", "x-block4.md"), files{"corpus/FOCUSES.md": fcHeader + fcRoot("x", "B1–B12")})),
		ss("cb-range-reports-mixed-families", ln("# R", std), merge(blockFiles("x-block1.md", "y-block2.md", "z-block3.md"), files{"corpus/FOCUSES.md": fcHeader + fcRoot("x", "B1–B3")})),
		ss("cb-range-no-file-inside-warns", ln("# R", std), merge(blockFiles("x-block30.md", "x-block31.md"), files{"corpus/FOCUSES.md": fcHeader + fcRoot("x", "B1–B3")})),
		ss("cb-range-malformed-ignored-with-warn", ln("# R", std), merge(blockFiles("x-block1.md"), files{"corpus/FOCUSES.md": fcHeader + fcRoot("x", "B3–B1")})),
		ss("cb-range-several-cells-warns", ln("# R", std), merge(blockFiles("x-block1.md", "x-block5.md"), files{"corpus/FOCUSES.md": "| Focus | Status | State | Block prefix | Blocks | Also |\n|---|---|---|---|---|---|\n| (root) | open | `RESEARCH-STATE.md` | x | B1–B3 | B4–B9 |\n"})),
		ss("cb-range-fallback-cell-warns", ln("# R", std), merge(blockFiles("x-block1.md", "x-block2.md"), files{"corpus/FOCUSES.md": "| Focus | Status | State | Block prefix | Blocks | Note |\n|---|---|---|---|---|---|\n| (root) | open | `RESEARCH-STATE.md` | x | many | B1–B2 |\n"})),
		ss("cb-focuses-md-unreadable-is-a-plain-count", ln("# R", std), merge(blockFiles("a-block1.md"), files{"corpus/FOCUSES.md/inner": "x"})),
		ss("cb-focuses-md-without-root-row", ln("# R", std), merge(blockFiles("a-block1.md", "a-block2.md"), files{"corpus/FOCUSES.md": fcHeader + fcRow("p", "p-", "")})),
		ss("cb-nested-focus-prefix-counts-its-dir", ln("# R", std), merge(blockFiles("t-block1.md"), files{"corpus/sub/RESEARCH-STATE-q.md": "# Q\n", "corpus/sub/q-block1.md": "x", "corpus/sub/q-block2.md": "x"}), "--sync-state", "--focus", "q"),
	)

	// --- the un-suffixed root of a multi-focus corpus (kit #906) ----------------------------------------------------
	cwFiles := merge(two, blockFiles("a-block1.md", "a-block2.md", "b-block1.md"))
	add(
		ss("cw-root-first-seed-writes-and-warns", ln("# R", std), cwFiles, "--sync-state", "--root"),
		ss("cw-root-declared-value-kept", ln("# R", fence("covered_blocks: 1"), std), cwFiles, "--sync-state", "--root"),
		ss("cw-root-fence-without-covered-blocks-writes-and-warns", ln("# R", fence("known_gaps: 3"), std), cwFiles, "--sync-state", "--root"),
		ss("cw-root-declared-equal-nothing-to-keep", ln("# R", fence("covered_blocks: 3"), std), cwFiles, "--sync-state", "--root"),
		ss("cw-root-only-covered-blocks-writes", ln("# R", fence("covered_blocks: 1"), std), cwFiles, "--sync-state", "--root", "--only", "covered_blocks"),
		ss("cw-root-only-other-counter-no-warning", ln("# R", fence("covered_blocks: 1"), std), cwFiles, "--sync-state", "--root", "--only", "blocked_open"),
		ss("cw-root-with-prefix-is-scoped", ln("# R", std), merge(cwFiles, files{"corpus/FOCUSES.md": fcHeader + fcRoot("a-", "") + fcRow("b", "b-", "")}), "--sync-state", "--root"),
		ss("cw-root-with-range-is-scoped", ln("# R", std), merge(cwFiles, files{"corpus/FOCUSES.md": fcHeader + fcRoot("a", "B1–B2") + fcRow("b", "b-", "")}), "--sync-state", "--root"),
		ss("cw-root-shared-global-is-scoped", ln("# R", fence("block_scope: shared-global"), sg), cwFiles, "--sync-state", "--root"),
		ss("cw-focus-file-is-never-corpus-wide", ln("# R", std), cwFiles, "--sync-state", "--focus", "b"),
		ss("cw-lone-root-is-never-corpus-wide", ln("# R", std), blockFiles("a-block1.md")),
	)

	// --- known_gaps / gaps_closed ------------------------------------------------------------------------------
	cov := func(r string) string { return ln("## Coverage", "- Coverage metric: "+r) }
	clampBlocked := ln("## Blocked gaps", "- g1 — needs: hw", "- g2 — needs: hw", "- g3 — needs: hw")
	mal := backlog("| deferred | G1 | x |", rowPending)
	add(
		ss("kg-pick-from-coverage-prose", ln("# R", std, cov("2/3")), nil),
		ss("kg-pick-no-prose-no-envelope-seeds-zero", ln("# R", "# only prose"), nil),
		ss("kg-pick-falls-back-to-the-envelope", ln("# R", fence("known_gaps: 12", "gaps_closed: 4"), "no prose"), nil),
		ss("kg-pick-prefers-prose-over-the-envelope", ln("# R", fence("known_gaps: 12", "gaps_closed: 4"), cov("5/7")), nil),
		ss("kg-backlog-exceeds-stale-coverage-warns", ln("# R", backlog(rowPending, rowMedium, rowDone, rowDone), cov("1/2")), nil),
		ss("kg-backlog-equal-coverage-uses-prose", ln("# R", backlog(rowPending, rowDone), cov("1/2")), nil),
		ss("kg-backlog-exceeds-no-coverage-prose", ln("# R", backlog(rowPending, rowDone, rowReq)), nil),
		ss("kg-backlog-exceeds-with-deferred-and-blocked", ln("# R", backlog(rowPending, rowDefer, rowBlocked, rowReq, rowDone), cov("1/2")), nil),
		ss("kg-gc-clamp-negative-keeps-declared", ln("# R", fence("gaps_closed: 7"), backlog(rowPending), clampBlocked, cov("0/0")), nil),
		ss("kg-gc-clamp-negative-no-declared", ln("# R", backlog(rowPending), clampBlocked, cov("0/0")), nil),
		ss("kg-gc-clamp-silent-when-only-excludes-gaps-closed", ln("# R", fence("gaps_closed: 7"), backlog(rowPending), clampBlocked, cov("0/0")), nil, "--sync-state", "--only", "blocked_open"),
		ss("kg-gc-clamp-warns-when-only-names-gaps-closed", ln("# R", fence("gaps_closed: 7"), backlog(rowPending), clampBlocked, cov("0/0")), nil, "--sync-state", "--only", "gaps_closed,blocked_open"),
		ss("kg-inplace-blocked-subtracted-and-warned", ln("# R", backlog(rowPending, rowBlocked, rowDone, rowDone), cov("1/2")), nil),
		ss("kg-lb-uncounted-keeps-declared-pair", ln("# R", fence("known_gaps: 12", "gaps_closed: 4"), mal, cov("1/2")), nil),
		ss("kg-lb-uncounted-declared-above-derived-plus-uncounted", ln("# R", fence("known_gaps: 40", "gaps_closed: 4"), mal, cov("1/2")), nil),
		ss("kg-lb-uncounted-closure-raises-gaps-closed", ln("# R", fence("known_gaps: 12", "gaps_closed: 0"), backlog("| deferred | G1 | x |", rowPending, rowDone, rowDone, rowDone)), nil),
		ss("kg-lb-declared-equals-derived-plus-uncounted-no-upper-warning", ln("# R", fence("known_gaps: 2", "gaps_closed: 0"), mal), nil),
		ss("kg-lb-declared-one-above-derived-plus-uncounted-warns", ln("# R", fence("known_gaps: 3", "gaps_closed: 0"), mal), nil),
		ss("kg-lb-declared-gaps-closed-literal-kept-when-equal-to-derived", ln("# R", fence("known_gaps: 9", "gaps_closed: 007"), backlog("| deferred | G1 | x |", rowDone, rowDone, rowDone, rowDone, rowDone, rowDone, rowDone)), nil),
		ss("kg-lb-declared-literals-kept-when-gaps-closed-equals-known-gaps", ln("# R", fence("known_gaps: 05", "gaps_closed: 5"), mal), nil),
		ss("kg-lb-known-gaps-literal-wins-when-gaps-closed-is-above", ln("# R", fence("known_gaps: 05", "gaps_closed: 6"), mal), nil),
		ss("kg-lb-gaps-closed-clamped-to-known-gaps", ln("# R", fence("known_gaps: 3", "gaps_closed: 8"), backlog("| deferred | G1 | x |", rowPending)), nil),
		ss("kg-lb-gaps-closed-declared-not-a-number", ln("# R", fence("known_gaps: 12", "gaps_closed: many"), mal), nil),
		ss("kg-lb-inplace-blocked-warned", ln("# R", fence("known_gaps: 12", "gaps_closed: 4"), backlog("| deferred | G1 | x |", rowBlocked, rowPending), cov("1/2")), nil),
		ss("kg-lb-declared-below-derived-is-not-kept", ln("# R", fence("known_gaps: 1", "gaps_closed: 0"), mal, cov("1/2")), nil),
		ss("kg-b1-closed-only-no-metric-keeps-declared", ln("# R", fence("known_gaps: 10", "gaps_closed: 2"), backlog("| — | G1 | x | closed |", "| ~~high~~ | G2 | x | closed |")), nil),
		ss("kg-b1-needs-the-metric-absent", ln("# R", fence("known_gaps: 10", "gaps_closed: 2"), backlog("| — | G1 | x | closed |"), cov("1/2")), nil),
		ss("kg-b1-needs-no-open-rows", ln("# R", fence("known_gaps: 10", "gaps_closed: 2"), backlog("| — | G1 | x | closed |", rowPending)), nil),
		ss("kg-b1-needs-no-deferred-rows", ln("# R", fence("known_gaps: 10", "gaps_closed: 2"), backlog("| — | G1 | x | closed |", rowDefer)), nil),
		ss("kg-declared-kept-when-above-derived", ln("# R", fence("known_gaps: 9", "gaps_closed: 8"), std, cov("2/3")), nil),
		ss("kg-declared-gaps-closed-only-above-derived", ln("# R", fence("known_gaps: 3", "gaps_closed: 3"), std, cov("1/3")), nil),
		ss("kg-declared-known-gaps-only-above-derived", ln("# R", fence("known_gaps: 30", "gaps_closed: 0"), std, cov("0/3")), nil),
		ss("kg-declared-pair-inconsistent-writes-derived", ln("# R", fence("known_gaps: 1", "gaps_closed: 50"), std, cov("2/3")), nil),
		ss("kg-declared-pair-consistent-gc-above-both", ln("# R", fence("known_gaps: 60", "gaps_closed: 50"), std, cov("2/3")), nil),
		ss("kg-declared-equal-to-derived-nothing-kept", ln("# R", fence("known_gaps: 3", "gaps_closed: 2"), std, cov("2/3")), nil),
		ss("kg-declared-non-integer-is-seeded", ln("# R", fence("known_gaps: lots", "gaps_closed: -4"), std, cov("2/3")), nil),
		ss("kg-declared-leading-zeros-compare-numerically", ln("# R", fence("known_gaps: 009", "gaps_closed: 007"), std, cov("2/3")), nil),
		ss("kg-only-bypasses-the-declared-keep", ln("# R", fence("known_gaps: 9", "gaps_closed: 8"), std, cov("2/3")), nil, "--sync-state", "--only", "known_gaps,gaps_closed"),
		ss("kg-prose-only-corpus-keeps-prose-counts", ln("# R", cov("5/9"), "## Stop control", "- requires-execution: 2"), nil),
		ss("cov-unrecognised-label-warns", ln("# R", std, "## Coverage", "- see the coverage metric 3/4 in prose"), nil),
		ss("cov-label-with-parenthesised-qualifier", ln("# R", std, "## Coverage", "- **Coverage metric** (issues): 2 / 3"), nil),
	)

	// --- the other derived counters ----------------------------------------------------------------------------
	add(
		ss("req-derived-from-marked-rows", ln("# R", backlog(rowReq, rowReq, rowPending), "## Stop control", "- requires-execution: 9"), nil),
		ss("req-prose-when-no-row-is-marked", ln("# R", backlog(rowPending), "## Stop control", "- Requires-Execution gaps (hw): 4 open"), nil),
		ss("req-falls-back-to-the-envelope", ln("# R", fence("requires_execution_open: 6"), backlog(rowPending)), nil),
		ss("req-nothing-anywhere-is-zero", ln("# R", backlog(rowPending)), nil),
		ss("deferred-counted", ln("# R", backlog(rowDefer, rowDefer, rowPending)), nil),
		ss("blocked-sections-feed-blocked-open", ln("# R", backlog(rowPending), "## Blocked gaps", "- live gap — needs: hw", "- other — needs: x", "- none"), nil),
		ss("blocked-gap-in-backlog-is-not-investigable", ln("# R", backlog(rowPending, rowMedium), "## Blocked gaps", "- live gap — needs: hw"), nil),
		ss("blocked-child-gaps-counted", ln("# R", backlog(rowPending), "## Child gaps surfaced at close", "- C1 x", "  needs: hw", "", "- C2 ~~y~~ needs: a", "- ~~C3~~ needs: b"), nil),
		ss("everything-at-once", ln("# T", bq, fence(stale...), backlog(rowPending, rowMedium, rowReq, rowBlocked, rowDefer, rowDone, "| deferred | G1 | x |"),
			"## Blocked gaps", "- live gap — needs: hw", "## Stop control", "- requires-execution: 3", cov("4/9"), "## Covered blocks", "- B1"), disk),
		ss("undocumented-findings-with-everything", ln("# R", fence(stale...), std, cov("2/3")), nil, "--sync-state", "--only", "undocumented_findings"),
	)

	// --- undocumented_findings -----------------------------------------------------------------------------------
	uf := func(name, line string) s3Scenario {
		return ss("uf-"+name, ln("# R", fence("schema: research-state.v1", line)), nil)
	}
	add(
		ss("uf-first-seed-writes-zero", ln("# R", bq, std), nil),
		ss("uf-absent-in-existing-fence-stays-absent", ln("# R", fence("schema: research-state.v1")), nil),
		uf("valid-carried", "undocumented_findings: 7"),
		uf("no-space-probed", "undocumented_findings:7"),
		uf("indented-probed", "   undocumented_findings: 7"),
		uf("indented-no-space", "\tundocumented_findings:7"),
		uf("unparseable-warns-and-carries", "undocumented_findings: seven"),
		uf("negative-is-unparseable", "undocumented_findings: -1"),
		uf("empty-value-seeds-zero", "undocumented_findings:"),
		uf("blank-value-seeds-zero", "undocumented_findings:    "),
		uf("no-space-unparseable", "undocumented_findings:x1"),
		uf("two-fields-first-wins", "undocumented_findings: 3 4"),
		uf("zero-leading", "undocumented_findings: 007"),
		ss("uf-only-excludes-it-so-declared-stays", ln("# R", fence("undocumented_findings: 5", "known_gaps: 9"), std), nil, "--sync-state", "--only", "known_gaps"),
		ss("uf-only-absent-and-not-named-is-omitted", ln("# R", fence("known_gaps: 9"), std), nil, "--sync-state", "--only", "known_gaps"),
		ss("uf-only-names-it", ln("# R", fence("undocumented_findings: 5"), std), nil, "--sync-state", "--only", "undocumented_findings"),
	)

	// --- --only and the CHANGED lines ---------------------------------------------------------------------------------
	add(
		ss("changed-lists-every-rewrite", ln("# R", fence(stale...), std, cov("2/3")), disk),
		ss("changed-absent-fields", ln("# R", fence("schema: research-state.v1", "covered_blocks: 1"), std, cov("2/3")), nil),
		ss("changed-none-when-equal", ln("# R", fence("covered_blocks: 0", "gaps_closed: 2", "known_gaps: 3", "investigable_open: 2", "requires_execution_open: 0", "blocked_open: 0", "deferred_open: 0", "undocumented_findings: 0"), std, cov("2/3")), nil),
		ss("changed-spacing-differences-are-reported", ln("# R", fence("covered_blocks:    0  ", "gaps_closed: 2", "known_gaps: 3", "investigable_open: 2", "requires_execution_open: 0", "blocked_open: 0", "deferred_open: 0")), nil),
		ss("changed-first-line-wins-for-duplicates", ln("# R", fence("covered_blocks: 4", "covered_blocks: 0")), nil),
		ss("only-one-counter-others-keep-declared", ln("# R", fence(stale...), std, cov("2/3")), disk, "--sync-state", "--only", "covered_blocks"),
		ss("only-two-counters", ln("# R", fence(stale...), std, cov("2/3")), disk, "--sync-state", "--only", "blocked_open,deferred_open"),
		ss("only-absent-field-is-derived", ln("# R", fence("schema: research-state.v1", "known_gaps: 9"), std, cov("2/3")), nil, "--sync-state", "--only", "known_gaps"),
		ss("only-without-a-fence-derives-everything", ln("# R", std, cov("2/3")), disk, "--sync-state", "--only", "known_gaps"),
		ss("only-all-counters-named", ln("# R", fence(stale...), std, cov("2/3")), disk, "--sync-state", "--only", "covered_blocks,gaps_closed,known_gaps,investigable_open,requires_execution_open,blocked_open,deferred_open,undocumented_findings"),
		ss("only-invalid-counter-is-usage", ln("# R", std), nil, "--sync-state", "--only", "nope"),
		ss("only-with-focus", ln("# R", fence(stale...), std), two, "--sync-state", "--focus", "b", "--only", "known_gaps"),
		ss("sync-with-stall-minutes-flag", ln("# R", std), nil, "--sync-state", "--stall-minutes", "5"),
	)
	add(s8aSyncScenarios()...) // the UNMAPPED cases of the bash suites (S8a)
	return scs
}
