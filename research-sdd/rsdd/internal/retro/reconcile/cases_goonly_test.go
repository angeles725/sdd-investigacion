package reconcile

import (
	"os"
	"path/filepath"
	"testing"
)

// Cases the frozen legacy script cannot answer the way the port does, so no golden exists: each is an intended
// divergence (research-sdd/toolbelt/tool-registry.d/reconcile-issues.md) and the expected output is written here
// from the intended behaviour. Every case fires ONE typed line on its own, without the signal that usually
// travels with it (L28), and asserts the exit code, stdout, stderr and the calls made to gh.
//
//	git could not be run in <dir> (<err>)        a git that exists but cannot start (closed.go probe)
//	git could not resolve ref <ref> in <dir>     git that starts, answers the repository check, then cannot run
//	cannot resolve a registered target name      --all reaches a retro whose directory resolves outside its target
//	a shipped: range too large to expand         a marker range the legacy loop would spend its life printing
//	RSDD_GH_TIMEOUT                              a gh call that outlives the bound (the script had no bound)

type goOnlyCase struct {
	dcase
	want result
}

// closedFixture is the closed-cache case every git case shares: one row, one closed issue citing a commit of the
// fixture repository and a test, so the audit has to ask git about it.
func closedFixture(name string, f func(*dcase)) dcase {
	d := dcase{
		name: name, retro: pending + tableHead + rowsOf("1"), cache: sigs("target-foo", "other.md", "7"),
		closed: shippedBody(fixMain), useClosed: true, repo: "fix",
	}
	f(&d)
	return d
}

func goOnlyCases() []goOnlyCase {
	// the row is reported borderline, never shipped, whenever git cannot be asked
	borderline := "borderline: row 1 — its issue is closed as completed and cites this retro in r.md, but the closure evidence is incomplete (commit reachability could not be verified (degraded)); human review (not shipped, not untracked, nothing edited)\n"
	tail := " — cannot verify that cited commits reach origin/main; rows are reported borderline, not shipped\n"
	return []goOnlyCase{
		{
			// git exists on PATH but is not executable code (exec format error): neither "not found" nor "not a
			// repository". The legacy script ran it as a shell script and reported "not a git repository".
			dcase: closedFixture("goonly/git-could-not-be-run", func(d *dcase) {
				d.env = map[string]string{"PATH": "@BOX@/badgit"}
				d.prep = func(t tb, b *box) {
					mustMkdir(t, filepath.Join(b.root, "badgit"))
					mustWrite(t, filepath.Join(b.root, "badgit", "git"), "this is not a program\n")
					must(t, os.Chmod(filepath.Join(b.root, "badgit", "git"), 0o755))
				}
			}),
			want: result{RC: 1, Stdout: borderline, Stderr: "degraded: git could not be run in @BOX@/fixrepo (git: proc: cannot start git: fork/exec @BOX@/badgit/git: exec format error)" + tail},
		},
		{
			// git answers `rev-parse --git-dir` and is gone for the next call (it deletes itself): the second
			// probe call cannot run at all, which is not "the ref is unknown".
			dcase: closedFixture("goonly/git-could-not-resolve-ref", func(d *dcase) {
				d.env = map[string]string{"PATH": "@BOX@/onceonly"}
				d.prep = func(t tb, b *box) {
					mustMkdir(t, filepath.Join(b.root, "onceonly"))
					mustWrite(t, filepath.Join(b.root, "onceonly", "git"), "#!/bin/sh\n/bin/rm -f -- \"$0\"\necho .git\n")
					must(t, os.Chmod(filepath.Join(b.root, "onceonly", "git"), 0o755))
				}
			}),
			want: result{RC: 1, Stdout: borderline, Stderr: "degraded: git could not resolve ref origin/main in @BOX@/fixrepo (git: not found: proc: cannot start git: executable file not found in $PATH) — cannot verify that cited commits reach it; rows are reported borderline, not shipped\n"},
		},
		{
			// --all finds a.md through a symlinked retros/ directory (find does not follow the link, os.ReadDir
			// does), but the retro's physical directory is outside every registered target.
			dcase: dcase{
				name: "goonly/all-symlinked-retros-dir-has-no-registered-name", all: true, noRetro: true, targets: targets2,
				files: map[string]string{"rh/real-retros/a.md": pending + tableHead + rowsOf("1")},
				prep: func(t tb, b *box) {
					mustMkdir(t, filepath.Join(b.root, "rh/beta-target/retros"))
					mustMkdir(t, filepath.Join(b.root, "rh/alpha-target"))
					must(t, os.Symlink("../real-retros", filepath.Join(b.root, "rh/alpha-target/retros")))
				},
			},
			want: result{
				RC:     1,
				Stdout: "fleet-summary: tracked=0 untracked=0 shipped=0 borderline=0 regressed=0 orphaned=0 degraded=1 out-of-scope=0 retros=0\n",
				Stderr: "degraded: cannot resolve a registered target name for @BOX@/rh/alpha-target/retros/a.md (target_name_for_retro rc=2)\nWARN: no retro files (*.md) found in '@BOX@/rh/beta-target/retros'\n",
			},
		},
		{
			// the range spans 100001 ids; the legacy `for` loop would print every one of them
			dcase: dcase{
				name:  "goonly/shipped-range-too-large",
				retro: "<!-- review-status: PARTIAL shipped: R1-R100002 -->\n# retro\n\n" + tableHead + rowsOf("1"),
				cache: sigs("target-foo", "other.md", "7"),
			},
			want: result{RC: 1, Stderr: "degraded: the review-status marker of r.md lists a shipped: range too large to expand (grammar: id range too large)\n"},
		},
		{
			// the gh call hangs past RSDD_GH_TIMEOUT=1; the port bounds it, the script waited for ever
			dcase: dcase{
				name: "goonly/gh-timeout", retro: pending + tableHead + rowsOf("1"), live: true,
				gh:  map[string]string{"list-open.hang": "1"},
				env: map[string]string{"RSDD_GH_TIMEOUT": "1"},
			},
			want: result{
				RC:     1,
				Stderr: "degraded: gh issue list failed for r.md (exit 124)\n",
				GHLog:  "gh auth status\ngh issue list --repo angeles725/sdd-investigacion --state open --limit 1000 --search \"Source retro: target-foo/retros/r.md ·\" --json body --jq .[] | .body, \"\\u001e\"\n",
			},
		},
	}
}

func TestGoOnlyCases(t *testing.T) {
	cases := goOnlyCases()
	boxes := make([]*box, len(cases))
	for i, c := range cases {
		boxes[i] = mkBox(t, c.dcase) // every stub is written before any subtest runs (ETXTBSY)
	}
	for i, c := range cases {
		b := boxes[i]
		t.Run(c.name, func(t *testing.T) {
			got := runGo(t, b)
			if d := diffResult(c.want, got); d != "" {
				t.Errorf("%s\ngot: %#v", d, got)
			}
		})
	}
}
