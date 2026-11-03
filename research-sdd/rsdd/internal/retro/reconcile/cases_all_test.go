package reconcile

import (
	"os"
	"path/filepath"
)

// --all over TARGETS.md (the bash suite's cases 8, 10d, 29-31, 34-36, 44i, 45k, 45p3, 46p).

const targets2 = "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | alpha-target | `@BOX@/rh/alpha-target` |\n| 2 | beta-target | `@BOX@/rh/beta-target` |\n"

func allModeCases() []dcase {
	tbl := pending + tableHead + rowsOf("1", "2")
	one := pending + tableHead + rowsOf("1")
	a := func(name string, f func(*dcase)) dcase {
		d := dcase{name: "all/" + name, all: true, noRetro: true, targets: targets2}
		f(&d)
		inner := d.prep
		d.prep = func(t tb, b *box) {
			mustMkdir(t, filepath.Join(b.root, "rh/alpha-target/retros"))
			mustMkdir(t, filepath.Join(b.root, "rh/beta-target/retros"))
			if inner != nil {
				inner(t, b)
			}
		}
		return d
	}
	sigA := func(retro string, ids ...string) string { return sigs("alpha-target", retro, ids...) }
	sigB := func(retro string, ids ...string) string { return sigs("beta-target", retro, ids...) }
	unreadable := func(rel string) func(t tb, b *box) {
		return func(t tb, b *box) { must(t, os.Chmod(filepath.Join(b.root, rel), 0)) }
	}
	return []dcase{
		a("two-targets-one-retro-each", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one, "rh/beta-target/retros/b.md": one}
		}),
		a("two-targets-mixed-classes", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": tbl, "rh/beta-target/retros/b.md": applied + tableHead + rowsOf("1")}
			d.cache = sigA("a.md", "1") + sigB("b.md", "1", "5")
		}),
		a("several-retros-in-bytewise-order", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/b.md": one, "rh/alpha-target/retros/B.md": one, "rh/alpha-target/retros/a.md": one, "rh/beta-target/retros/c.md": one}
		}),
		a("non-md-entries-are-ignored", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one, "rh/alpha-target/retros/notes.txt": one, "rh/alpha-target/retros/a.md.bak": one}
			d.prep = func(t tb, b *box) {
				must(t, os.Mkdir(filepath.Join(b.root, "rh/alpha-target/retros/dir.md"), 0o755))
				must(t, os.Symlink("a.md", filepath.Join(b.root, "rh/alpha-target/retros/link.md")))
			}
		}),
		a("target-without-a-retros-directory", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one}
			d.prep = func(t tb, b *box) { must(t, os.RemoveAll(filepath.Join(b.root, "rh/beta-target/retros"))) }
		}),
		a("only-empty-retros-directories", func(d *dcase) {}),
		a("empty-flat-next-to-a-populated-corpus", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/corpus/retros/a.md": one}
		}),
		a("flat-and-corpus-both-audited", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one, "rh/alpha-target/corpus/retros/c.md": one}
			d.cache = sigA("a.md", "1") + sigA("c.md", "1")
		}),
		a("both-layouts-empty-warn-per-directory", func(d *dcase) {
			d.prep = func(t tb, b *box) { mustMkdir(t, filepath.Join(b.root, "rh/alpha-target/corpus/retros")) }
		}),
		a("target-path-is-not-a-directory", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one}
			d.prep = func(t tb, b *box) { must(t, os.RemoveAll(filepath.Join(b.root, "rh/beta-target"))) }
		}),
		a("nested-registered-target-keeps-its-own-name", func(d *dcase) {
			d.targets = "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | outer | `@BOX@/rh/outer` |\n| 2 | inner | `@BOX@/rh/outer/corpus/inner` |\n"
			d.files = map[string]string{"rh/outer/retros/o.md": one, "rh/outer/corpus/inner/retros/i.md": one}
			d.cache = sigs("inner", "i.md", "1") + sigs("outer", "o.md", "1")
		}),
		a("name-differs-from-the-directory", func(d *dcase) {
			d.targets = "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `@BOX@/rh/legacy-dir` |\n"
			d.files = map[string]string{"rh/legacy-dir/retros/r.md": tbl}
			d.cache = sigs("reg-name", "r.md", "1") + sigs("legacy-dir", "r.md", "2")
		}),
		a("research-home-token", func(d *dcase) {
			d.targets = "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | alpha-target | `$RESEARCH_HOME/rh/alpha-target` |\n"
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one}
			d.env = map[string]string{"RESEARCH_HOME": "@BOX@"}
		}),
		a("duplicate-rows-audit-the-target-once", func(d *dcase) {
			d.targets = targets2 + "| 3 | alpha-again | `@BOX@/rh/alpha-target` |\n"
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one}
		}),
		a("targets-md-missing", func(d *dcase) { d.noTargets = true }),
		a("targets-md-without-rows", func(d *dcase) { d.targets = "# nothing registered\n" }),
		a("targets-md-empty-but-present", func(d *dcase) { d.targets = " " }),
		a("no-retro-anywhere", func(d *dcase) { d.targets = "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | gone | `@BOX@/rh/gone` |\n" }),
		a("an-unreadable-retro-is-degraded-the-rest-audited", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one, "rh/beta-target/retros/b.md": one}
			d.prep = unreadable("rh/alpha-target/retros/a.md")
		}),
		a("a-misplaced-marker-is-counted-and-never-fails", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": "# retro\n\n## Notes\n\n<!-- review-status: applied -->\n\n" + tableHead + rowsOf("1"), "rh/beta-target/retros/b.md": one}
		}),
		a("unclassifiable-and-empty-retros-are-not-counted", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": "# retro\n\nnothing\n", "rh/beta-target/retros/b.md": pending + "## Proposed kit deltas\n\nprose only\n"}
		}),
		a("missing-issues-cache-degrades-every-retro", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one, "rh/beta-target/retros/b.md": one}
			d.cacheMissing = true
		}),
		a("a-degraded-retro-keeps-the-tracked-lines-already-printed", func(d *dcase) {
			d.files = map[string]string{"rh/alpha-target/retros/a.md": tbl}
			d.cache = sigA("a.md", "1")
			d.useClosed, d.closedMissing = true, true
		}),
		a("closed-cache-ships-and-borderlines", func(d *dcase) {
			d.repo, d.useClosed = "fix", true
			d.files = map[string]string{"rh/alpha-target/retros/a.md": tbl}
			d.closed = "Source retro: alpha-target/retros/a.md · 1\nCommit: " + fixMain + "\n" + evTest + "\x1e\nSource retro: alpha-target/retros/a.md · 2\nCommit: " + fixMain + "\n"
		}),
		a("git-unusable-degrades-each-retro-that-needs-it", func(d *dcase) {
			d.useClosed = true
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one, "rh/beta-target/retros/b.md": one}
			d.closed = "Source retro: alpha-target/retros/a.md · 1\nCommit: " + fixMain + "\n" + evTest + "\x1e\nSource retro: beta-target/retros/b.md · 1\nCommit: " + fixMain + "\n" + evTest
		}),
		a("shallow-note-once-per-run", func(d *dcase) {
			d.repo, d.useClosed = "shallow", true
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one, "rh/beta-target/retros/b.md": one}
			d.closed = "Source retro: alpha-target/retros/a.md · 1\nCommit: 1234567a\n" + evTest + "\x1e\nSource retro: beta-target/retros/b.md · 1\nCommit: 7654321b\n" + evTest
		}),
		a("regressed-is-counted-and-stays-exit-zero", func(d *dcase) {
			d.repo, d.useClosed = "fix", true
			d.files = map[string]string{
				"rh/alpha-target/retros/" + curRetro:   pending + tableHead + titledRows("1", title1),
				"rh/alpha-target/retros/" + laterRetro: pending + tableHead + titledRows("4", title1),
			}
			d.closed = "Source retro: alpha-target/retros/" + curRetro + " · 1\nCommit: " + fixMain + "\n" + evTest
		}),
		a("live-two-targets", func(d *dcase) {
			d.live = true
			d.files = map[string]string{"rh/alpha-target/retros/a.md": tbl, "rh/beta-target/retros/b.md": one}
			d.gh = map[string]string{"open.json": openJSON(sigA("a.md", "1"))}
		}),
		a("live-open-query-fails-for-every-retro", func(d *dcase) {
			d.live = true
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one, "rh/beta-target/retros/b.md": one}
			d.gh = map[string]string{"list-open.rc": "1", "list-open.err": "down\n"}
		}),
		a("live-gh-missing", func(d *dcase) { d.live, d.noGH = true, true }),
		a("live-closed-completed-is-shipped", func(d *dcase) {
			d.live, d.repo = true, "fix"
			d.files = map[string]string{"rh/alpha-target/retros/a.md": one}
			d.gh = map[string]string{"closed.json": closedJSON(closedIssue(3, "COMPLETED", "Source retro: alpha-target/retros/a.md · 1\nCommit: "+fixMain+"\n"+evTest))}
		}),
		a("live-old-gh-listing-shared-by-all-retros", func(d *dcase) {
			d.live, d.repo = true, "fix"
			d.env = map[string]string{"GH_STUB_OLD_GH": "1"}
			d.files = map[string]string{"rh/alpha-target/retros/2026-03-01-a.md": one, "rh/beta-target/retros/2026-03-01-b.md": one}
			d.gh = map[string]string{
				"closed.1.json": closedJSON(closedIssue(3, "", "Source retro: alpha-target/retros/2026-03-01-a.md · 1\nCommit: "+fixMain+"\n"+evTest)),
				"closed.2.json": closedJSON(closedIssue(4, "", "Source retro: beta-target/retros/2026-03-01-b.md · 1\nCommit: "+fixMain+"\n"+evTest)),
				"api.json":      apiJSON([2]string{"3", "completed"}, [2]string{"4", "not_planned"}),
			}
		}),
		a("list-limit-invalid-before-anything", func(d *dcase) {
			d.env = map[string]string{"RECONCILE_ISSUES_LIST_LIMIT": "nope"}
		}),
	}
}
