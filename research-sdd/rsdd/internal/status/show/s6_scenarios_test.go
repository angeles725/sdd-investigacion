package show

import "fmt"

// The S6 scenario table: full default-report runs. The groups follow the sections of the frozen report
// (status-report.sh) and the readers it calls: the header and coverage lines, the stop-control counters, the
// contradictions ledger, saturation, the Stop hook, the remote-visibility block, the next-step walk and the
// consistency footer. What the children say (gh, verify-state) is stated in the world's spec/ directory (see
// s6_harness_test.go); the campaign block and the document-cycle outline are the script's own (S7 scenarios hold their cases).

// fixedNow is 2026-01-01T00:00:00Z in epoch seconds, the instant the port's test clock also reads.
const fixedNow = "1767225600"

// ws6 is a scenario over a file set whose target and flags are given: the default report, one run.
func ws6(name, want string, f files, env map[string]string, args ...string) s6Scenario {
	clocked := map[string]string{nowEpochHook: fixedNow} // the clock of both sides: the campaign age reads it
	for k, v := range env {
		clocked[k] = v
	}
	sc := m5(name, want, f, clocked)
	sc.runs = [][]string{append([]string{"{ROOT}/corpus"}, args...)}
	return sc
}

// os6 is the one-state-file scenario of the default report.
func os6(name, want, state string, extra files, env map[string]string, args ...string) s6Scenario {
	return ws6(name, want, merge(files{stateRel: state}, extra), env, args...)
}

// st6 is a derived-consistent state: the Stop control section carries inv, tail is appended after it (Coverage,
// Iteration history, blocked sections), rows are the backlog.
func st6(inv int, tail string, rows ...string) string { return st4("", "0", inv, tail, rows...) }

// gitRepo is the smallest repository git accepts, with the given remotes (name, url pairs), under the corpus.
func gitRepo(remotes ...string) files {
	cfg := "[core]\n\trepositoryformatversion = 0\n"
	for i := 0; i+1 < len(remotes); i += 2 {
		cfg += fmt.Sprintf("[remote %q]\n\turl = %s\n", remotes[i], remotes[i+1])
	}
	return files{"corpus/.git/HEAD": "ref: refs/heads/main\n", "corpus/.git/config": cfg, "corpus/.git/objects/": "", "corpus/.git/refs/": ""}
}

func s6Scenarios() []s6Scenario {
	var scs []s6Scenario
	scs = append(scs, s6Header()...)
	scs = append(scs, s6Counters()...)
	scs = append(scs, s6Contra()...)
	scs = append(scs, s6Saturation()...)
	scs = append(scs, s6Visibility()...)
	scs = append(scs, s6NextStep()...)
	scs = append(scs, s6Footer()...)
	return scs
}

const (
	covHdr = "\n## Coverage\n\n"
	hdrOne = "== research-sdd-status: corpus  ·  corpus: (flat) =="
)

