package gate

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Scenarios of the hook contract: arguments, loop safety, block-once, the verdicts, the degraded state and the
// session-sha scope of the retro search. The ids are the case ids of the old bash suite (tests/retro-gate.test.sh);
// the map from each removed case to its scenario is in the PR body.

var rgCases []rgCase

func reasonOf(t *testing.T, out string) string {
	t.Helper()
	var m struct{ Decision, Reason string }
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("stdout is not one JSON decision: %v\n%s", err, out)
	}
	if m.Decision != "block" {
		t.Fatalf("decision = %q", m.Decision)
	}
	return m.Reason
}

// std is a target with a session start recorded at 08:00 and one block committed after it (mtime 10:00).
func (w *rgWorld) std(name, sid string) string {
	d := w.mkgit(name)
	w.session(d, sid, rgSession)
	w.block(d, "niagara-block1.md", "2026-09-05T10:00:00")
	w.touch(d+"/niagara-block1.md", "202609051000")
	return d
}

// nojq is a PATH holding the tools the gate needs, and no jq.
func (w *rgWorld) nojq() string {
	dir := w.root + "/nojq"
	must(w.t, os.MkdirAll(dir, 0o755))
	for _, tool := range []string{"bash", "git", "date", "dirname", "basename", "find", "grep", "sed", "awk", "tail", "head", "wc", "mv", "rm", "mkdir", "mktemp", "readlink", "realpath", "stat", "timeout", "sort", "tr", "cut", "cat", "ls", "env", "sleep", "tee", "touch"} {
		if p, err := exec.LookPath(tool); err == nil {
			_ = os.Symlink(p, dir+"/"+tool)
		}
	}
	return dir
}

