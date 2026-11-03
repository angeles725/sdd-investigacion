package reconcile

import (
	"os"
	"path/filepath"
	"strings"
)

// The closed-issue classes (slice 2): --closed-cache, the closure-evidence rule, git reachability, the shallow
// clone and the cross-retro regressed lookup. Every case audits ONE retro against an --issues-cache and a
// --closed-cache, the shape of the bash suite's cases 44 to 46.

const evTest = "Test: research-sdd/toolbelt/tests/x.test.sh\n"

// closedSig is the signature of row id in a closed issue of retro r.md of target-foo.
func closedSig(id string) string { return "Source retro: target-foo/retros/r.md · " + id + "\n" }

// shippedBody is a closed issue for row 1 that carries a commit and a test.
func shippedBody(commit string) string { return closedSig("1") + "Commit: " + commit + "\n" + evTest }

// titledRows renders table rows whose delta cell is the given title (so the row has a cross-retro identity).
func titledRows(pairs ...string) string {
	var sb strings.Builder
	for i := 0; i < len(pairs); i += 2 {
		sb.WriteString("| " + pairs[i] + " | " + pairs[i+1] + " | CLAUDE.md | B1 | fix | HIGH |\n")
	}
	return sb.String()
}

const (
	curRetro   = "2026-01-01-cur.md"
	laterRetro = "2026-02-01-later.md"
	title1     = "Make the closed lookup honest"
)

func curSig(id string) string {
	return "Source retro: target-foo/retros/" + curRetro + " · " + id + "\n"
}