func s6Header() []s6Scenario {
	var scs []s6Scenario
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	pend := row("high", "the root gap", "pending")
	base := st6(1, "", pend)
	rel := os6("h-relative-target", hdrOne, base, nil, nil)
	rel.runs = [][]string{{"corpus"}}
	dots := os6("h-dotted-relative-target", "== research-sdd-status: .  ·  corpus: (flat) ==", base, nil, nil)
	dots.runs = [][]string{{"./corpus/../corpus/."}}
	sub := os6("h-relative-target-from-a-subdirectory", hdrOne, base, files{"work/": ""}, nil)
	sub.cwd, sub.runs = "work", [][]string{{"../corpus"}}
	add(
		os6("h-minimal-flat-corpus", hdrOne, base, nil, nil),
		os6("h-stall-minutes-flag-is-accepted", hdrOne, base, nil, nil, "--stall-minutes", "5"),
		rel, dots, sub,
		ws6("h-state-in-a-subdirectory", "corpus: sub ==", files{"corpus/sub/RESEARCH-STATE.md": base}, nil),
		ws6("h-state-two-levels-down", "corpus: a/b ==", files{"corpus/a/b/RESEARCH-STATE.md": base}, nil),
		ws6("h-no-state-file-bootstraps", "no RESEARCH-STATE under", files{"corpus/notes.md": "x\n"}, nil),
	)

	cov := func(lines ...string) string { return st6(1, covHdr+ln(lines...), pend) }
	add(
		os6("h-coverage-metric-and-blocks", "  coverage metric : 5/8", cov("- Coverage metric: 5/8", "- Covered blocks: 5 claimed"), nil, nil),
		os6("h-coverage-metric-spaces-removed", "  coverage metric : 5/8", cov("- Coverage metric: 5 / 8"), nil, nil),
		os6("h-coverage-no-section", "  coverage metric : <none>", base, nil, nil),
		os6("h-coverage-section-without-the-lines", "  covered blocks  : <none> claimed", cov("nothing here"), nil, nil),
		os6("h-covered-blocks-number-at-the-start-of-the-line", "  covered blocks  : 7 claimed", cov("7 covered blocks"), nil, nil),
		os6("h-covered-blocks-case-insensitive", "  covered blocks  : 12 claimed", cov("COVERED BLOCKS: 12 of 20"), nil, nil),
		os6("h-covered-blocks-first-number", "  covered blocks  : 1 claimed", cov("Covered blocks (B1-B9): 7 claimed, 9 total"), nil, nil),
		os6("h-covered-blocks-first-line-without-digits", "  covered blocks  : 4 claimed", cov("Covered blocks: none yet", "covered blocks again: 4"), nil, nil),
		os6("h-covered-blocks-outside-the-section-is-ignored", "  covered blocks  : <none> claimed", st6(1, "\n## Notes\n\ncovered blocks: 9\n"+covHdr+"x\n", pend), nil, nil),
		os6("h-unrecognised-coverage-label-warns", "  coverage metric : <none>", cov("see the coverage metric 3/4 below"), nil, nil),
		os6("h-recognised-label-silences-the-warning", "  coverage metric : 3/4", cov("coverage metric is 1/2 soon", "Coverage metric: 3/4"), nil, nil),
	)
	blocks := func(prefix string, lo, hi int) files { return nblk("a-"+prefix, lo, hi) }
	add(
		os6("h-on-disk-counts-every-block-file", "· 3 on disk", base, blocks("", 1, 3), nil),
		os6("h-on-disk-ignores-other-files", "· 2 on disk", base, merge(blocks("", 1, 2), files{"corpus/notes.md": "x\n", "corpus/a-block9.txt": "x\n"}), nil),
		os6("h-on-disk-none", "· 0 on disk", base, nil, nil),
		os6("h-on-disk-with-a-prefix", "· 2 on disk", base, merge(blocks("r-", 1, 2), blocks("x-", 1, 4), files{"corpus/FOCUSES.md": fcHeader + fcRoot("a-r-", "")}), nil),
		os6("h-on-disk-with-a-range", "· 3 on disk", base, merge(blocks("", 1, 6), files{"corpus/FOCUSES.md": fcHeader + fcRoot("", "B2–B4")}), nil),
		os6("h-on-disk-range-ignores-a-sibling-claim", "· 2 on disk", base, merge(blocks("", 1, 6), files{"corpus/FOCUSES.md": fcHeader + fcRoot("", "B1–B4") + fcRow("sib", "", "B3–B9")}), nil),
		os6("h-on-disk-malformed-range-counts-everything", "· 6 on disk", base, merge(blocks("", 1, 6), files{"corpus/FOCUSES.md": fcHeader + fcRoot("", "B4–B2")}), nil),
		os6("h-on-disk-bad-prefix-regex", "on disk", base, merge(blocks("", 1, 2), files{"corpus/FOCUSES.md": fcHeader + fcRoot("(r-", "")}), nil),
		os6("h-on-disk-range-cell-elsewhere-warns", "on disk", base, merge(blocks("", 1, 6), files{"corpus/FOCUSES.md": "| Focus | Status | State | Block prefix | Blocks | Note |\n|---|---|---|---|---|---|\n| (root) | open | `RESEARCH-STATE.md` |  | n/a | B2–B3 |\n"}), nil),
	)
	return scs
}

