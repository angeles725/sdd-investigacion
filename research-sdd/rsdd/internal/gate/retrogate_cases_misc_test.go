package gate

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Scenarios of the --json envelope (#1711), the Stop-branch log (#1258) and the nested-worktree probe's failure
// handling (#1301).

// envelope parses the ONE document on stdout and returns the verdict item.
func envelope(t *testing.T, out string) (doc, item map[string]any) {
	t.Helper()
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("stdout is not one JSON document: %v\n%s", err, out)
	}
	items, _ := doc["items"].([]any)
	if len(items) != 1 {
		t.Fatalf("items = %v", doc["items"])
	}
	return doc, items[0].(map[string]any)
}

func counts(doc map[string]any) map[string]any { c, _ := doc["counts"].(map[string]any); return c }

// verdictIs checks the verdict item of a --json run: verdict, branch, check_mode (nil = null) and the counts.
func verdictIs(t *testing.T, r *rgRes, verdict, branch string, mode any, blocked, degraded, unverified int) map[string]any {
	t.Helper()
	if r.rc != 0 {
		t.Errorf("rc=%d err=%s", r.rc, r.err)
	}
	doc, it := envelope(t, r.out)
	if doc["schema"] != "research-sdd.retro-gate/v1" || doc["state"] != "ok" || doc["reason"] != nil {
		t.Errorf("envelope head = %v", doc)
	}
	if it["kind"] != "verdict" || it["verdict"] != verdict || it["branch"] != branch || it["check_mode"] != mode {
		t.Errorf("item = %v, want %s/%s/%v", it, verdict, branch, mode)
	}
	c := counts(doc)
	if c["blocked"] != float64(blocked) || c["degraded_check"] != float64(degraded) || c["unverified"] != float64(unverified) {
		t.Errorf("counts = %v, want %d/%d/%d", c, blocked, degraded, unverified)
	}
	return it
}

func (w *rgWorld) jqStub(body string) string {
	real, err := exec.LookPath("jq")
	must(w.t, err)
	dir := w.root + "/stub-jq"
	w.script(dir+"/jq", body+"\nexec "+real+" \"$@\"\n")
	return dir
}