func init() {
	rgCases = append(rgCases,
		rgCase{id: "BAD-args", // BAD: no arg / nonexistent target → exit 0 (hook contract)
			setup: func(w *rgWorld) []rgRun {
				return []rgRun{{args: nil}, {args: []string{w.root + "/nope"}}, {args: []string{"a", "b"}}}
			},
			check: func(t *testing.T, rs []*rgRes) {
				for i, r := range rs {
					if r.rc != 0 || r.out != "" {
						t.Errorf("run %d: rc=%d out=%q, want the hook contract (0, empty)", i, r.rc, r.out)
					}
				}
				has(t, "no arg", rs[0].err, "Usage: retro-gate.sh [--json] <target>\n", "retro-gate: ERROR: missing <target>\n")
				has(t, "nonexistent", rs[1].err, "retro-gate: ERROR: target not found: <R>/nope\n")
				has(t, "two positionals", rs[2].err, "missing <target>")
				if len(rs[1].tree) != 0 {
					t.Errorf("a target that does not exist leaves no state: %v", rs[1].tree)
				}
			}},

		rgCase{id: "ALLOW-loop-safety", // stop_hook_active=true → exit 0, no JSON, loop-safety on stderr
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				r := gate(d, "s1")
				r.stdin = mkjson("s1", true)
				return one(r)
			},
			check: func(t *testing.T, rs []*rgRes) {
				r := rs[0]
				if r.rc != 0 || r.out != "" {
					t.Errorf("rc=%d out=%q", r.rc, r.out)
				}
				has(t, "stderr", r.err, "retro-gate: state=allow branch=loop-safety stop_hook_active=true target=t\n")
				has(t, "log", r.lastLog(), "target=t session=s1 branch=loop-safety")
			}},

		rgCase{id: "BLOCK-no-retro", // BLOCK: no retro → decision=block, template reference, exit 0
			setup: func(w *rgWorld) []rgRun { return one(gate(w.std("t", "s1"), "s1")) },
			check: func(t *testing.T, rs []*rgRes) {
				r := rs[0]
				reason := reasonOf(t, r.out)
				if r.rc != 0 {
					t.Errorf("rc=%d", r.rc)
				}
				has(t, "reason", reason, "§18 retro pending for t: run the SELF-RETROSPECTIVE (fresh-context retro agent) from ",
					"/kit/templates/retro.template.md → <R>/t/retros/<D>-<focus>.md, then stop. Checked: research file(s) changed, newest retro: none added this session. Template: ")
				has(t, "stderr", r.err, "retro-gate: state=block branch=retro-pending changed=1 changed retro=(none) target=t\n")
				has(t, "block-once state", r.tree[".rsdd-retro-blocked-s1"], "<TS>\n")
				has(t, "log", r.lastLog(), "branch=retro-pending")
			}},

		rgCase{id: "BLOCK-once", // second Stop of the same session allows
			setup: func(w *rgWorld) []rgRun { d := w.std("t", "s1"); return []rgRun{gate(d, "s1"), gate(d, "s1")} },
			check: func(t *testing.T, rs []*rgRes) {
				if !rs[0].blocked() {
					t.Fatalf("first Stop must block: %q", rs[0].out)
				}
				if rs[1].rc != 0 || rs[1].out != "" {
					t.Errorf("second: rc=%d out=%q", rs[1].rc, rs[1].out)
				}
				has(t, "stderr", rs[1].err, "retro-gate: state=allow branch=block-once session=s1 target=t\n")
				has(t, "log", rs[1].lastLog(), "branch=block-once")
			}},

		rgCase{id: "ALLOW-no-change", // no research change → allow, branch=no-change
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				w.session(d, "s1", rgSession)
				return one(gate(d, "s1"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].rc != 0 || rs[0].out != "" {
					t.Errorf("rc=%d out=%q", rs[0].rc, rs[0].out)
				}
				has(t, "stderr", rs[0].err, "retro-gate: state=allow branch=no-change target=t\n")
			}},

		rgCase{id: "ALLOW-conforming", // a conforming retro added since the session start → allow, retro-conforming
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				w.retroCommitted(d, "2026-09-05-r.md", "2026-09-05T12:00:00")
				w.touch(d+"/retros/2026-09-05-r.md", "202609051200")
				return one(gate(d, "s1"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].rc != 0 || rs[0].out != "" {
					t.Errorf("rc=%d out=%q", rs[0].rc, rs[0].out)
				}
				has(t, "stderr", rs[0].err, "retro-gate: state=allow branch=retro-conforming retro=2026-09-05-r.md target=t\n")
			}},

		rgCase{id: "BLOCK-non-conforming", // a non-conforming retro → block naming the missing elements
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				w.retro(d, "2026-09-05-bad.md", false)
				w.git(d, "add", "retros/2026-09-05-bad.md")
				w.gitAt(d, "2026-09-05T12:00:00", "commit", "-q", "-m", "bad retro")
				return one(gate(d, "s1"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				reason := reasonOf(t, rs[0].out)
				has(t, "reason", reason, "§18 retro pending for t: 2026-09-05-bad.md is non-conforming. Fix it (from ", "/kit/templates/retro.template.md) — missing elements: ")
				has(t, "stderr", rs[0].err, "changed=1 changed retro=2026-09-05-bad.md target=t")
			}},

		rgCase{id: "DEGRADE-no-jq", // jq absent → allow, branch=degraded, nothing on stdout; the Stop is still logged
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				r := gate(d, "s1")
				r.path = w.nojq()
				return one(r)
			},
			check: func(t *testing.T, rs []*rgRes) {
				r := rs[0]
				if r.rc != 0 || r.out != "" {
					t.Errorf("rc=%d out=%q", r.rc, r.out)
				}
				has(t, "stderr", r.err, "retro-gate: state=allow branch=degraded (jq missing — cannot read hook JSON) target=t\n")
				has(t, "log (SL9)", r.lastLog(), "branch=degraded")
			}},

		rgCase{id: "EMITTER-dq", // a target name with a double quote still yields valid JSON
			setup: func(w *rgWorld) []rgRun { return one(gate(w.std(`t"q`, "s1"), "s1")) },
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "reason", reasonOf(t, rs[0].out), `§18 retro pending for t"q:`)
				has(t, "raw", rs[0].out, `retro pending for t\"q:`)
			}},
	)
}