func closedCases() []dcase {
	tbl := pending + tableHead + rowsOf("1", "2")
	c := func(name, closed string, f func(*dcase)) dcase {
		d := dcase{name: "closed/" + name, retro: tbl, cache: sigs("target-foo", "other.md", "7"), closed: closed, useClosed: true, repo: "fix"}
		if f != nil {
			f(&d)
		}
		return d
	}
	var out []dcase
	add := func(name, closed string, f func(*dcase)) { out = append(out, c(name, closed, f)) }

	// The three classes and the evidence rule.
	add("shipped", shippedBody(fixMain), nil)
	add("shipped-evidence-in-comment-lines", closedSig("1")+"Comments:\nthe commit "+fixMain+" landed\ntests/x.sh covers it\n", nil)
	add("borderline-no-commit", closedSig("1")+evTest, nil)
	add("borderline-no-test", closedSig("1")+"Commit: "+fixMain+"\n", nil)
	add("borderline-nothing-cited", closedSig("1"), nil)
	add("borderline-commit-on-side-branch", shippedBody(fixSide), nil)
	add("borderline-commit-absent", shippedBody("0123456789abcdef0123456789abcdef01234567"), nil)
	add("borderline-date-is-not-a-commit", closedSig("1")+"Closed in commit 20261101 with "+evTest, nil)
	add("shipped-one-reachable-among-many", closedSig("1")+"Commits: "+fixSide+" 0123456 "+fixMain+"\n"+evTest, nil)
	add("shipped-reach-is-first-in-sort-order", closedSig("1")+"Commit: "+fixMain+"\nCommit: "+fixMain[:12]+"\n"+evTest, nil)
	add("evidence-commit-needs-a-digit", closedSig("1")+"Commit: abcdefabcdef\n"+evTest, nil)
	add("evidence-commit-length-bounds", closedSig("1")+"Commit: 123456 "+strings.Repeat("1", 41)+"\n"+evTest, nil)
	add("evidence-commit-word-boundaries", closedSig("1")+"recommitted "+fixMain+"\n"+evTest, nil)
	add("evidence-commit-word-uppercase", closedSig("1")+"COMMITS "+strings.ToUpper(fixMain)+"\n"+evTest, nil)
	add("evidence-test-needs-a-path", closedSig("1")+"Commit: "+fixMain+"\nTest: passes\n", nil)
	add("evidence-test-needs-the-word", closedSig("1")+"Commit: "+fixMain+"\nsee contest_x.go\n", nil)
	add("evidence-test-forms", closedSig("1")+"Commit: "+fixMain+"\nTests: pkg/tests/x_test.go\n", nil)
	add("evidence-test-prefix-form", closedSig("1")+"Commit: "+fixMain+"\nTest: test_thing.py\n", nil)
	add("evidence-on-the-signature-line", "Source retro: target-foo/retros/r.md · 1 commit "+fixMain+" test tests/a\n", nil)
	add("both-rows-closed", shippedBody(fixMain)+"\x1e\n"+closedSig("2")+"Commit: "+fixSide+"\n"+evTest, nil)
	add("one-row-shipped-one-borderline-one-untracked", shippedBody(fixMain)+"\x1e\n"+closedSig("2")+evTest, func(d *dcase) {
		d.retro = tbl + rowsOf("3")
	})

	// Closed-cache records: separators, signature splitting, the preamble note, the legacy prefix.
	add("separated-records-evidence-stays-in-its-issue", closedSig("1")+"no evidence here\n\x1e\n"+closedSig("2")+"Commit: "+fixMain+"\n"+evTest, nil)
	add("separated-records-footer-signature", "Commit: "+fixMain+"\n"+evTest+closedSig("1")+"\x1e\n", nil)
	add("unseparated-records-split-by-signature", closedSig("1")+"nothing\n"+closedSig("2")+"Commit: "+fixMain+"\n"+evTest, nil)
	add("unseparated-preamble-is-ignored-and-noted", "stray\nlines\n"+shippedBody(fixMain), nil)
	add("unseparated-preamble-noted-per-row", "stray\n"+closedSig("9"), nil)
	add("two-closed-issues-for-one-row", closedSig("1")+"Commit: "+fixSide+"\n\x1e\n"+closedSig("1")+evTest, nil)
	add("signature-id-prefix-is-not-the-row", closedSig("11")+"Commit: "+fixMain+"\n"+evTest, nil)
	add("signature-other-retro", "Source retro: target-foo/retros/other.md · 1\nCommit: "+fixMain+"\n"+evTest, nil)
	add("signature-other-target", "Source retro: other/retros/r.md · 1\nCommit: "+fixMain+"\n"+evTest, nil)
	add("crlf-closed-cache", strings.ReplaceAll(shippedBody(fixMain), "\n", "\r\n"), nil)
	add("nul-and-trailing-newlines", shippedBody(fixMain)+"\x00\n\n\n", nil)
	add("empty-closed-cache", "", nil)
	add("whitespace-closed-cache", "\n\n", nil)
	add("legacy-prefix-closed-issue", "Source retro: legacy-dir/retros/r.md · 1\nCommit: "+fixMain+"\n"+evTest, func(d *dcase) {
		legacy(d)
	})
	add("legacy-and-registered-closed-issues", "Source retro: legacy-dir/retros/r.md · 1\nCommit: "+fixSide+"\n"+closedSig("1")+"Commit: "+fixMain+"\n"+evTest, func(d *dcase) {
		legacy(d)
	})

	// Which rows reach the closed lookup, and the cache states.
	add("tracked-rows-skip-the-closed-lookup", shippedBody(fixMain), func(d *dcase) { d.cache = sigs("target-foo", "r.md", "1", "2") })
	add("closed-cache-unreadable-all-tracked-is-fine", "", func(d *dcase) {
		d.cache, d.closedMissing = sigs("target-foo", "r.md", "1", "2"), true
	})
	add("closed-cache-missing-is-degraded", "", func(d *dcase) { d.closedMissing = true })
	add("closed-cache-missing-keeps-tracked-lines", "", func(d *dcase) {
		d.closedMissing, d.cache = true, sigs("target-foo", "r.md", "1")
	})
	add("closed-cache-is-a-directory", "", func(d *dcase) {
		d.prep = func(t tb, b *box) { must(t, os.Remove(b.closedArg)); must(t, os.Mkdir(b.closedArg, 0o755)) }
	})
	add("closed-cache-with-orphan-and-no-match", shippedBody(fixMain), func(d *dcase) {
		d.retro, d.cache = tbl[:len(pending+tableHead)]+rowsOf("1"), sigs("target-foo", "r.md", "9")
	})
	add("shipped-only-no-no-match-note", shippedBody(fixMain), func(d *dcase) { d.retro, d.cache = tbl[:len(pending+tableHead)]+rowsOf("1"), "" })
	add("applied-retro-closed-cache-unused", shippedBody(fixMain), func(d *dcase) { d.retro = applied + tableHead + rowsOf("1", "2") })
	add("dismissed-row-is-not-looked-up", shippedBody(fixMain), func(d *dcase) {
		d.retro = "<!-- review-status: PARTIAL shipped: 3; DISMISSED: 1 -->\n# retro\n\n" + tableHead + rowsOf("1", "2", "3")
	})
	add("out-of-scope-marker-skips-the-lookup", shippedBody(fixMain), func(d *dcase) {
		d.retro = "# retro\n\ntext\n\n## Later\n\n<!-- review-status: pending -->\n\n" + tableHead + rowsOf("1")
	})

	// Git reachability and its typed states.
	add("git-dir-is-not-a-repository", shippedBody(fixMain), func(d *dcase) { d.repo = "" })
	add("git-dir-env-points-nowhere", shippedBody(fixMain), func(d *dcase) { d.env = map[string]string{"RECONCILE_ISSUES_GIT_DIR": "@BOX@/no/such/repo"} })
	add("main-ref-unknown", shippedBody(fixMain), func(d *dcase) { d.env = map[string]string{"RECONCILE_ISSUES_MAIN_REF": "refs/remotes/origin/nope"} })
	add("main-ref-override", shippedBody(fixSide), func(d *dcase) { d.env = map[string]string{"RECONCILE_ISSUES_MAIN_REF": "side"} })
	add("main-ref-empty-means-default", shippedBody(fixMain), func(d *dcase) { d.env = map[string]string{"RECONCILE_ISSUES_MAIN_REF": ""} })
	add("git-dir-empty-means-kit-root", shippedBody(fixMain), func(d *dcase) {
		d.repo, d.env = "", map[string]string{"RECONCILE_ISSUES_GIT_DIR": ""}
	})
	add("git-missing", shippedBody(fixMain), func(d *dcase) { d.noGit = true })
	add("git-missing-without-cited-commits-is-silent", closedSig("1")+evTest, func(d *dcase) { d.noGit = true })
	add("git-state-degraded-no-commit-no-probe", closedSig("1"), func(d *dcase) { d.repo = "" })
	add("git-degraded-twice-one-probe", shippedBody(fixMain), func(d *dcase) {
		d.repo = ""
		d.retro = tbl
		d.closed = shippedBody(fixMain) + "\x1e\n" + closedSig("2") + "Commit: " + fixMain + "\n" + evTest
	})

	// Shallow clones (kit issue #1773).
	two := closedSig("1") + "Commit: 10261004 " + fixMain + "\n" + evTest + "\x1e\n" + closedSig("2") + "Commit: 10261004 " + fixMain + "\n" + evTest
	shallowRef := map[string]string{"RECONCILE_ISSUES_MAIN_REF": "origin/side"}
	add("shallow-nothing-resolves", two, func(d *dcase) { d.repo, d.env, d.retro = "shallow", shallowRef, tbl })
	add("shallow-one-row-nothing-resolves-no-sha-token", closedSig("1")+"Commit: 10261004\n"+evTest, func(d *dcase) { d.repo, d.env = "shallow", shallowRef })
	add("shallow-one-cited-commit-resolves", closedSig("1")+"Commit: "+fixMain+" "+fixSide+"\n"+evTest, func(d *dcase) {
		d.repo, d.env = "shallow", shallowRef
	})
	add("shallow-resolved-and-reaches", shippedBody(fixSide), func(d *dcase) { d.repo, d.env = "shallow", shallowRef })
	add("shallow-missing-main-ref-is-degraded", two, func(d *dcase) { d.repo = "shallow" })
	return out
}