func init() {
	rgCases = append(rgCases,
		rgCase{id: "J1/J2", // block envelope; the flag is free in position; stderr, rc and the state file match the default mode
			setup: func(w *rgWorld) []rgRun {
				a, b, c := w.std("a/t", "s1"), w.std("b/t", "s1"), w.std("c/t", "s1")
				return []rgRun{gate(a, "s1").json(), gate(b, "s1"), {args: []string{c, "--json"}, stdin: mkjson("s1", false), target: c}}
			},
			check: func(t *testing.T, rs []*rgRes) {
				it := verdictIs(t, rs[0], "block", "retro-pending", "session-sha", 1, 0, 0)
				if it["target"] != "t" || it["session_id"] != "s1" || it["newest_retro"] != nil {
					t.Errorf("J1b item = %v", it)
				}
				if it["reason"] != strings.ReplaceAll(reasonOf(t, rs[1].out), "<R>/b/", "<R>/a/") {
					t.Errorf("J1d: envelope reason differs from the decision reason")
				}
				if strings.Contains(rs[0].out, `"decision"`) {
					t.Errorf("J1e: --json stdout carries the hook decision")
				}
				if rs[0].err != rs[1].err || rs[0].rc != rs[1].rc {
					t.Errorf("J1f: stderr/rc diverge: %q vs %q", rs[0].err, rs[1].err)
				}
				if rs[0].tree[".rsdd-retro-blocked-s1"] == "" { // J1g
					t.Errorf("J1g: no block-once state under --json")
				}
				verdictIs(t, rs[2], "block", "retro-pending", "session-sha", 1, 0, 0) // J2
			}},
		rgCase{id: "J3", // a non-conforming retro → block item with newest_retro and 'missing elements'
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				w.retro(d, "2026-09-05-bad.md", false)
				w.git(d, "add", "retros/2026-09-05-bad.md")
				w.gitAt(d, "2026-09-05T12:00:00", "commit", "-q", "-m", "bad")
				return one(gate(d, "s1").json())
			},
			check: func(t *testing.T, rs []*rgRes) {
				it := verdictIs(t, rs[0], "block", "retro-pending", "session-sha", 1, 0, 0)
				if it["newest_retro"] != "2026-09-05-bad.md" || !strings.Contains(it["reason"].(string), "missing elements") {
					t.Errorf("item = %v", it)
				}
			}},
		rgCase{id: "J4/J14b", // a verified conforming allow
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				w.retroCommitted(d, "2026-09-05-r.md", "2026-09-05T12:00:00")
				return one(gate(d, "s1").json())
			},
			check: func(t *testing.T, rs []*rgRes) {
				it := verdictIs(t, rs[0], "allow", "retro-conforming", "session-sha", 0, 0, 0)
				if it["reason"] != nil || it["newest_retro"] != "2026-09-05-r.md" {
					t.Errorf("item = %v", it)
				}
			}},
		rgCase{id: "J5/J6/J7", // loop-safety, block-once and no-change allow items
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				e := w.fresh("e", "s2")
				active := gate(d, "s1").json()
				active.stdin = mkjson("s1", true)
				return []rgRun{active, gate(d, "s1"), gate(d, "s1").json(), gate(e, "s2").json()}
			},
			check: func(t *testing.T, rs []*rgRes) {
				verdictIs(t, rs[0], "allow", "loop-safety", nil, 0, 0, 0)
				verdictIs(t, rs[2], "allow", "block-once", nil, 0, 0, 0)
				verdictIs(t, rs[3], "allow", "no-change", "session-sha", 0, 0, 0)
			}},
		rgCase{id: "J8", // a degraded change check says so
			setup: func(w *rgWorld) []rgRun {
				d := w.root + "/t"
				w.touch(w.write0(d+"/niagara-block1.md", "# b\n"), "202609051000")
				return one(gate(d, "nosess").json())
			},
			check: func(t *testing.T, rs []*rgRes) {
				verdictIs(t, rs[0], "block", "retro-pending", "mtime-fallback", 1, 1, 0)
			}},
		rgCase{id: "J9/J13", // jq missing, or too old for --argjson → degraded envelope, rc 3, DEGRADED: line
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				a := gate(d, "s1").json()
				a.path = w.nojq()
				b := gate(d, "s1").json()
				b.path = w.pathWith(w.jqStub("case \" $* \" in *--argjson*) exit 2;; esac"))
				return []rgRun{a, gate(d, "s1"), b}
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].rc != 3 || rs[0].out != `{"schema":"research-sdd.retro-gate/v1","state":"degraded","reason":"jq not found; cannot read hook JSON or build the envelope","counts":{},"items":[]}`+"\n" {
					t.Errorf("J9a: rc=%d out=%q", rs[0].rc, rs[0].out)
				}
				has(t, "J9b", rs[0].err, "retro-gate: state=allow branch=degraded (jq missing — cannot read hook JSON) target=t\nDEGRADED: jq not found; cannot read hook JSON or build the envelope\n")
				if rs[2].rc != 3 || !strings.Contains(rs[2].out, `"reason":"jq lacks --argjson (jq >= 1.5 required)"`) {
					t.Errorf("J13: rc=%d out=%q", rs[2].rc, rs[2].out)
				}
				has(t, "J13", rs[2].err, "DEGRADED: jq lacks --argjson (jq >= 1.5 required)\n")
			}},
		rgCase{id: "J9c/J10", // usage and operational failures; the default mode keeps the hook contract
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				return []rgRun{{args: []string{"--json"}}, {args: []string{"--json", w.root + "/nope"}}, {args: nil}, {args: []string{d, "extra"}, stdin: mkjson("s", false)}}
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].rc != 2 || rs[0].out != "" {
					t.Errorf("J10a: rc=%d out=%q", rs[0].rc, rs[0].out)
				}
				if rs[1].rc != 1 || rs[1].out != "" {
					t.Errorf("J10b: rc=%d out=%q", rs[1].rc, rs[1].out)
				}
				has(t, "J10b", rs[1].err, "retro-gate: ERROR: target not found: <R>/nope\n")
				if rs[2].rc != 0 || rs[3].rc != 0 {
					t.Errorf("J10c/d: default usage rc = %d, %d", rs[2].rc, rs[3].rc)
				}
			}},
		rgCase{id: "J11/ESC-names", // hostile target names survive into a valid envelope and decision
			setup: func(w *rgWorld) []rgRun {
				a, b := w.std("t\"q\\x\ttab\x01\x1b", "s1"), w.std("u é\\\"", "s1")
				return []rgRun{gate(a, "s1").json(), gate(b, "s1").json(), gate(w.std("v\"w\tx\x01", "s9"), "s9")}
			},
			check: func(t *testing.T, rs []*rgRes) {
				for i := 0; i < 2; i++ {
					envelope(t, rs[i].out)
				}
				has(t, "ESC2b", reasonOf(t, rs[2].out), "retro pending for v\"w\tx\x01:")
			}},
		rgCase{id: "J14a", // verify-retro.sh absent → allow item with counts.unverified 1
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				w.retroCommitted(d, "2026-09-05-r.md", "2026-09-05T12:00:00")
				must(w.t, os.Remove(w.tb+"/verify-retro.sh"))
				return []rgRun{gate(d, "s1").json(), gate(d, "s1")}
			},
			check: func(t *testing.T, rs []*rgRes) {
				verdictIs(t, rs[0], "allow", "no-verifier", "session-sha", 0, 0, 1)
				has(t, "stderr", rs[1].err, "retro-gate: state=allow branch=no-verifier (verify-retro.sh absent) target=t\n")
			}},

		// ── #1301: the nested-worktree probe fails or is incomplete ───────────────
		rgCase{id: "P1/J14c", goOnly: true, // a probe failure other than rc 3 keeps the gate blocking, loudly
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				var rs []rgRun
				for _, fail := range []error{errors.New("block-files: boom"), fmt.Errorf("x: %w", kit.ErrNotDirectory)} {
					r := gate(d, "s1")
					r.hooks.nested = func(string) ([]string, error) { return nil, fail }
					r.before = func() { _ = os.Remove(d + "/.claude/.rsdd-retro-blocked-s1") }
					rs = append(rs, r, r.json())
				}
				return rs
			},
			check: func(t *testing.T, rs []*rgRes) {
				for i, rc := range []int{1, 1, 2, 2} {
					want := fmt.Sprintf("retro-gate: WARN: nested-worktree probe failed (rc=%d) for t — worktree copies may be counted\n", rc)
					has(t, fmt.Sprintf("P1 run %d", i), rs[i].err, want)
					lacks(t, "P1 stderr", rs[i].err, "state=allow")
				}
				wantBlocked(t, rs[:1])
				verdictIs(t, rs[1], "block", "retro-pending", "session-sha", 1, 0, 1) // J14c
			}},
		rgCase{id: "P2/J14d", // rc 3 (incomplete traversal): the lib's WARN only, no duplicate, still blocks, unverified
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				must(w.t, os.MkdirAll(d+"/locked", 0o755))
				must(w.t, os.Chmod(d+"/locked", 0))
				w.t.Cleanup(func() { _ = os.Chmod(d+"/locked", 0o755) })
				return []rgRun{gate(d, "s1").json()}
			},
			check: func(t *testing.T, rs []*rgRes) {
				if os.Geteuid() == 0 {
					t.Skip("root reads a mode-0 directory")
				}
				lacks(t, "P2", rs[0].err, "nested-worktree probe failed")
				has(t, "P2", rs[0].err, "block-files: nested_worktree_roots: find exited 1 under <R>/t — worktrees under unreadable directories may be missing\n")
				verdictIs(t, rs[0], "block", "retro-pending", "session-sha", 1, 0, 1)
			}},
		rgCase{id: "P3", // control: a clean probe emits no probe warning
			setup: func(w *rgWorld) []rgRun { return one(gate(w.std("t", "s1"), "s1")) },
			check: func(t *testing.T, rs []*rgRes) {
				lacks(t, "P3", rs[0].err, "nested-worktree probe", "nested_worktree_roots")
			}},
	)

	// ── #1258: the Stop-branch log ──────────────────────────────────────────────
	rgCases = append(rgCases,
		rgCase{id: "SL1/SL2/SL10", // one line per Stop under .claude, nothing else written, the log is ignored by .claude/.rsdd-*
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				w.write(d+"/.gitignore", ".claude/.rsdd-*\n")
				w.git(d, "add", ".gitignore")
				w.gitAt(d, "2026-01-02T00:00:00", "commit", "-q", "-m", "ignore")
				w.session(d, "s1", rgSession)
				second := gate(d, "s1")
				second.stdin = mkjson("s1", true)
				second.before = func() {
					if st := w.git(d, "status", "--porcelain"); st != "" {
						w.t.Errorf("SL10: the Stop left the target's tree dirty: %q", st)
					}
				}
				return []rgRun{gate(d, "s1"), second}
			},
			check: func(t *testing.T, rs []*rgRes) {
				ls := strings.Split(strings.TrimRight(rs[1].stopLog(), "\n"), "\n")
				if len(ls) != 2 {
					t.Fatalf("log = %q", rs[1].stopLog())
				}
				if ls[0] != "<TS> target=t session=s1 branch=no-change" || ls[1] != "<TS> target=t session=s1 branch=loop-safety" {
					t.Errorf("log lines = %q", ls)
				}
				for name := range rs[1].tree {
					if !strings.HasPrefix(name, ".rsdd-") {
						t.Errorf("unexpected state file %s", name)
					}
				}
			}},
		rgCase{id: "SL7", // bounded: past 400 lines the file is cut to the newest 200
			setup: func(w *rgWorld) []rgRun {
				d := w.fresh("t", "s1")
				var b strings.Builder
				for i := 1; i <= 420; i++ {
					fmt.Fprintf(&b, "old-%d\n", i)
				}
				w.write(d+"/.claude/.rsdd-retro-gate-stops.log", b.String())
				return one(gate(d, "s1"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				ls := strings.Split(strings.TrimRight(rs[0].stopLog(), "\n"), "\n")
				if len(ls) != 200 || ls[0] != "old-222" || !strings.Contains(ls[199], "branch=no-change") {
					t.Errorf("rotated log has %d lines, first %q, last %q", len(ls), ls[0], ls[len(ls)-1])
				}
			}},
		rgCase{id: "SL8", // a state directory that cannot be written: typed WARN, verdict unchanged
			setup: func(w *rgWorld) []rgRun {
				d := w.mkgit("t")
				w.block(d, "niagara-block1.md", "2026-09-05T10:00:00")
				w.write(d+"/.claude", "not a directory\n")
				return one(gate(d, "s1"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				wantBlocked(t, rs)
				has(t, "SL8a", rs[0].err, "retro-gate: WARN: stop-log write failed (<R>/t/.claude/.rsdd-retro-gate-stops.log) — Stop not recorded; verdict unaffected\n")
			}},
		rgCase{id: "SL12", // a missing helper lib: exit 0 and a branch=error-helper line
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				must(w.t, os.Remove(w.tb+"/lib"))
				return one(gate(d, "s1"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].rc != 0 || rs[0].out != "" {
					t.Errorf("rc=%d out=%q", rs[0].rc, rs[0].out)
				}
				has(t, "stderr", rs[0].err, "retro-gate: ERROR: missing helper <R>/kit/toolbelt/lib/block-files.sh\n")
				has(t, "log", rs[0].lastLog(), "target=t session= branch=error-helper")
			}},
		rgCase{id: "SL13/SL-session-sanitised", // no session sha → mode=degraded; a session-sha Stop is not marked; odd ids are sanitised
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s1")
				e := w.fresh("e", "ok.id_1-x")
				return []rgRun{gate(d, "nosess"), gate(e, "ok.id_1-x"), {args: []string{e}, stdin: `{"session_id":"a/b c\t\u00e9","stop_hook_active":true}`, target: e}}
			},
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "SL13a", rs[0].lastLog(), "session=nosess branch=retro-pending mode=degraded")
				lacks(t, "SL13b", rs[1].lastLog(), "mode=degraded")
				has(t, "sanitised", rs[2].lastLog(), "session=a_b_c___ branch=loop-safety")
			}},
	)
}
