package reconcile

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

type tb = *testing.T

func must(t tb, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// The case table. Every case is a slice-1 scenario of the bash suite shape: ONE retro audited against an
// --issues-cache, no --closed-cache. Cases that need the closed-issue classes, --all or live gh are NOT here; the
// list at the bottom (deferredCases) names them with their slice so the gap is declared, not silent.

const tableHead = "## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n"

const (
	pending = "<!-- review-status: pending -->\n# retro\n\n"
	applied = "<!-- review-status: applied 2026-01-01 -->\n# retro\n\n"
)

// rowsOf renders one table row per id.
func rowsOf(ids ...string) string {
	var sb strings.Builder
	for _, id := range ids {
		sb.WriteString("| " + id + " | change " + id + " | CLAUDE.md | B1 | fix | HIGH |\n")
	}
	return sb.String()
}

// sigs renders one issue-body signature line per id for target/retro.
func sigs(target, retro string, ids ...string) string {
	var sb strings.Builder
	for _, id := range ids {
		sb.WriteString("Source retro: " + target + "/retros/" + retro + " · " + id + "\n")
	}
	return sb.String()
}

func allCases() []dcase {
	cs := coreCases()
	cs = append(cs, inputStateCases()...)
	cs = append(cs, formCases()...)
	cs = append(cs, markerCases()...)
	cs = append(cs, layoutCases()...)
	cs = append(cs, matrixCases()...)
	cs = append(cs, closedCases()...)
	cs = append(cs, regressedCases()...)
	return cs
}

func coreCases() []dcase {
	tbl := pending + tableHead
	return []dcase{
		{name: "core/tracked-and-untracked", retro: tbl + rowsOf("1", "2"), cache: sigs("target-foo", "r.md", "1")},
		{name: "core/all-tracked-no-closed-note", retro: tbl + rowsOf("1", "2"), cache: sigs("target-foo", "r.md", "1", "2")},
		{name: "core/all-untracked-empty-cache", retro: tbl + rowsOf("1", "2", "3"), cache: ""},
		{name: "core/orphaned-issue-row-absent-from-retro", retro: tbl + rowsOf("1"), cache: sigs("target-foo", "r.md", "1", "9")},
		{name: "core/orphaned-duplicate-lines-kept", retro: tbl + rowsOf("1"), cache: sigs("target-foo", "r.md", "9", "9")},
		{name: "core/tracked-duplicate-row-ids", retro: tbl + rowsOf("1", "1"), cache: sigs("target-foo", "r.md", "1")},
		{name: "core/orphaned-applied-status-reason", retro: applied + tableHead + rowsOf("1", "2"), cache: sigs("target-foo", "r.md", "1")},
		{name: "core/orphaned-dismissed-status-reason", retro: "<!-- review-status: dismissed 2026-01-01 -->\n# retro\n\n" + tableHead + rowsOf("1"), cache: sigs("target-foo", "r.md", "1")},
		{name: "core/no-match-applied-empty-cache", retro: applied + tableHead + rowsOf("1"), cache: ""},
		{name: "core/no-match-empty-table", retro: tbl, cache: ""},
		{name: "core/other-retro-signature-ignored", retro: tbl + rowsOf("1"), cache: sigs("target-foo", "other.md", "1")},
		{name: "core/other-target-signature-ignored", retro: tbl + rowsOf("1"), cache: sigs("other-target", "r.md", "1")},
		{name: "core/signature-needs-the-dot-literal", retro: tbl + rowsOf("1"), cache: sigs("target-foo", "rXmd", "1")},
		{name: "core/signature-in-the-middle-of-a-line", retro: tbl + rowsOf("1"), cache: "see Source retro: target-foo/retros/r.md · 1 for details\n"},
		{name: "core/signature-last-dot-separator-wins", retro: tbl + rowsOf("1"), cache: "Source retro: target-foo/retros/r.md · 1 · note\n"},
		{name: "core/signature-id-with-trailing-text", retro: tbl + rowsOf("1"), cache: "Source retro: target-foo/retros/r.md · 1 (seeded)\n"},
		{name: "core/signature-without-id", retro: tbl + rowsOf("1"), cache: "Source retro: target-foo/retros/r.md · \n"},
		{name: "core/record-separator-lines", retro: tbl + rowsOf("1", "2"), cache: "Source retro: target-foo/retros/r.md · 1\n\x1e\nSource retro: target-foo/retros/r.md · 2\n\x1e\n"},
		{name: "core/crlf-cache", retro: tbl + rowsOf("1", "2"), cache: "Source retro: target-foo/retros/r.md · 1\r\nSource retro: target-foo/retros/r.md · 2\r\n"},
		{name: "core/cache-trailing-blank-lines", retro: tbl + rowsOf("1"), cache: sigs("target-foo", "r.md", "1") + "\n\n\n"},
		{name: "core/cache-nul-bytes", retro: tbl + rowsOf("1"), cache: "Source retro: target-foo/retros/r.md · 1\x00\n"},
		{name: "core/cache-is-whitespace-only", retro: tbl + rowsOf("1"), cache: "\n\n"},
		{name: "core/row-ids-case-sensitive", retro: tbl + rowsOf("D1"), cache: sigs("target-foo", "r.md", "d1")},
		{name: "core/legacy-pre-1286-signature-tracks", retro: tbl + rowsOf("1", "2"), cache: sigs("legacy-dir", "r.md", "1"),
			target: "reg-name", retroDir: "rh/legacy-dir/retros", targets: "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `@BOX@/rh/legacy-dir` |\n"},
		{name: "core/legacy-and-registered-signatures-mixed", retro: tbl + rowsOf("1", "2", "3"),
			cache:  sigs("legacy-dir", "r.md", "1") + sigs("reg-name", "r.md", "2") + sigs("legacy-dir", "r.md", "8"),
			target: "reg-name", retroDir: "rh/legacy-dir/retros", targets: "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `@BOX@/rh/legacy-dir` |\n"},
		{name: "core/legacy-name-equal-to-registered-name", retro: tbl + rowsOf("1"), cache: sigs("target-foo", "r.md", "1")},
		{name: "core/metacharacter-target-names-are-literal", retro: tbl + rowsOf("1", "2"),
			cache:  sigs("target-v2Xfoo", "r.md", "1") + sigs("target-v2.foo", "r.md", "2"),
			target: "target-v2.foo"},
		{name: "core/untracked-note-emitted-once", retro: tbl + rowsOf("1", "2", "3", "4"), cache: sigs("target-foo", "r.md", "3")},
	}
}

func inputStateCases() []dcase {
	tbl := pending + tableHead + rowsOf("1")
	return []dcase{
		{name: "input/absent-retro", noRetro: true, cache: ""},
		{name: "input/absent-retro-relative", noRetro: true, retroArg: "no/such/retro.md"},
		{name: "input/retro-is-a-directory", retro: "x", retroFile: "r.md", prep: func(t tb, b *box) {
			must(t, os.Remove(b.retro))
			must(t, os.Mkdir(b.retro, 0o755))
		}},
		{name: "input/cache-file-missing-is-degraded", retro: tbl, cacheMissing: true},
		{name: "input/cache-file-missing-after-empty-input", retro: "# retro\n\nno deltas\n", cacheMissing: true},
		{name: "input/cache-is-a-directory", retro: tbl, prep: func(t tb, b *box) {
			must(t, os.Remove(b.cache))
			must(t, os.Mkdir(b.cache, 0o755))
		}},
		{name: "input/retro-unreadable-is-degraded", retro: tbl, prep: func(t tb, b *box) { must(t, os.Chmod(b.retro, 0)) }},
		{name: "input/empty-retro-file", retro: ""},
		{name: "input/empty-input-no-delta-section", retro: "# retro\n\nNo proposed deltas here.\n"},
		{name: "input/empty-input-honest-zero", retro: pending + "## Proposed kit deltas\n\nNo new deltas — nothing to add.\n"},
		{name: "input/unclassifiable-canonical-heading-with-prose", retro: pending + "## Proposed kit deltas\n\nSome prose about a delta, no table, no entries.\n"},
		{name: "input/unclassifiable-empty-canonical-heading", retro: pending + "## Proposed kit deltas\n\n"},
		{name: "input/relative-retro-path", retro: tbl, cache: sigs("target-foo", "r.md", "1"), rel: true},
		{name: "input/retro-path-with-dotdot", retro: tbl, cache: sigs("target-foo", "r.md", "1"), retroArg: "@BOX@/rh/target-foo/retros/../retros/r.md"},
		{name: "input/retro-reached-through-symlink", retro: tbl, cache: sigs("target-foo", "r.md", "1"), prep: func(t tb, b *box) {
			must(t, os.Symlink(filepath.Join(b.root, "rh", "target-foo"), filepath.Join(b.root, "link")))
			b.arg = filepath.Join(b.root, "link", "retros", "r.md")
		}},
		{name: "input/bom-before-the-marker", retro: "\xef\xbb\xbf" + applied + tableHead + rowsOf("1"), cache: ""},
		{name: "input/crlf-retro", retro: strings.ReplaceAll(tbl, "\n", "\r\n"), cache: sigs("target-foo", "r.md", "1")},
		{name: "input/retro-without-final-newline", retro: strings.TrimSuffix(tbl, "\n"), cache: ""},
	}
}

func matrixCases() []dcase {
	var out []dcase
	markers := map[string]string{
		"pending": "<!-- review-status: pending -->\n", "none": "", "applied": "<!-- review-status: applied -->\n",
		"dismissed": "<!-- review-status: dismissed -->\n", "unknown": "<!-- review-status: wibble -->\n",
		"partial": "<!-- review-status: PARTIAL shipped: 1 -->\n", "partial-dismissed": "<!-- review-status: PARTIAL shipped: 1; DISMISSED: 2 -->\n",
		"partial-nothing-shipped": "<!-- review-status: PARTIAL -->\n",
	}
	caches := map[string]string{
		"empty": "", "row1": sigs("target-foo", "r.md", "1"), "rows123": sigs("target-foo", "r.md", "1", "2", "3"),
		"row2-row9": sigs("target-foo", "r.md", "2", "9"),
	}
	for _, mn := range sortedKeys(markers) {
		for _, cn := range sortedKeys(caches) {
			out = append(out, dcase{
				name:  "matrix/" + mn + "-" + cn,
				retro: markers[mn] + "# retro\n\n" + tableHead + rowsOf("1", "2", "3"),
				cache: caches[cn],
			})
		}
	}
	return out
}
