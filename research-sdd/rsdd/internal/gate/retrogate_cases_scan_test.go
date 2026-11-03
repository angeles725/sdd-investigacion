package gate

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// Scenarios of the change and retro scans: nested worktree copies (#1223), directory symlinks (#1311, #1352,
// #1404), symlinked targets (#1301), the generated CATALOG.md (#1229) and the nested-worktree probe's failure
// handling (#1301). Where the bash suite broke a tool through a PATH stub (git, timeout, mktemp), the stub is kept
// for the bash side and the port gets the equivalent seam (a TMPDIR that cannot be used, hooks.onEntry, hooks.walkRC).

func (w *rgWorld) pathWith(dirs ...string) string {
	return strings.Join(dirs, ":") + ":" + w.stubs + ":" + os.Getenv("PATH")
}

// gitStub is a git that fails every ls-files call (git "cannot enumerate") and runs the real one otherwise.
func (w *rgWorld) gitStub() string {
	real, err := exec.LookPath("git")
	must(w.t, err)
	dir := w.root + "/stub-git"
	w.script(dir+"/git", "case \" $* \" in *\" ls-files \"*) exit 1;; esac\nexec "+real+" \"$@\"\n")
	return dir
}

func wantBlocked(t *testing.T, rs []*rgRes) {
	t.Helper()
	if !rs[0].blocked() {
		t.Errorf("want block; out=%q err=%s", rs[0].out, rs[0].err)
	}
}

func wantNoChange(t *testing.T, rs []*rgRes) {
	t.Helper()
	if rs[0].out != "" || !strings.Contains(rs[0].err, "branch=no-change") {
		t.Errorf("want allow/no-change; out=%q err=%s", rs[0].out, rs[0].err)
	}
}

