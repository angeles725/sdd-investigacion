package verifyretro

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The case table. Every case runs through the frozen legacy script (differential_test.go, recorded into
// testdata/golden/cases.json) and through the port (golden_test.go replays it without bash).

const (
	cHdr     = "# Retro — T · F · 2026-01-01 · Research-SDD self-retrospective\n"
	cMark    = "<!-- review-status: pending -->\n"
	cHead    = "| # | Proposed change | Target (file · §/section) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n"
	cRow     = "| 1 | c | t | e | x | HIGH |\n"
	cCanon   = "## Proposed kit deltas\n\n"
	cHonest  = "\n## Honest verdict\n\nno new deltas; the kit already covers this run.\n"
	cTable   = cCanon + cHead + cRow
	cConform = cMark + cHdr + "\n" + cTable
)

func cat(parts ...string) string { return strings.Join(parts, "") }

// fixtureCases are the 16 retros of the old bash suite (testdata/fixtures, byte copies).
func fixtureCases() []dcase {
	names, err := filepath.Glob("testdata/fixtures/*.md")
	if err != nil || len(names) == 0 {
		panic("verifyretro: no fixtures under testdata/fixtures")
	}
	var out []dcase
	for _, n := range names {
		data, err := os.ReadFile(n)
		if err != nil {
			panic(err)
		}
		out = append(out, dcase{name: "fixture/" + strings.TrimSuffix(filepath.Base(n), ".md"), retro: string(data)})
	}
	return out
}

func inputCases() []dcase {
	return []dcase{
		{name: "args/none", args: []string{}},
		{name: "args/two", args: []string{"@RETRO@", "@RETRO@"}},
		{name: "args/empty-string", args: []string{""}},
		{name: "args/absent-file", noRetro: true},
		{name: "args/directory-named-md", args: []string{"@BOX@/dir.md"}, noRetro: true, prep: func(t *testing.T, b *box) { mustMkdir(t, filepath.Join(b.root, "dir.md")) }},
		{name: "args/not-md-existing", args: []string{"@BOX@/notes.txt"}, prep: func(t *testing.T, b *box) { mustWrite(t, filepath.Join(b.root, "notes.txt"), cConform) }},
		{name: "args/not-md-absent", args: []string{"@BOX@/absent.txt"}},
		{name: "args/dot-md-name", file: ".md", retro: cConform},
		{name: "args/md-suffix-not-extension", args: []string{"@BOX@/r.mdx"}, prep: func(t *testing.T, b *box) { mustWrite(t, filepath.Join(b.root, "r.mdx"), cConform) }},
		{name: "args/md-without-dot", file: "rmd", retro: cConform},
		{name: "args/relative-unclosed-fence", file: "f.md", rel: true, retro: cat(cConform, "\n```\nstray\n")},
		{name: "args/help-flag", args: []string{"--help"}},
		{name: "args/relative", retro: cConform, rel: true},
		{name: "args/relative-absent", noRetro: true, args: []string{"nope.md"}},
		{name: "args/dotdot", retro: cConform, args: []string{"../rh/retros/r.md"}},
		{name: "args/symlink", retro: cConform, args: []string{"@BOX@/link.md"}, prep: func(t *testing.T, b *box) {
			if err := os.Symlink(b.retro, filepath.Join(b.root, "link.md")); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "args/dangling-symlink", retro: cConform, args: []string{"@BOX@/dangling.md"}, prep: func(t *testing.T, b *box) {
			if err := os.Symlink(filepath.Join(b.root, "gone.md"), filepath.Join(b.root, "dangling.md")); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "args/dotdot-through-symlink", retro: cConform, args: []string{"@BOX@/sub/../r.md"}, prep: func(t *testing.T, b *box) {
			// sub is a symlink to rh/retros: "sub/.." is rh, so rh/r.md is absent although a lexical clean finds @BOX@/r.md.
			if err := os.Symlink(filepath.Join(b.root, "rh", "retros"), filepath.Join(b.root, "sub")); err != nil {
				t.Fatal(err)
			}
			mustWrite(t, filepath.Join(b.root, "r.md"), cConform)
		}},
		{name: "args/unreadable", retro: cConform, prep: func(t *testing.T, b *box) {
			if os.Geteuid() == 0 {
				t.Skip("root reads a mode-000 file; the unreadable branch cannot be reached")
			}
			if err := os.Chmod(b.retro, 0); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "args/not-md-and-unreadable-is-not-md", file: "x.txt", retro: cConform, prep: func(t *testing.T, b *box) {
			if os.Geteuid() == 0 {
				t.Skip("root reads a mode-000 file")
			}
			if err := os.Chmod(b.retro, 0); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "file/empty", retro: ""},
		{name: "file/no-trailing-newline", retro: strings.TrimSuffix(cConform, "\n")},
		{name: "file/crlf", retro: strings.ReplaceAll(cConform, "\n", "\r\n")},
		{name: "file/crlf-honesty", retro: strings.ReplaceAll(cat(cMark, cHdr, cCanon, cHead, cHonest), "\n", "\r\n")},
	}
}

func markerCases() []dcase {
	body := cat(cHdr, "\n", cTable)
	m := func(name, lead string) dcase { return dcase{name: "marker/" + name, retro: cat(lead, body)} }
	return []dcase{
		m("pending", "<!-- review-status: pending -->\n"),
		m("applied", "<!-- review-status: applied -->\n"),
		m("dismissed", "<!-- review-status: dismissed -->\n"),
		m("uppercase-word", "<!-- review-status: PENDING -->\n"),
		m("mixed-case-keyword", "<!-- Review-Status: Applied -->\n"),
		m("a-and-z-word", "<!-- review-status: AzZa -->\n"),
		m("unknown-word", "<!-- review-status: draft -->\n"),
		m("word-with-suffix", "<!-- review-status: pending-review -->\n"),
		m("word-glued-to-digits", "<!-- review-status: pending2 -->\n"),
		m("digits-only", "<!-- review-status: 123 -->\n"),
		m("no-word", "<!-- review-status: -->\n"),
		m("no-spaces", "<!--review-status:pending-->\n"),
		m("tabs", "<!--\treview-status:\tapplied -->\n"),
		m("indented", "   <!-- review-status: pending -->\n"),
		m("tab-indented", "\t<!-- review-status: pending -->\n"),
		m("absent", ""),
		m("blank-line-before", "\n<!-- review-status: pending -->\n"),
		m("blank-line-between-comments", "<!-- a -->\n\n<!-- review-status: pending -->\n"),
		m("second-comment-line", "<!-- note -->\n<!-- review-status: dismissed -->\n"),
		m("two-markers-first-wins", "<!-- review-status: applied -->\n<!-- review-status: pending -->\n"),
		m("two-markers-one-line", "<!-- review-status: applied --><!-- review-status: pending -->\n"),
		m("first-unrecognised-second-valid", "<!-- review-status: nope -->\n<!-- review-status: pending -->\n"),
		m("after-text-line", "text\n<!-- review-status: pending -->\n"),
		m("after-h1", "# Title\n<!-- review-status: pending -->\n"),
		m("bare-no-comment", "review-status: pending\n"),
		m("bom-marker", "\xef\xbb\xbf<!-- review-status: pending -->\n"),
		m("bom-then-exclude", "\xef\xbb\xbf<!-- kit-retro: exclude -->\n"),
		m("crlf-marker", "<!-- review-status: pending -->\r\n"),
		m("marker-with-trailing-text", "<!-- review-status: pending --> trailing\n"),
		m("marker-text-before-on-line", "<!-- x --> <!-- review-status: pending -->\n"),
		m("multi-line-comment-open", "<!-- review-status: pending\n-->\n"),
		m("marker-in-body-only", "<!-- plain -->\n\n## Notes\n<!-- review-status: pending -->\n"),
		{name: "marker/kelvin-sign-is-not-k", retro: "<!-- \u212Ait-retro: exclude -->\n"},
		{name: "marker/dotted-capital-i-is-not-i", retro: "<!-- k\u0130t-retro: exclude -->\n"},
		{name: "marker/exclude", retro: cat("<!-- kit-retro: exclude -->\n", "no headings at all\n")},
		{name: "marker/exclude-uppercase", retro: "<!-- KIT-RETRO: EXCLUDE -->\n"},
		{name: "marker/exclude-spaceless", retro: "<!--kit-retro:exclude-->\n"},
		{name: "marker/exclude-trailing-text", retro: "<!-- kit-retro: exclude --> and more\n"},
		{name: "marker/exclude-indented", retro: "  <!-- kit-retro: exclude -->\n"},
		{name: "marker/exclude-second-line", retro: "<!-- note -->\n<!-- kit-retro: exclude -->\n"},
		{name: "marker/exclude-after-text", retro: "text\n<!-- kit-retro: exclude -->\n"},
		{name: "marker/exclude-mid-line", retro: "<!-- note --> <!-- kit-retro: exclude -->\n"},
		{name: "marker/exclude-with-extra-words", retro: "<!-- kit-retro: exclude now -->\n"},
		{name: "marker/exclude-and-status", retro: cat("<!-- kit-retro: exclude -->\n<!-- review-status: pending -->\n", body)},
		{name: "marker/exclude-and-bad-status", retro: cat("<!-- kit-retro: exclude -->\n<!-- review-status: nope -->\n", body)},
		{name: "marker/exclude-unclosed-fence-silent", retro: "<!-- kit-retro: exclude -->\n```\nopen\n"},
		{name: "marker/empty-file-is-missing", retro: ""},
	}
}

func headerCases() []dcase {
	h := func(name, title string) dcase {
		return dcase{name: "header/" + name, retro: cat(cMark, title, "\n", cTable)}
	}
	return []dcase{
		h("emdash", "# Retro — x\n"),
		h("hyphen", "# Retro - x\n"),
		h("none", "# Something else\n"),
		h("lowercase", "# retro — x\n"),
		h("no-space-after-hash", "#Retro — x\n"),
		h("h2", "## Retro — x\n"),
		h("indented", " # Retro — x\n"),
		h("endash", "# Retro – x\n"),
		h("bare-title-word", "# Retro\n"),
		h("emdash-no-trailing-text", "# Retro —\n"),
		h("hyphen-no-trailing-text", "# Retro -\n"),
		h("both-forms-emdash-wins", "# Retro - x\n# Retro — y\n"),
		h("both-forms-reversed", "# Retro — y\n# Retro - x\n"),
		h("in-fence", "```\n# Retro — x\n```\n"),
		h("hyphen-in-fence", "```\n# Retro - x\n```\n"),
		h("late-in-file", "text\n\ntext\n# Retro — x\n"),
		{name: "header/with-bom", retro: cat("\xef\xbb\xbf", cMark, cHdr, cTable)},
		{name: "header/crlf-hyphen", retro: strings.ReplaceAll(cat(cMark, "# Retro - x\n", cTable), "\n", "\r\n")},
		{name: "header/missing-and-marker-missing", retro: cat("# nope\n\n", cTable)},
	}
}

func deltaCases() []dcase {
	base := cat(cMark, cHdr, "\n")
	d := func(name, rest string) dcase { return dcase{name: "delta/" + name, retro: cat(base, rest)} }
	return []dcase{
		d("table-one-row", cTable),
		d("table-two-rows", cat(cTable, "| 2 | c | t | e | x | LOW |\n")),
		d("table-header-only", cat(cCanon, cHead)),
		d("table-header-only-honesty", cat(cCanon, cHead, cHonest)),
		d("no-table-no-honesty", cCanon),
		d("no-table-honesty-in-section", cat(cCanon, "no new deltas; the kit already covers this run.\n")),
		d("honesty-under-honest-verdict", cat("## Summary\n\nx\n", cHonest)),
		d("honesty-emdash", "## Honest verdict\n\nNo new deltas — the kit already covers this run.\n"),
		d("honesty-nothing-to-add", "## Honest verdict\n\nno new deltas; nothing to add.\n"),
		d("honesty-uppercase-mention-impure", cat(cCanon, cHead, "\nNO NEW DELTAS in prose\n")),
		d("honesty-phrase-in-notes-only", cat(cCanon, cHead, "\n## Notes\n\nno new deltas; the kit already covers this run.\n")),
		d("mention-with-table-conforming", cat(cTable, "\nno new deltas here either\n")),
		d("entries-form", cat(cCanon, "### D1 — first\n\nbody\n\n### D2 — second\n\nbody\n")),
		d("entries-form-honesty", cat(cCanon, "### D1 — first\n\nbody\n", cHonest)),
		d("entries-h3-without-emdash", cat(cCanon, "### D1 - first\n\nbody\n")),
		d("deprecated-heading-rows", cat("## Proposed deltas\n\n", cHead, cRow)),
		d("deprecated-heading-no-rows", "## Proposed deltas\n\n"),
		d("deprecated-heading-honesty", cat("## Proposed deltas\n\n", cHead, cHonest)),
		d("deprecated-then-canonical", cat("## Proposed deltas\n\n", cHead, cRow, "\n", cTable)),
		d("unrecognised-with-rows", cat("## Consolidated kit deltas by file\n\n", cHead, cRow)),
		d("unrecognised-no-rows", "## Consolidated kit deltas by file\n\ntext\n"),
		d("unrecognised-header-only", cat("## Consolidated kit deltas by file\n\n", cHead)),
		d("unrecognised-no-rows-honesty", cat("## Consolidated kit deltas by file\n\ntext\n", cHonest)),
		d("unrecognised-rows-honesty", cat("## Consolidated kit deltas by file\n\n", cHead, cRow, cHonest)),
		d("unrecognised-then-canonical", cat("## Consolidated kit deltas by file\n\n", cHead, cRow, "\n", cTable)),
		d("unrecognised-h3-proposals", "### Proposals\n\n- idea\n"),
		d("unrecognised-heading-trailing-space", "## Consolidated kit deltas by file  \n\ntext\n"),
		d("unrecognised-heading-percent-and-ctrl", "## Consolidated kit deltas by file 100% \x01 x\n\ntext\n"),
		d("h2-delta-headings", "## Delta D1 — first\n\nbody\n\n## Delta D2 — second\n\nbody\n"),
		d("absent", "## Notes\n\nnothing\n"),
		d("absent-empty-body", ""),
		d("canonical-in-fence-is-absent", "```\n## Proposed kit deltas\n| # | a |\n|---|---|\n| 1 | b |\n```\n"),
		d("unclosed-fence-before-table", cat("```\nexample\n\n", cTable)),
		d("unclosed-fence-conforming", cat(cTable, "\n```\nstray\n")),
		d("closed-fence-then-table", cat("```\nx\n```\n\n", cTable)),
		d("dirty-lead-block", cat(cCanon, "> - add X\n\n", cHead, "\n## Honest verdict\n\nno new deltas; the kit already covers this run.\n")),
		d("table-after-other-section", cat("## Other\n\n", cHead, cRow, "\n", cCanon)),
		d("canonical-heading-uppercase", cat("## PROPOSED KIT DELTAS\n\n", cHead, cRow)),
		{name: "delta/marker-pending-everything-wrong", retro: "no marker, no title, no delta\n"},
		{name: "delta/marker-bad-title-hyphen-empty-section", retro: cat("<!-- review-status: nope -->\n# Retro - x\n\n", cCanon)},
		{name: "delta/all-defects-with-unclosed-fence", retro: cat("text\n```\n\n", cCanon)},
		{name: "delta/crlf-table", retro: strings.ReplaceAll(cConform, "\n", "\r\n")},
		{name: "delta/crlf-unrecognised", retro: strings.ReplaceAll(cat(cMark, cHdr, "## Consolidated kit deltas by file\n\ntext\n"), "\n", "\r\n")},
	}
}

func allCases() []dcase {
	var all []dcase
	all = append(all, fixtureCases()...)
	all = append(all, inputCases()...)
	all = append(all, markerCases()...)
	all = append(all, headerCases()...)
	all = append(all, deltaCases()...)
	return all
}