// ── #957: the session-sha scope of the retro search ──────────────────────────

func init() {
	oldRetro := func(w *rgWorld, name, sid string) string {
		d := w.mkgit(name)
		w.retroCommitted(d, "2026-01-10-old-retro.md", "2026-01-10T00:00:00")
		w.session(d, sid, rgSession)
		w.block(d, "niagara-block1.md", "2026-09-05T10:00:00")
		w.touch(d+"/niagara-block1.md", "202609051000")
		return d
	}
	rename := func(w *rgWorld, d string) {
		w.git(d, "mv", "retros/2026-01-10-old-retro.md", "retros/2026-09-23-renamed.md")
		w.gitAt(d, "2026-09-23T12:00:00", "commit", "-q", "-m", "rename retro")
	}
	wantBlock := func(t *testing.T, rs []*rgRes) {
		if !rs[0].blocked() {
			t.Errorf("want block, got out=%q err=%s", rs[0].out, rs[0].err)
		}
	}
	wantAllow := func(t *testing.T, rs []*rgRes) {
		if rs[0].out != "" || rs[0].rc != 0 {
			t.Errorf("want allow, got rc=%d out=%q err=%s", rs[0].rc, rs[0].out, rs[0].err)
		}
	}
	rgCases = append(rgCases,
		rgCase{id: "T-flip", // an old retro with a bumped mtime does not qualify (session-sha scope, not mtime)
			setup: func(w *rgWorld) []rgRun {
				d := oldRetro(w, "t", "s")
				w.touch(d+"/retros/2026-01-10-old-retro.md", "202609051200")
				return one(gate(d, "s"))
			}, check: wantBlock},
		rgCase{id: "T-git-mv", // a renamed retro is R, not A
			setup: func(w *rgWorld) []rgRun { d := oldRetro(w, "t", "s"); rename(w, d); return one(gate(d, "s")) }, check: wantBlock},
		rgCase{id: "T-git-mv-diff-renames-false", // -M forces rename detection whatever diff.renames says
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				w.git(d, "config", "diff.renames", "false")
				w.retroCommitted(d, "2026-01-10-old-retro.md", "2026-01-10T00:00:00")
				w.session(d, "s", rgSession)
				w.block(d, "niagara-block1.md", "2026-09-05T10:00:00")
				rename(w, d)
				return one(gate(d, "s"))
			}, check: wantBlock},
		rgCase{id: "T-new-committed",
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s")
				w.retroCommitted(d, "2026-09-05-new-retro.md", "2026-09-05T12:00:00")
				return one(gate(d, "s"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				wantAllow(t, rs)
				has(t, "stderr", rs[0].err, "retro-conforming")
			}},
		rgCase{id: "T-untracked-new", // an untracked retro newer than the session file qualifies
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s")
				p := w.retro(d, "2026-09-05-untracked.md", true)
				w.touch(p, "202609051200")
				return one(gate(d, "s"))
			}, check: wantAllow},
		rgCase{id: "T-same-commit",
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				w.session(d, "s", "")
				w.write(d+"/niagara-block1.md", "# Block\n\nContent.\n")
				w.retro(d, "2026-09-05-same-commit.md", true)
				w.git(d, "add", "-A")
				w.gitAt(d, "2026-09-05T12:00:00", "commit", "-q", "-m", "block and retro")
				return one(gate(d, "s"))
			}, check: wantAllow},
		rgCase{id: "T-non-git", // a non-git target runs degraded: the mtime of the retro against the block
			setup: func(w *rgWorld) []rgRun {
				d := w.root + "/t"
				w.write(d+"/niagara-block1.md", "# Block\n")
				w.touch(d+"/niagara-block1.md", "202609051000")
				p := w.retro(d, "2026-09-05-nongit.md", true)
				w.touch(p, "202609051100")
				return one(gate(d, "ng"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				wantAllow(t, rs)
				has(t, "stderr", rs[0].err, "retro-gate: WARN: no session-start sha (session file absent/empty); degraded check\n")
				has(t, "log", rs[0].lastLog(), "branch=retro-conforming mode=degraded")
			}},
		rgCase{id: "T-staged", // a staged, uncommitted retro qualifies (--cached)
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				w.session(d, "s", "")
				w.block(d, "niagara-block1.md", "2026-09-05T10:00:00")
				w.retro(d, "2026-09-05-staged.md", true)
				w.git(d, "add", "retros/2026-09-05-staged.md")
				return one(gate(d, "s"))
			}, check: wantAllow},
		rgCase{id: "T-badsha", // an unresolvable sha degrades to the mtime fallback
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				w.write(d+"/.claude/.rsdd-session-s", "0123456789abcdef0123456789abcdef01234567\n")
				w.touch(d+"/.claude/.rsdd-session-s", rgSession)
				w.block(d, "niagara-block1.md", "2026-09-05T10:00:00")
				w.touch(d+"/niagara-block1.md", "202609051000")
				w.retroCommitted(d, "2026-09-05-badsha.md", "2026-09-05T12:00:00")
				w.touch(d+"/retros/2026-09-05-badsha.md", "202609051200")
				return one(gate(d, "s"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				wantAllow(t, rs)
				has(t, "stderr", rs[0].err, "retro-gate: WARN: session-start sha 0123456789ab unresolvable; degraded check\n")
			}},
		rgCase{id: "T-nest", // a retro under corpus/retros/ qualifies (no pathspec)
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				w.session(d, "s", "")
				w.write(d+"/corpus/niagara-block1.md", "# Block\n")
				w.git(d, "add", "-A")
				w.gitAt(d, "2026-09-05T10:00:00", "commit", "-q", "-m", "corpus block")
				w.write(d+"/corpus/retros/2026-09-05-nested.md", rgConformingRetro)
				w.git(d, "add", "-A")
				w.gitAt(d, "2026-09-05T12:00:00", "commit", "-q", "-m", "nested retro")
				return one(gate(d, "s"))
			}, check: wantAllow},
		rgCase{id: "T-untracked-old", // accepted tradeoff: an untracked retro older than the session file does not qualify
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				w.block(d, "niagara-block1.md", "2026-09-05T10:00:00")
				w.touch(d+"/niagara-block1.md", "202609051000")
				w.touch(w.retro(d, "2026-01-01-old-untracked.md", true), "202601010800")
				w.session(d, "s", rgSession)
				return one(gate(d, "s"))
			}, check: wantBlock},
		rgCase{id: "T-idx-only", // INDEX.md never qualifies
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s")
				w.write(d+"/retros/INDEX.md", "# Index\n")
				w.git(d, "add", "retros/INDEX.md")
				w.gitAt(d, "2026-09-05T12:00:00", "commit", "-q", "-m", "index")
				return one(gate(d, "s"))
			}, check: wantBlock},
		rgCase{id: "T-excluded", // a `kit-retro: exclude` retro never qualifies
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s")
				w.write(d+"/retros/2026-09-05-excluded.md", "<!-- kit-retro: exclude -->\n# Client feedback\n")
				w.git(d, "add", "retros/2026-09-05-excluded.md")
				w.gitAt(d, "2026-09-05T12:00:00", "commit", "-q", "-m", "excluded")
				return one(gate(d, "s"))
			}, check: wantBlock},
		// Deep and odd retro paths: the scan is a native match, not a grep per path (#2168).
		rgCase{id: "T-untracked-path-forms", // depth, quoting and the index filter on the untracked (b) leg
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s")
				for _, p := range []string{"a/b/c/retros/x/deep.md", "retros/sub/INDEXED.md", "retros/Ünï.md", "retros/.md", "retros/notes.txt", "xretros/y.md"} {
					w.touch(w.write0(d+"/"+p, "x\n"), "202609051200")
				}
				return one(gate(d, "s"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "stderr", rs[0].err, "retro=")
			}},
	)
}

func (w *rgWorld) write0(p, c string) string { w.write(p, c); return p }

var _ = filepath.Join
var _ = strings.Contains
