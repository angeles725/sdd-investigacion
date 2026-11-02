package stageissues

import (
	"os"
	"path/filepath"
	"testing"
)

// casesInput: argument handling, absent/unreadable/empty input (old suite 1, 82, 2).
func casesInput() []dcase {
	one := doc(pending, row("1", "first delta of the retro", "CLAUDE.md", "B1", "new", "HIGH"))
	return []dcase{
		{name: "input/absent-file", noRetro: true},
		{name: "input/no-args", raw: []string{}},
		{name: "input/empty-arg", raw: []string{""}},
		{name: "input/directory", raw: []string{"@BOX@/rh"}},
		{name: "input/apply-first-arg", raw: []string{"--apply"}},
		{name: "input/apply-only-no-retro-gh-ok", raw: []string{"--apply"}, env: map[string]string{"STUB_MODE": "nomatch"}},
		dry("input/extra-args-ignored", one).withArgs("extra", "--bogus"),
		{name: "input/relative-path", retro: one, cwd: "rh/target-foo/retros", raw: []string{"r.md"}},
		{name: "input/relative-dotdot", retro: one, raw: []string{"../rh/target-foo/retros/r.md"}},
		{name: "input/root-parent-dir", retro: one, cwd: "rh/target-foo/retros", raw: []string{"./r.md"}},
		dry("input/zero-byte-file", ""),
		dry("input/no-delta-section", "# retro\n\nNo proposed deltas here.\n"),
		{name: "input/unreadable", retro: one, prep: func(t *testing.T, b *box) {
			if os.Geteuid() == 0 {
				t.Skip("root reads a mode-000 file; the unreadable branch cannot be reached")
			}
			if err := os.Chmod(b.retro, 0); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "input/symlinked-retro", retro: one, prep: func(t *testing.T, b *box) {
			link := filepath.Join(b.root, "rh", "target-foo", "retros", "link.md")
			if err := os.Symlink(b.retro, link); err != nil {
				t.Fatal(err)
			}
			b.retro = link
		}},
	}
}

const (
	partialMarker   = "<!-- review-status: applied · abc123 · PARTIAL — shipped: 1; deferred: 2 -->"
	dismissedMarker = "<!-- review-status: dismissed · abc123 -->"
)

func threeRows() []string {
	return []string{
		row("1", "first delta of the retro", "CLAUDE.md", "B1", "new", "HIGH"),
		row("2", "second delta of the retro", "METHODOLOGY.md", "B2", "fix", "MEDIUM"),
		row("3", "third delta of the retro", "toolbelt/x.sh", "B3", "doc", "LOW"),
	}
}

// casesStatus: the review-status marker states (old suite 3, 5, 17, 18, 47-51, 77).
func casesStatus() []dcase {
	rows := threeRows()
	return []dcase{
		dry("status/pending", doc(pending, rows...)),
		dry("status/none-marker", doc("", rows...)),
		dry("status/none-word", doc("<!-- review-status: none -->", rows...)),
		dry("status/applied-no-match", doc(applied, rows...)),
		dry("status/dismissed-no-match", doc(dismissedMarker, rows...)),
		dry("status/unknown-word", doc("<!-- review-status: bogus -->", rows...)),
		dry("status/partial-shipped-1", doc(partialMarker, rows...)),
		dry("status/partial-all-shipped", doc("<!-- review-status: applied · abc · PARTIAL — shipped: 1, 2, 3 -->", rows...)),
		dry("status/partial-hash-format", doc("<!-- review-status: applied · abc · PARTIAL — shipped: #1 (desc), 2 (x); deferred: 3 -->", rows...)),
		dry("status/partial-range", doc("<!-- review-status: applied · abc · PARTIAL — shipped: 1-2 -->", rows...)),
		dry("status/partial-no-shipped-list", doc("<!-- review-status: applied · abc · PARTIAL — nothing shipped yet -->", rows...)),
		dry("status/partial-dismissed-list", doc("<!-- review-status: applied · abc · PARTIAL — shipped: 1; DISMISSED: 2 -->", rows...)),
		dry("status/partial-dismissed-malformed", doc("<!-- review-status: applied · abc · PARTIAL — shipped: 1; DISMISSED: (none) -->", rows...)),
		dry("status/partial-all-dismissed-or-shipped", doc("<!-- review-status: applied · abc · PARTIAL — shipped: 1; DISMISSED: 2, 3 -->", rows...)),
		dry("status/dismissed-prose-partial", doc("<!-- review-status: dismissed · abc · partial overlap with kit v0.2 -->", rows...)),
		dry("status/applied-free-text-partial", doc("<!-- review-status: applied · abc · covers the partial rewrite -->", rows...)),
		dry("status/marker-after-h1", "# Retro title\n\n"+applied+"\n\n## Proposed kit deltas\n\n"+tblHdr+rows[0]+"\n"),
		dry("status/marker-deep-out-of-scope", "# retro\n\n## Some section\n\ntext\n\n## Another\n\n"+applied+"\n\n## Proposed kit deltas\n\n"+tblHdr+rows[0]+"\n"),
		dry("status/marker-inside-fence", "# retro\n\n```\n"+applied+"\n```\n\n## Proposed kit deltas\n\n"+tblHdr+rows[0]+"\n"),
		// out-of-scope marker at the list edges and behind fences (old suite 17fence-1/2, 17c-1..4; kit issues #949, #1099, #1304)
		dry("status/oos-after-tilde-fence-holding-backticks", "# §18 Retro — focus: apis\n\n## Notes\n\n~~~\n```\n~~~\n\n"+"<!-- review-status: applied 2026-09-20 · kit ad87c33 -->"+"\n\n"+"## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |\n"),
		dry("status/oos-after-unclosed-fence", "# §18 Retro — focus: apis\n\n## Notes\n\n```\nstray opener, never closed\n\n"+"<!-- review-status: applied 2026-09-20 · kit ad87c33 -->"+"\n\n"+"## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |\n"),
		dry("status/oos-after-yaml-frontmatter", "---\ntitle: x\n---\n\n"+"<!-- review-status: applied 2026-09-20 · kit ad87c33 -->"+"\n\n"+"## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |\n"),
		dry("status/oos-middle-narrative", "# §18 Retro — focus: apis\n\n## Background\n\nSome long narrative paragraph explaining\nwhat happened across several lines of prose\nso the marker below sits well past line 1.\n\n"+"<!-- review-status: applied 2026-09-20 · kit ad87c33 -->"+"\n\n## More notes\n\nEven more narrative content follows the marker,\nso it is not the last line of the file either.\n\n"+"## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |\n"),
		dry("status/oos-last-line-no-newline", "# §18 Retro — focus: apis\n\n## Notes\n\n"+"<!-- review-status: applied 2026-09-20 · kit ad87c33 -->"),
		dry("status/oos-single-row", "## Notes\n"+"<!-- review-status: applied 2026-09-20 · kit ad87c33 -->"+"\n"),
		dry("status/bom-marker", "\ufeff"+applied+"\n# retro\n\n## Proposed kit deltas\n\n"+tblHdr+rows[0]+"\n"),
		dry("status/bom-then-h1-marker", "\ufeff# retro\n\n"+applied+"\n\n## Proposed kit deltas\n\n"+tblHdr+rows[0]+"\n"),
		dry("status/pending-with-trailing-text", doc("<!-- review-status: pending · will seed later -->", rows...)),
		dry("status/uppercase-word", doc("<!-- review-status: APPLIED · abc -->", rows...)),
	}
}
