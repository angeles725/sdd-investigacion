package stage

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The parity case table. Every case runs through the frozen legacy script (differential_test.go, recorded into
// testdata/golden/cases.json) and through the port (golden_test.go replays it without bash). The numbers are the
// cases of the retired bash suite (tests/stage-retro.test.sh), see odd/tasks/stage-retro-go.md for the map.

const (
	mPending = "<!-- review-status: pending -->"
	mApplied = "<!-- review-status: applied 2026-01-01 · kit deadbeef -->"
)

// retroBody is the minimal retro of the old suite: an optional marker line and a Proposed-kit-deltas section.
func retroBody(marker string) string {
	var b strings.Builder
	if marker != "-" {
		b.WriteString(marker + "\n")
	}
	b.WriteString("# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n## Already covered\n\n(none)\n")
	return b.String()
}

// toolsBody carries a Tools section followed by `closer` (the heading after it).
func toolsBody(closer string) string {
	return mPending + "\n# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n" +
		"## Already covered\n\n(none)\n\n## Tools built, adapted, or outgrown\n\n" +
		"| # | CREATED (path - purpose) | ADAPTED | OUTGREW | ORACLE | VERDICT |\n|---|---|---|---|---|---|\n" +
		"| T1 | `tools/t.py` - test tool | - | - | - | `keep-local` - target-specific |\n\n" +
		closer + "\n\nSENTINEL_THIS_MUST_NOT_APPEAR_IN_STAGE_RETRO_OUTPUT\n\n## Last\n\nend\n"
}

// retro writes <dir>/retros/<file> (dir is repo-relative) and commits + pushes it.
func (f *fx) retro(dir, file, content string) {
	f.t.Helper()
	f.write(filepath.Join(dir, "retros", file), content, 0o644)
	f.commitAll("add retro "+file, true)
}

// targets writes the registry: name/path pairs (path repo-relative) and commits nothing (the next commit does).
func (f *fx) targets(pairs ...string) {
	f.t.Helper()
	var b strings.Builder
	b.WriteString("# test targets\n\n| # | Target | Path |\n|---|---|---|\n")
	for i := 0; i+1 < len(pairs); i += 2 {
		b.WriteString("| " + string(rune('1'+i/2)) + " | " + pairs[i] + " | `$RESEARCH_HOME/" + pairs[i+1] + "` |\n")
	}
	f.write("research-sdd/TARGETS.md", b.String(), 0o644)
}

func simple(marker string) func(*testing.T, *fx) {
	return func(t *testing.T, f *fx) { f.retro("targetA", "r1.md", retroBody(marker)) }
}

// selfRef commits the retro on a branch without pushing it, the shape of the self-referential guard cases.
func selfRef(marker, content string) func(*testing.T, *fx) {
	return func(t *testing.T, f *fx) {
		f.write("targetA/retros/r1.md", marker+"\n"+content, 0o644)
		f.commitAll("add retro (not pushed)", false)
	}
}

func allCases() []dcase {
	var cs []dcase
	for _, group := range [][]dcase{coreCases(), guardCases(), selfRefCases(), targetCases(), shapeCases()} {
		cs = append(cs, group...)
	}
	return cs
}

func coreCases() []dcase {
	return []dcase{
		{name: "parity/01-pending-stages-branch", setup: simple(mPending)},
		{name: "parity/02-applied-refused", setup: simple(mApplied)},
		{name: "parity/02b-dismissed-refused", setup: simple("<!-- review-status: dismissed 2026-01-01 -->")},
		{name: "parity/02c-marker-after-heading-does-not-gate", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r1.md", "# retro\n"+mApplied+"\n\n## Proposed kit deltas\n\n| 1 | d | r |\n\n## Next\n\nx\n")
		}},
		{name: "parity/05-missing-retro-arg", args: []string{"@REPO@/targetA/retros/does-not-exist.md"}},
		{name: "parity/05b-no-args", args: []string{}},
		{name: "parity/05c-empty-arg", args: []string{""}},
		{name: "parity/05d-directory-arg", args: []string{"@REPO@/targetA"}, setup: simple(mPending)},
		{name: "parity/06b-relative-retro", setup: simple(mPending), rel: true},
		{name: "parity/06c-retro-from-its-own-dir", setup: simple(mPending), cwd: "targetA/retros"},
		{name: "parity/07-excluded-refused", setup: simple("<!-- kit-retro: exclude -->")},
		{name: "parity/08-tools-table", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r-tools.md", toolsBody("## Metrics"))
		}, retro: "targetA/retros/r-tools.md"},
		{name: "parity/08b-tools-range-bounded", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r-noclose.md", toolsBody("## Honest verdict"))
		}, retro: "targetA/retros/r-noclose.md"},
		{name: "parity/08c-sections-twice", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r1.md", mPending+"\n# r\n\n## Proposed kit deltas\n\nfirst\n\n## Mid\n\nmid\n\n## Proposed kit deltas (again)\n\nsecond\n\n## End\n\nend\n")
		}},
		{name: "parity/09-fetch-fails", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r1.md", retroBody(mPending))
			f.git(f.repo, "remote", "set-url", "origin", filepath.Join(f.root, "nonexistent", "does-not-exist.git"))
		}},
		{name: "parity/10-behind-origin", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r1.md", retroBody(mPending))
			clone := filepath.Join(f.root, "extra-clone")
			f.git(f.root, "clone", "-q", f.remote, clone)
			if err := os.WriteFile(filepath.Join(clone, "extra-from-remote.txt"), []byte("x\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			f.git(clone, "add", "-A")
			f.git(clone, "commit", "-qm", "extra remote commit")
			f.git(clone, "push", "-q", "origin", "main")
		}},
		{name: "parity/11-checkout-b-fails", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r1.md", retroBody(mPending))
			f.git(f.repo, "branch", "-q", "retro/targetA-r1/blocker")
		}},
		{name: "parity/12-symlinked-toolbelt", setup: simple(mPending), viaLink: true},
		{name: "parity/14-existing-branch-held", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r1.md", retroBody(mPending))
			f.git(f.repo, "branch", "-q", "retro/targetA-r1", "origin/main")
			f.git(f.repo, "worktree", "add", "-q", filepath.Join(f.root, "held-wt"), "retro/targetA-r1")
		}},
		{name: "parity/15-stale-branch-predates-retro", setup: func(t *testing.T, f *fx) {
			f.git(f.repo, "branch", "-q", "retro/targetA-r1", "origin/main")
			f.retro("targetA", "r1.md", retroBody(mPending))
		}},
		{name: "parity/15e-existing-branch-has-retro", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r1.md", retroBody(mPending))
			f.git(f.repo, "branch", "-q", "retro/targetA-r1", "origin/main")
		}},
	}
}