func s6Counters() []s6Scenario {
	var scs []s6Scenario
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	rows := []string{
		row("high", "H1 a", "pending"), row("high", "H2 b", "**pending**"), row("medium", "M1 c", "pending"),
		row("low", "L1 d", "pending (note)"), row("low", "~~L2 struck~~", "pending"), row("low", "L3 done", "✅ covered"),
	}
	add(
		os6("k-pending-by-priority", "  pending backlog : high=2 medium=1 low=0", st6(-1, "", rows...), nil, nil),
		os6("k-pending-none", "  pending backlog : high=0 medium=0 low=0", st6(0, "", row("high", "H1 a", "✅ covered")), nil, nil),
		os6("k-pending-unknown-priority-counts-nowhere", "  pending backlog : high=0 medium=0 low=1", st6(1, "", row("SES2", "S1 x", "pending"), row("low", "L1", "pending")), nil, nil),
		os6("k-pending-low-only", "  pending backlog : high=0 medium=0 low=2", st6(2, "", row("low", "L1", "pending"), row("low", "L2", "pending")), nil, nil),
		os6("k-pending-with-an-unclosed-bold-mark-counts", "  pending backlog : high=1 medium=0 low=0", st6(1, "", row("high", "H1", "**pending")), nil, nil),
		os6("k-pending-with-a-trailing-bold-mark-counts", "  pending backlog : high=1 medium=0 low=0", st6(1, "", row("high", "H1", "pending**")), nil, nil),
		os6("k-stop-control-counts", "investigable=1 · requires-execution=0 · blocked=0", st6(1, "", row("high", "H1", "pending")), nil, nil),
		os6("k-stop-control-without-the-section", "investigable=? · requires-execution=? · blocked=0", ln("# S", "", "## Gap-backlog (prioritized)", h4, row("high", "H1", "pending")), nil, nil),
		os6("k-requires-execution-prose", "requires-execution=3", ln("# S", "", "## Stop control", "", "- Open gaps — read-only investigable: 2", "- Open gaps — requires-execution: 3 (of which 1 hw)", "- blocked: 0"), nil, nil),
		os6("k-investigable-first-matching-line-with-digits", "investigable=4 ·", ln("# S", "", "## Stop control", "", "- read-only investigable: none yet", "- Read-Only Investigable: 4"), nil, nil),
		os6("k-blocked-open-from-needs-bullets", "blocked=2", st6(0, blockHdr+"- G1 — needs: hw\n- G2 — needs: vpn\n", row("high", "G1", "pending")), nil, nil),
		os6("k-blocked-open-child-gaps", "blocked=1", st6(0, "\n## Child gaps surfaced at close\n- C1 x\n  needs: hw\n"), nil, nil),
		os6("k-retyped-visible", "  re-typed in table : 1 — row(s) carry the literal 're-typed' Status", st6(1, "", row("high", "H1", "re-typed"), row("low", "L1", "pending")), nil, nil),
		os6("k-retyped-both-spellings-counted", "  re-typed in table : 2 —", st6(0, "", row("high", "H1", "retyped (x)"), row("low", "L1", "**re-typed** note"), row("low", "~~L2~~", "re-typed")), nil, nil),
		os6("k-retyped-absent-prints-nothing", hdrOne, st6(1, "", row("high", "H1", "pending")), nil, nil),
		os6("k-unknown-priority-warns-on-stderr", "  pending backlog", st6(0, "", row("SES2", "S1 x", "pending")), nil, nil),
	)
	unreadable := os6("k-state-file-unreadable", "degraded: blocked_open: blocked_open_count rc 2", st6(1, "", row("high", "H1", "pending")), nil, nil)
	unreadable.unreadable, unreadable.needsUser = []string{stateRel}, true
	add(unreadable)
	return scs
}

// contraLedger builds a CONTRADICTIONS ledger with the given rows.
func contraLedger(rows ...string) string {
	return ln(append([]string{"# Contradictions", "", "| id | claim A | claim B | status | note |", "|---|---|---|---|---|"}, rows...)...)
}