func init() {
	// ── #1223: copies of the corpus in nested worktrees ─────────────────────────
	nestedBlock := func(w *rgWorld, d string) {
		w.touch(w.write0(d+"/.claude/worktrees/wt1/niagara-block1.md", "# copy\n"), "202609051000")
	}
	rgCases = append(rgCases,
		rgCase{id: "W1", // only a .claude/worktrees copy changed → allow
			setup: func(w *rgWorld) []rgRun { d := w.fresh("t", "s"); nestedBlock(w, d); return one(gate(d, "s")) }, check: wantNoChange},
		rgCase{id: "W2", // a real block beside worktree copies still blocks
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				nestedBlock(w, d)
				w.block(d, "niagara-block1.md", "2026-09-05T10:00:00")
				return one(gate(d, "s"))
			}, check: wantBlocked},
		rgCase{id: "W3", // a block inside a real linked worktree nested in the target is a copy, not a change
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				w.git(d, "worktree", "add", "-q", d+"/nested", "-b", "wtb")
				w.touch(w.write0(d+"/nested/niagara-block1.md", "# wt copy\n"), "202609051000")
				return one(gate(d, "s"))
			},
			check: func(t *testing.T, rs []*rgRes) { wantNoChange(t, rs) }},
		rgCase{id: "W3b", // a nested clone (.git directory) is not a worktree: its block counts
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				w.mkgit("t/clone")
				w.touch(w.write0(d+"/clone/niagara-block1.md", "# clone\n"), "202609051000")
				return one(gate(d, "s"))
			}, check: wantBlocked},
		rgCase{id: "W3c", // a submodule-style .git file has no commondir: its block counts
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				w.write(d+"/sub/.git", "gitdir: ../.git/modules/sub\n")
				w.touch(w.write0(d+"/sub/niagara-block1.md", "# sub\n"), "202609051000")
				return one(gate(d, "s"))
			}, check: wantBlocked},
		rgCase{id: "W4", // degraded: a newer .claude/worktrees copy does not make the retro stale
			setup: func(w *rgWorld) []rgRun {
				d := w.root + "/t"
				w.touch(w.write0(d+"/niagara-block1.md", "# b\n"), "202609051000")
				w.touch(w.retro(d, "2026-09-05-r.md", true), "202609051100")
				w.touch(w.write0(d+"/.claude/worktrees/wt/niagara-block1.md", "# c\n"), "202609051400")
				return one(gate(d, "nosess"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].out != "" {
					t.Errorf("want allow: %q %s", rs[0].out, rs[0].err)
				}
			}},
		rgCase{id: "W5", // a retro that only exists inside .claude/worktrees does not qualify
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s")
				w.touch(w.retro(d+"/.claude/worktrees/wt", "2026-09-05-r.md", true), "202609051200")
				return one(gate(d, "s"))
			}, check: wantBlocked},
		rgCase{id: "W6", // the real retro is seeded, the nested-worktree one is not
			setup: func(w *rgWorld) []rgRun {
				x := seedWorld(w, "printf '%s\\n' \"$*\" >> \"$SEED_LOG\"\necho 'summary: created=0 skipped-duplicate=0'\n")
				w.retro(x.target+"/.claude/worktrees/wt", "2026-09-05-copy.md", true)
				return one(x)
			},
			check: func(t *testing.T, rs []*rgRes) {
				if len(rs[0].seeded) != 1 || !strings.Contains(rs[0].seeded[0], "/t/retros/"+rgSeedRetro) {
					t.Errorf("seeded = %v", rs[0].seeded)
				}
				has(t, "stderr", rs[0].err, "ran=1 ")
			}},
		rgCase{id: "W7", // degraded: a retro only inside a nested worktree does not qualify
			setup: func(w *rgWorld) []rgRun {
				d := w.root + "/t"
				w.touch(w.write0(d+"/niagara-block1.md", "# b\n"), "202609051000")
				w.touch(w.retro(d+"/.claude/worktrees/wt", "2026-09-05-r.md", true), "202609051200")
				return one(gate(d, "nosess"))
			}, check: wantBlocked},
		rgCase{id: "W8", // a committed retro under .claude/worktrees does not qualify
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s")
				w.write(d+"/.claude/worktrees/wt/retros/2026-09-05-r.md", rgConformingRetro)
				w.git(d, "add", "-f", ".claude/worktrees")
				w.gitAt(d, "2026-09-05T12:00:00", "commit", "-q", "-m", "wt retro")
				return one(gate(d, "s"))
			}, check: wantBlocked},
		rgCase{id: "W9", // a submodule of a linked-worktree target (gitdir has /worktrees/) is not a worktree
			setup: func(w *rgWorld) []rgRun {
				m := w.mkgit("m")
				wt := w.root + "/w9"
				w.git(m, "worktree", "add", "-q", wt, "-b", "w9b")
				w.session(wt, "s", rgSession)
				must(w.t, os.MkdirAll(m+"/.git/worktrees/w9/modules/sub", 0o755))
				w.write(wt+"/sub/.git", "gitdir: "+m+"/.git/worktrees/w9/modules/sub\n")
				w.touch(w.write0(wt+"/sub/niagara-block1.md", "# sub\n"), "202609051000")
				return one(gate(wt, "s"))
			}, check: wantBlocked},
		rgCase{id: "W10", // `gitdir: .` plus a stray commondir is not a worktree
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				w.write(d+"/fake/.git", "gitdir: .\n")
				w.write(d+"/fake/commondir", "..\n")
				w.touch(w.write0(d+"/fake/niagara-block1.md", "# f\n"), "202609051000")
				return one(gate(d, "s"))
			}, check: wantBlocked},
		rgCase{id: "W10b", // a worktree gitdir without its back-pointer is unprovable: counted, and silent on stderr
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				w.git(d, "worktree", "add", "-q", d+"/nested", "-b", "wtb")
				must(w.t, os.Remove(d+"/.git/worktrees/nested/gitdir"))
				w.touch(w.write0(d+"/nested/niagara-block1.md", "# wt copy\n"), "202609051000")
				return one(gate(d, "s"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				wantBlocked(t, rs)
				lacks(t, "stderr", rs[0].err, "No such file", "nested_worktree_roots")
			}},

		// ── #1229: the generated CATALOG.md ────────────────────────────────────
		rgCase{id: "C1/C3", // degraded: CATALOG.md newer than the retro (also a nested one) does not make it stale
			setup: func(w *rgWorld) []rgRun {
				d := w.root + "/t"
				w.touch(w.write0(d+"/niagara-block1.md", "# b\n"), "202609051000")
				w.touch(w.retro(d, "2026-09-05-r.md", true), "202609051100")
				w.touch(w.write0(d+"/CATALOG.md", "# c\n"), "202609051300")
				w.touch(w.write0(d+"/corpus/CATALOG.md", "# c\n"), "202609051400")
				return one(gate(d, "nosess"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].out != "" {
					t.Errorf("want allow: %q %s", rs[0].out, rs[0].err)
				}
			}},
		rgCase{id: "C2", // degraded: a real block newer than the retro still blocks, CATALOG.md does not mask it
			setup: func(w *rgWorld) []rgRun {
				d := w.root + "/t"
				w.touch(w.retro(d, "2026-09-05-r.md", true), "202609051100")
				w.touch(w.write0(d+"/niagara-block1.md", "# b\n"), "202609051200")
				w.touch(w.write0(d+"/CATALOG.md", "# c\n"), "202609051300")
				return one(gate(d, "nosess"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "reason", reasonOf(t, rs[0].out), "newest retro 2026-09-05-r.md is OLDER than newest changed block. Run the SELF-RETROSPECTIVE from ")
			}},

		// ── #1301: symlinked target ────────────────────────────────────────────
		rgCase{id: "L1", // an uncommitted block via a symlinked target blocks (no false ALLOW)
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("real", "s")
				w.touch(w.write0(d+"/niagara-block1.md", "# b\n"), "202609051000")
				must(w.t, os.Symlink(d, w.root+"/lnk"))
				return one(gate(w.root+"/lnk", "s"))
			},
			check: func(t *testing.T, rs []*rgRes) { wantBlocked(t, rs); lacks(t, "stderr", rs[0].err, "branch=no-change") }},
		rgCase{id: "L2", // a block changed inside a submodule, via a symlinked target
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("real", "s")
				w.write(d+"/sub/.git", "gitdir: ../.git/modules/sub\n")
				w.touch(w.write0(d+"/sub/niagara-block1.md", "# b\n"), "202609051000")
				must(w.t, os.Symlink(d, w.root+"/lnk"))
				return one(gate(w.root+"/lnk", "s"))
			}, check: wantBlocked},
		rgCase{id: "L3/L5/L4", // degraded scans follow a symlinked target: conforming allows and is seeded, a stale one blocks
			setup: func(w *rgWorld) []rgRun {
				d := w.root + "/real"
				w.touch(w.write0(d+"/niagara-block1.md", "# b\n"), "202609051000")
				w.touch(w.retro(d, "2026-09-05-r.md", true), "202609051200")
				must(w.t, os.Symlink(d, w.root+"/lnk"))
				return []rgRun{gate(w.root+"/lnk", "ns1"), {args: []string{w.root + "/lnk"}, stdin: mkjson("ns2", false), target: w.root + "/lnk", before: func() {
					w.touch(d+"/niagara-block1.md", "202609051400")
				}}}
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].out != "" || len(rs[0].seeded) != 1 {
					t.Errorf("conforming: out=%q seeded=%v", rs[0].out, rs[0].seeded)
				}
				has(t, "stale", reasonOf(t, rs[1].out), "is OLDER than newest changed block")
			}},
	)

	// ── #1311 / #1352 / #1404: directory symlinks (Part C) ──────────────────────
	link := func(w *rgWorld, d, name string, newer bool) {
		must(w.t, os.Symlink(w.ext("ext-"+name, newer), d+"/"+name))
	}
	rgCases = append(rgCases,
		rgCase{id: "S1", setup: func(w *rgWorld) []rgRun { d := w.fresh("t", "s"); link(w, d, "corpus", true); return one(gate(d, "s")) }, check: wantBlocked},
		rgCase{id: "S2", setup: func(w *rgWorld) []rgRun {
			d := w.fresh("t", "s")
			link(w, d, "corpus", false)
			return one(gate(d, "s"))
		}, check: wantNoChange},
		rgCase{id: "S3", // a self-referential directory symlink terminates
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				must(w.t, os.Symlink(".", d+"/loop"))
				must(w.t, os.Symlink("sub", d+"/sub"))
				return one(gate(d, "s"))
			}, check: wantNoChange},
		rgCase{id: "S4", // a directory symlink added since the session start counts as a change
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				link(w, d, "corpus", false)
				w.git(d, "add", "corpus")
				w.gitAt(d, "2026-09-05T10:00:00", "commit", "-q", "-m", "link")
				return one(gate(d, "s"))
			}, check: wantBlocked},
		rgCase{id: "S11", // a tracked link (pre-session) with changed research behind it
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				link(w, d, "corpus", true)
				w.git(d, "add", "corpus")
				w.gitAt(d, "2026-09-01T10:00:00", "commit", "-q", "-m", "link")
				w.session(d, "s", rgSession)
				return one(gate(d, "s"))
			}, check: wantBlocked},
		rgCase{id: "S5", // a link into a nested worktree is not a change
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				w.touch(w.write0(d+"/.claude/worktrees/wt/niagara-block1.md", "# c\n"), "202609051000")
				must(w.t, os.Symlink(".claude/worktrees/wt", d+"/corpus"))
				return one(gate(d, "s"))
			}, check: wantNoChange},
		rgCase{id: "S6", // a link to an ancestor is skipped with a typed WARN
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				w.touch(w.write0(w.root+"/up-block1.md", "# up\n"), "202609051000")
				must(w.t, os.Symlink("..", d+"/up"))
				return one(gate(d, "s"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].blocked() {
					t.Errorf("the ancestor was scanned: %s", rs[0].out)
				}
				has(t, "stderr", rs[0].err, "retro-gate: WARN: directory symlink up resolves to <R> (/, $HOME or an ancestor of the target) — not scanned\n")
			}},
		rgCase{id: "S7", // a gitignored link is not enumerated (documented tradeoff)
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				w.write(d+"/.gitignore", "ign\n.claude/\n")
				must(w.t, os.Symlink(w.ext("ext-ign", true), d+"/ign"))
				return one(gate(d, "s"))
			}, check: wantNoChange},
		rgCase{id: "S8/S13", // git cannot enumerate → bounded walk finds the link (also one named with a newline)
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				e := w.ext("ext-a", true)
				must(w.t, os.Symlink(e, d+"/corpus"))
				must(w.t, os.Symlink(e, d+"/nl\nlink"))
				r := gate(d, "s")
				r.path = w.pathWith(w.gitStub())
				return one(r)
			},
			check: func(t *testing.T, rs []*rgRes) {
				wantBlocked(t, rs)
				lacks(t, "stderr", rs[0].err, "WARN: directory-symlink")
			}},
		rgCase{id: "S12", // a link named with a newline is one path end to end
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				must(w.t, os.Symlink(w.ext("ext-a", true), d+"/nl\nlink"))
				return one(gate(d, "s"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				wantBlocked(t, rs)
				lacks(t, "stderr", rs[0].err, "WARN: directory-symlink")
			}},
		rgCase{id: "S9/J15b", // the fallback enumeration times out → typed WARN, counted unverified
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				link(w, d, "corpus", true)
				w.script(w.root+"/stub-to/timeout", "exit 124\n")
				r := gate(d, "s").withEnv("RETRO_GATE_DIRLINK_TIMEOUT", "0.05")
				r.path = w.pathWith(w.gitStub(), w.root+"/stub-to")
				r.hooks.onEntry = func(_, _ string) { sleepMs(120) }
				return []rgRun{r, r.json().withEnv("RETRO_GATE_DIRLINK_TIMEOUT", "0.05")}
			},
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "stderr", rs[0].err, "retro-gate: WARN: directory-symlink scan timed out after 0.05s for t — symlinked research directories not scanned\n")
				has(t, "J15b envelope", rs[1].out, `"unverified": 1`)
			}},
		rgCase{id: "S10/J15c", // an inner walk that exits non-zero is a typed WARN, counted unverified
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				link(w, d, "corpus", false)
				w.script(w.root+"/stub-to/timeout", "shift\ncase \" $* \" in *\" -newer \"*) exit 1;; esac\nexec \"$@\"\n")
				r := gate(d, "s")
				r.path = w.pathWith(w.root + "/stub-to")
				r.hooks.walkRC = func(string) int { return 1 }
				return []rgRun{r, r.json()}
			},
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "stderr", rs[0].err, "retro-gate: WARN: directory-symlink walk incomplete (rc=1) under corpus — research behind it may be missed\n")
				has(t, "J15c envelope", rs[1].out, `"unverified": 1`)
			}},
		rgCase{id: "S14", // RETRO_GATE_DIRLINK_TIMEOUT must be a positive number
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				link(w, d, "corpus", true)
				var rs []rgRun
				for _, v := range []string{"abc", "0", "0.0", "-3", "1e3", "2s", "7", "2.5", ""} {
					r := gate(d, "s").withEnv("RETRO_GATE_DIRLINK_TIMEOUT", v)
					r.before = func() { _ = os.Remove(d + "/.claude/.rsdd-retro-blocked-s") }
					rs = append(rs, r)
				}
				return rs
			},
			check: func(t *testing.T, rs []*rgRes) {
				for i, v := range []string{"abc", "0", "0.0", "-3", "1e3", "2s"} {
					has(t, "invalid "+v, rs[i].err, "retro-gate: WARN: RETRO_GATE_DIRLINK_TIMEOUT='"+v+"' is not a positive number — using the default 5 s\n")
				}
				for i := 6; i < 9; i++ {
					lacks(t, "valid", rs[i].err, "RETRO_GATE_DIRLINK_TIMEOUT")
				}
				// every run after the first is a block-once allow; the first one walked the link and blocked
				if !rs[0].blocked() {
					t.Errorf("link not walked: %s", rs[0].err)
				}
			}},
		rgCase{id: "S15/S15b/J15a", // no scratch file → Part C skipped with ONE typed WARN; control walks the link
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s")
				e := w.ext("ext-a", true)
				must(w.t, os.Symlink(e, d+"/corpus-a"))
				must(w.t, os.Symlink(e, d+"/corpus-b"))
				bad := gate(d, "s").withEnv("TMPDIR", w.root+"/no-such-tmp")
				ctl := gate(d, "s")
				ctl.stdin = mkjson("s2", false)
				w.session(d, "s2", rgSession)
				return []rgRun{bad, bad.json().withEnv("TMPDIR", w.root+"/no-such-tmp"), ctl}
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].rc != 0 || strings.Count(rs[0].err, "WARN: directory-symlink scan skipped: cannot create a scratch file") != 1 || strings.Contains(rs[0].err, "rc=126") {
					t.Errorf("S15: rc=%d err=%s", rs[0].rc, rs[0].err)
				}
				has(t, "J15a", rs[1].out, `"unverified": 1`)
				wantBlocked(t, rs[2:])
				lacks(t, "S15b", rs[2].err, "scratch file")
			}},
	)
}

func sleepMs(n int) { time.Sleep(time.Duration(n) * time.Millisecond) }