func guardCases() []dcase {
	return []dcase{
		{name: "parity/30-dirty-kit-repo", setup: func(t *testing.T, f *fx) {
			f.retro("targetA", "r1.md", retroBody(mPending))
			f.write("scratch.txt", "untracked\n", 0o644)
		}},
		{name: "parity/31-force-on-pending-is-a-noop", setup: simple(mPending), args: []string{"@RETRO@", "--force"}},
		{name: "parity/32-outside-kit-untracked", setup: func(t *testing.T, f *fx) {
			f.write("../outside/retros/r1.md", retroBody(mPending), 0o644)
			f.write("marker.txt", "x\n", 0o644)
			f.commitAll("marker", true)
		}, retro: "../outside/retros/r1.md"},
		{name: "parity/33-outside-kit-tracked", setup: func(t *testing.T, f *fx) {
			out := filepath.Join(f.root, "outside")
			f.write("../outside/retros/r1.md", retroBody(mPending), 0o644)
			f.git(out, "init", "-q", "-b", "main")
			f.git(out, "add", "-A")
			f.git(out, "commit", "-qm", "retro")
		}, retro: "../outside/retros/r1.md"},
	}
}

func selfRefCases() []dcase {
	body := "# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n\n## Already covered\n\n(none)\n"
	return []dcase{
		{name: "parity/13-selfref-unpushed", setup: selfRef(mPending, body)},
		{name: "parity/16-selfref-stale-blob", setup: func(t *testing.T, f *fx) {
			f.write("targetA/retros/r1.md", mPending+"\n# retro\n\nOLD content.\n", 0o644)
			f.commitAll("OLD", true)
			f.write("targetA/retros/r1.md", mPending+"\n# retro\n\nNEW content.\n", 0o644)
			f.write("targetA/retros/r2.md", "# retro 2\n", 0o644)
			f.commitAll("NEW (not pushed)", false)
		}},
		{name: "parity/16b-selfref-local-ahead", setup: selfRef(mPending, "# retro\n")},
		{name: "parity/16c-selfref-other-branch", keepsHead: true, setup: func(t *testing.T, f *fx) {
			f.git(f.repo, "checkout", "-q", "-b", "feat/side")
			f.write("targetA/retros/r1.md", mPending+"\n# retro\n", 0o644)
			f.commitAll("retro on a feature branch only", false)
		}},
		{name: "parity/16d-selfref-origin-ahead", keepsHead: true, setup: func(t *testing.T, f *fx) {
			f.git(f.repo, "checkout", "-q", "-b", "feat/pushed")
			f.write("targetA/retros/r1.md", mPending+"\n# retro\n", 0o644)
			f.commitAll("retro", false)
			f.git(f.repo, "push", "-q", "origin", "feat/pushed:main")
		}},
		{name: "parity/16e-selfref-diverged", keepsHead: true, setup: func(t *testing.T, f *fx) {
			f.git(f.repo, "checkout", "-q", "-b", "feat/pushed2")
			f.write("targetA/retros/r1.md", mPending+"\n# retro\n", 0o644)
			f.commitAll("retro", false)
			f.git(f.repo, "push", "-q", "origin", "feat/pushed2:main")
			f.git(f.repo, "checkout", "-q", "main")
			f.write("local-only.txt", "local only\n", 0o644)
			f.commitAll("local main diverges", false)
			f.git(f.repo, "checkout", "-q", "feat/pushed2")
		}},
		{name: "parity/17-selfref-symlinked-retro", setup: func(t *testing.T, f *fx) {
			f.write("targetA/retros/r1.md", mPending+"\n# retro\n\nOLD content.\n", 0o644)
			f.commitAll("retro (not pushed)", false)
			if err := os.MkdirAll(filepath.Join(f.root, "links"), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(f.abs("targetA/retros"), filepath.Join(f.root, "links", "symlink-to-retros")); err != nil {
				t.Fatal(err)
			}
		}, args: []string{"@BOX@/links/symlink-to-retros/r1.md"}},
	}
}

func targetCases() []dcase {
	return []dcase{
		{name: "parity/20-registered-name", setup: func(t *testing.T, f *fx) {
			f.targets("reg-name", "targetA")
			f.retro("targetA", "r1.md", retroBody(mPending))
		}},
		{name: "parity/21-nested-corpus", setup: func(t *testing.T, f *fx) {
			f.targets("reg-name", "targetA")
			f.retro("targetA/corpus", "r1.md", retroBody(mPending))
		}, retro: "targetA/corpus/retros/r1.md"},
		{name: "parity/22a-nearest-ancestor", setup: func(t *testing.T, f *fx) {
			f.targets("outer-name", "targetA", "inner-name", "targetA/inner-t")
			f.retro("targetA/inner-t", "r1.md", retroBody(mPending))
		}, retro: "targetA/inner-t/retros/r1.md"},
		{name: "parity/22b-nearest-ancestor-reversed", setup: func(t *testing.T, f *fx) {
			f.targets("inner-name", "targetA/inner-t", "outer-name", "targetA")
			f.retro("targetA/inner-t", "r1.md", retroBody(mPending))
		}, retro: "targetA/inner-t/retros/r1.md"},
		{name: "parity/23-unregistered", setup: func(t *testing.T, f *fx) {
			f.targets("other", "other")
			f.retro("targetA", "r1.md", retroBody(mPending))
		}},
		{name: "parity/24a-no-targets-md", setup: simple(mPending)},
		{name: "parity/24b-empty-targets-md", setup: func(t *testing.T, f *fx) {
			f.write("research-sdd/TARGETS.md", "# test targets\n\n| # | Target | Path |\n|---|---|---|\n", 0o644)
			f.retro("targetA", "r1.md", retroBody(mPending))
		}},
		{name: "parity/25-name-cell-with-whitespace", setup: func(t *testing.T, f *fx) {
			f.targets("two words", "targetA")
			f.retro("targetA", "r1.md", retroBody(mPending))
		}},
	}
}

// shapeCases vary the file name: what the slug keeps, replaces and collapses.
func shapeCases() []dcase {
	named := func(file string) dcase {
		return dcase{name: "parity/40-file-" + strings.NewReplacer(" ", "_", "(", "", ")", "").Replace(file), retro: "targetA/retros/" + file,
			setup: func(t *testing.T, f *fx) { f.retro("targetA", file, retroBody(mPending)) }}
	}
	return []dcase{
		named("my retro (v2).md"), named("a--b__c.md"), named("-lead-and-trail-.md"), named("2026-01-01_x.y.md"),
		named("UPPER.md"), named("noext"), named("two.md.md"),
	}
}