// legacy turns a case into the pre-#1286 layout: the registered name differs from the directory name.
func legacy(d *dcase) {
	d.target, d.retroDir = "reg-name", "rh/legacy-dir/retros"
	d.targets = "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `@BOX@/rh/legacy-dir` |\n"
	d.cache = ""
}

// regressedCases cover the cross-retro lookup (kit issue #1709 slice 2).
func regressedCases() []dcase {
	cur := pending + tableHead + titledRows("1", title1, "2", "Another delta with a long title")
	later := func(marker string, rows string) string { return marker + "# later\n\n" + tableHead + rows }
	open := "<!-- review-status: pending -->\n"
	closed := curSig("1") + "Closed-issue-number: 12\nCommit: " + fixMain + "\n" + evTest
	mk := func(name string, f func(*dcase)) dcase {
		d := dcase{
			name: "regressed/" + name, retro: cur, retroFile: curRetro, cache: "", closed: closed, useClosed: true, repo: "fix",
			files: map[string]string{"rh/target-foo/retros/" + laterRetro: later(open, titledRows("5", title1))},
		}
		if f != nil {
			f(&d)
		}
		return d
	}
	var out []dcase
	add := func(name string, f func(*dcase)) { out = append(out, mk(name, f)) }
	file := func(d *dcase, name, content string) { d.files["rh/target-foo/retros/"+name] = content }

	add("reproposed-in-a-later-retro", nil)
	add("reproposed-title-is-compared-exactly", func(d *dcase) { file(d, laterRetro, later(open, titledRows("5", "make the closed lookup honest"))) })
	add("reproposed-bold-title-is-unwrapped", func(d *dcase) { file(d, laterRetro, later(open, titledRows("5", "**"+title1+"**"))) })
	add("not-reproposed-different-title", func(d *dcase) { file(d, laterRetro, later(open, titledRows("5", "A wholly different delta here"))) })
	add("no-later-retro", func(d *dcase) { d.files = map[string]string{} })
	add("earlier-retro-is-not-later", func(d *dcase) {
		d.files = map[string]string{}
		file(d, "2025-01-01-old.md", later(open, titledRows("5", title1)))
	})
	add("two-later-retros-both-reported", func(d *dcase) { file(d, "2026-03-01-third.md", later(open, titledRows("8", title1))) })
	add("later-retro-dismissed-closes-its-rows", func(d *dcase) {
		file(d, laterRetro, later("<!-- review-status: dismissed 2026-02-02 -->\n", titledRows("5", title1)))
	})
	add("later-retro-applied-closes-its-rows", func(d *dcase) {
		file(d, laterRetro, later("<!-- review-status: applied 2026-02-02 -->\n", titledRows("5", title1)))
	})
	add("later-retro-partial-keeps-unlisted-rows-open", func(d *dcase) {
		file(d, laterRetro, later("<!-- review-status: PARTIAL shipped: 4 -->\n", titledRows("4", "Something else entirely here", "5", title1)))
	})
	add("later-retro-partial-shipped-row-is-closed", func(d *dcase) {
		file(d, laterRetro, later("<!-- review-status: PARTIAL shipped: 5 -->\n", titledRows("5", title1)))
	})
	add("later-retro-partial-dismissed-row-is-closed", func(d *dcase) {
		file(d, laterRetro, later("<!-- review-status: PARTIAL shipped: 4; DISMISSED: 5 -->\n", titledRows("5", title1)))
	})
	add("later-retro-marker-out-of-scope", func(d *dcase) {
		file(d, laterRetro, "# later\n\ntext\n\n## Later\n\n<!-- review-status: pending -->\n\n"+tableHead+titledRows("5", title1))
	})
	add("later-retro-unreadable-is-degraded", func(d *dcase) {
		d.prep = func(t tb, b *box) { must(t, os.Chmod(filepath.Join(filepath.Dir(b.retro), laterRetro), 0)) }
	})
	add("later-retros-dir-not-listable-is-degraded", func(d *dcase) {
		d.prep = func(t tb, b *box) {
			dir := filepath.Dir(b.retro)
			must(t, os.Chmod(dir, 0o111))
			t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
		}
	})
	add("same-day-and-undated-siblings-are-noted", func(d *dcase) {
		file(d, "2026-01-01-same.md", later(open, titledRows("5", title1)))
		file(d, "notes.md", later(open, titledRows("5", title1)))
		file(d, "scratch.md", later(open, titledRows("5", title1)))
	})
	add("sibling-that-is-not-markdown-is-ignored", func(d *dcase) { file(d, "2026-03-01-x.txt", later(open, titledRows("5", title1))) })
	add("sibling-directory-named-md-is-ignored", func(d *dcase) {
		d.prep = func(t tb, b *box) {
			must(t, os.Mkdir(filepath.Join(filepath.Dir(b.retro), "2026-04-01-dir.md"), 0o755))
		}
	})
	add("current-retro-undated", func(d *dcase) {
		d.retroFile, d.files = "cur.md", map[string]string{}
		d.closed = strings.ReplaceAll(closed, curRetro, "cur.md")
	})
	add("current-retro-undated-noted-once-for-two-rows", func(d *dcase) {
		d.retroFile, d.files = "cur.md", map[string]string{}
		d.closed = strings.ReplaceAll(closed, curRetro, "cur.md") + "\x1e\n" + strings.ReplaceAll(curSig("2"), curRetro, "cur.md") + "Commit: " + fixMain + "\n" + evTest
	})
	add("short-title-has-no-identity", func(d *dcase) {
		d.retro = pending + tableHead + titledRows("1", "Short one", "2", "Another delta with a long title")
		file(d, laterRetro, later(open, titledRows("5", "Short one")))
	})
	add("bare-priority-token-has-no-identity", func(d *dcase) {
		d.retro = pending + tableHead + titledRows("1", "HIGH", "2", "Another delta with a long title")
		file(d, laterRetro, later(open, titledRows("5", "HIGH")))
	})
	add("closed-issue-numbers-sorted-and-joined", func(d *dcase) {
		d.closed = curSig("1") + "Closed-issue-number: 9\nCommit: " + fixMain + "\n" + evTest + "\x1e\n" +
			curSig("1") + "Closed-issue-number:  12  \nClosed-issue-number: 9\n"
	})
	add("no-issue-numbers-in-the-cache", func(d *dcase) { d.closed = curSig("1") + "Commit: " + fixMain + "\n" + evTest })
	add("borderline-row-is-not-checked-for-regression", func(d *dcase) { d.closed = curSig("1") + "Closed-issue-number: 12\n" + evTest })
	add("title-column-named-by-the-header", func(d *dcase) {
		hdr := "## Proposed kit deltas\n\n| # | Target | Proposed change | Type |\n|---|---|---|---|\n"
		d.retro = pending + hdr + "| 1 | CLAUDE.md | " + title1 + " | fix |\n"
		file(d, laterRetro, open+"# later\n\n"+hdr+"| 5 | OTHER.md | "+title1+" | fix |\n")
	})
	add("entry-form-titles", func(d *dcase) {
		d.retro = pending + "## Proposed kit deltas\n\n### D1 — " + title1 + "\n\nbody\n"
		d.closed = curSig("D1") + "Closed-issue-number: 3\nCommit: " + fixMain + "\n" + evTest
		file(d, laterRetro, open+"# later\n\n## Proposed kit deltas\n\n### D4 — "+title1+"\n")
	})
	add("later-retro-with-unsafe-id-row-is-ignored", func(d *dcase) {
		file(d, laterRetro, later(open, titledRows("5.1", title1)))
	})
	add("later-retro-fenced-table", func(d *dcase) {
		file(d, laterRetro, open+"# later\n\n```\n"+tableHead+titledRows("5", title1)+"```\n")
	})
	add("later-retro-without-delta-section", func(d *dcase) { file(d, laterRetro, open+"# later\n\nnothing\n") })
	return out
}