func s6Contra() []s6Scenario {
	var scs []s6Scenario
	add := func(s ...s6Scenario) { scs = append(scs, s...) }
	base := st6(1, "", row("high", "H1", "pending"))
	led := func(name, want string, ledgers files, env map[string]string) s6Scenario {
		return os6(name, want, base, ledgers, env)
	}
	one := func(rows ...string) files { return files{"corpus/CONTRADICTIONS.md": contraLedger(rows...)} }
	add(
		led("x-no-ledger", "  contradictions  : (no ledger)", nil, nil),
		led("x-ledger-without-rows", "  contradictions  : (none)", one(), nil),
		led("x-ledger-counts-open-rows", "  contradictions  : 2 open", one("| C1 | a | b | open | n |", "| C2 | a | b | resolved | n |", "| C3 | a | b | open | n |"), nil),
		led("x-open-is-case-insensitive-and-trimmed", "  contradictions  : 3 open", one("| C1 | a | b |  OPEN  | n |", "| C2 | a | b | Open | n |", "| C3 | a | b |\topen\t| n |"), nil),
		led("x-open-only-in-the-status-cell", "  contradictions  : (none)", one("| open | open | open | closed | open |", "| C2 | a | b | open? | open |"), nil),
		led("x-a-header-whose-fourth-cell-says-open-counts", "  contradictions  : 1 open", files{"corpus/CONTRADICTIONS.md": "| id | claim A | claim B | open | note |\n|---|---|---|---|---|\n"}, nil),
		led("x-four-cells-without-trailing-pipe", "  contradictions  : 1 open", one("| C1 | a | b | open"), nil),
		led("x-no-leading-pipe", "  contradictions  : 1 open", one("C1 | a | b | open | n"), nil),
		led("x-three-cells-are-too-few", "  contradictions  : (none)", one("| C1 | a | open |"), nil),
		led("x-escaped-pipe-stays-in-its-cell", "  contradictions  : (none)", one(`| C1 | a \| b | c | resolved \| open | n |`), nil),
		led("x-escaped-pipe-shifts-no-columns", "  contradictions  : 1 open", one(`| C1 | a \| b | c | open | n |`), nil),
		led("x-open-with-an-escaped-pipe-is-not-open", "  contradictions  : (none)", one(`| C1 | a | b | open \| x | n |`), nil),
		led("x-non-table-lines-are-ignored", "  contradictions  : 1 open", files{"corpus/CONTRADICTIONS.md": "open open open open\n| C1 | a | b | open | n |\nprose with | one pipe\n"}, nil),
		led("x-crlf-after-the-last-pipe-is-a-cell-of-its-own", "  contradictions  : 1 open", files{"corpus/CONTRADICTIONS.md": "| C1 | a | b | open |\r\n"}, nil),
		led("x-last-line-without-newline", "  contradictions  : 1 open", files{"corpus/CONTRADICTIONS.md": "| C1 | a | b | open | n |"}, nil),
		led("x-two-ledgers-counted-together", "  contradictions  : 3 open", merge(one("| C1 | a | b | open | n |"), files{"corpus/CONTRADICTIONS-extra.md": contraLedger("| C2 | a | b | open | n |", "| C3 | a | b | open | n |")}), nil),
		led("x-two-ledgers-warn", "  contradictions  : (none)", merge(one(), files{"corpus/CONTRADICTIONS-b.md": contraLedger()}), nil),
		led("x-three-ledgers-warn-with-their-number", "  contradictions  : 1 open", merge(one(), files{"corpus/CONTRADICTIONS-b.md": contraLedger(), "corpus/CONTRADICTIONS-c.md": contraLedger("| C1 | a | b | open | n |")}), nil),
		led("x-ledger-name-is-case-sensitive", "  contradictions  : (no ledger)", files{"corpus/contradictions.md": contraLedger("| C1 | a | b | open | n |")}, nil),
		led("x-ledger-needs-the-md-suffix", "  contradictions  : (no ledger)", files{"corpus/CONTRADICTIONS.txt": contraLedger("| C1 | a | b | open | n |")}, nil),
		led("x-ledger-in-a-subdirectory-is-not-read", "  contradictions  : (no ledger)", files{"corpus/sub/CONTRADICTIONS.md": contraLedger("| C1 | a | b | open | n |")}, nil),
		led("x-ledger-that-is-a-directory", "  contradictions  : (none)", files{"corpus/CONTRADICTIONS-d.md/": ""}, nil),
		led("x-ledger-that-is-empty", "  contradictions  : (none)", files{"corpus/CONTRADICTIONS.md": ""}, nil),
	)
	return scs
}
