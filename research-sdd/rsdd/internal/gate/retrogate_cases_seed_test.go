package gate

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// Scenarios of the issue-seeding on a conforming close (§18-EN3). The seeder is a stub that prints the typed
// outcome under test; what is checked is how the gate counts, words and logs it. The old suite's EN3-*, #944, #971,
// #1258 SL4-SL6 and #1705 K-series cases are these.

const rgSeedRetro = "2026-09-05-r.md"

// seedWorld is a conforming close with the stub seeder body installed; the run is the verdict under test.
func seedWorld(w *rgWorld, body string) rgRun {
	d := w.std("t", "s1")
	w.retroCommitted(d, rgSeedRetro, "2026-09-05T12:00:00")
	w.touch(d+"/retros/"+rgSeedRetro, "202609051200")
	w.seeder(body)
	return gate(d, "s1")
}

// seedCase builds a scenario whose seeder prints body, and checks stderr for the wanted fragments.
func seedCase(id, body string, want ...string) rgCase {
	return rgCase{id: id,
		setup: func(w *rgWorld) []rgRun { return one(seedWorld(w, body)) },
		check: func(t *testing.T, rs []*rgRes) {
			r := rs[0]
			if r.rc != 0 || r.out != "" {
				t.Errorf("seeding never changes the verdict: rc=%d out=%q", r.rc, r.out)
			}
			has(t, "stderr", r.err, want...)
		}}
}

const sumLine = "retro-gate: issue-seeding: "

func init() {
	r := rgSeedRetro
	rgCases = append(rgCases,
		rgCase{id: "EN3-a/SL4", // a conforming close runs the seeder with --apply and counts the run
			setup: func(w *rgWorld) []rgRun {
				return one(seedWorld(w, "printf '%s\\n' \"$*\" >> \"$SEED_LOG\"\nprintf 'summary: created=2 skipped-duplicate=1 skipped-shipped=0 skipped-wrong-kit=0\\n'\n"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				x := rs[0]
				if x.rc != 0 || x.out != "" {
					t.Errorf("rc=%d out=%q", x.rc, x.out)
				}
				if len(x.seeded) != 1 || !strings.HasSuffix(x.seeded[0], "/t/retros/"+r+" --apply") {
					t.Errorf("seeder calls = %v", x.seeded)
				}
				has(t, "stderr", x.err, "retro-gate: seeder "+r+": summary: created=2 skipped-duplicate=1 skipped-shipped=0 skipped-wrong-kit=0\n",
					sumLine+"ran=1 created=2 skipped-dedup=1 empty=0 unclassifiable=0 absent=0 failed=0 failed-issues=0 target=t unknown-outcome-retros=0\n")
				has(t, "log", x.lastLog(), "branch=retro-conforming seeding="+r+" summary: created=2 skipped-duplicate=1 skipped-shipped=0 skipped-wrong-kit=0; ran=1 created=2 skipped-dedup=1 empty=0 unclassifiable=0 absent=0 failed=0 unknown-outcome-retros=0")
			}},
		rgCase{id: "EN3-b", // no retro → block, and the seeder is never called
			setup: func(w *rgWorld) []rgRun { return one(gate(w.std("t", "s1"), "s1")) },
			check: func(t *testing.T, rs []*rgRes) {
				if !rs[0].blocked() || len(rs[0].seeded) != 0 {
					t.Errorf("blocked=%v seeded=%v", rs[0].blocked(), rs[0].seeded)
				}
			}},
		rgCase{id: "EN3-c/SL5", // gh absent → typed skip, still allows
			setup: func(w *rgWorld) []rgRun {
				x := seedWorld(w, "exit 0\n")
				x.path = w.hermetic(false)
				return one(x)
			},
			check: func(t *testing.T, rs []*rgRes) {
				x := rs[0]
				if x.rc != 0 || x.out != "" {
					t.Errorf("rc=%d out=%q", x.rc, x.out)
				}
				has(t, "stderr", x.err, "retro-gate: WARN: gh not found — issue-seeding skipped (run <R>/kit/toolbelt/stage-retro-issues.sh <retro> --apply manually)\n")
				has(t, "log", x.lastLog(), "seeding=skipped:gh-absent")
			}},
		rgCase{id: "EN3-gh-not-authenticated",
			setup: func(w *rgWorld) []rgRun {
				x := seedWorld(w, "exit 0\n")
				w.script(w.stubs+"/gh", "exit 1\n")
				return one(x)
			},
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "stderr", rs[0].err, "retro-gate: WARN: gh not authenticated — issue-seeding skipped (run gh auth login, then <R>/kit/toolbelt/stage-retro-issues.sh <retro> --apply manually)\n")
				has(t, "log", rs[0].lastLog(), "seeding=skipped:gh-not-authenticated")
			}},
		rgCase{id: "EN3-seeder-missing",
			setup: func(w *rgWorld) []rgRun {
				x := seedWorld(w, "exit 0\n")
				must(w.t, os.Remove(w.tb+"/stage-retro-issues.sh"))
				return one(x)
			},
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "stderr", rs[0].err, "retro-gate: WARN: stage-retro-issues.sh not found at <R>/kit/toolbelt/stage-retro-issues.sh — seeding skipped\n")
				has(t, "log", rs[0].lastLog(), "seeding=skipped:seeder-missing")
			}},
		rgCase{id: "EN3-d", // idempotent: two sessions, two seeder calls, no error
			setup: func(w *rgWorld) []rgRun {
				x := seedWorld(w, "printf '%s\\n' \"$*\" >> \"$SEED_LOG\"\nprintf 'summary: created=0 skipped-duplicate=1\\n'\n")
				return []rgRun{x, x}
			},
			check: func(t *testing.T, rs []*rgRes) {
				if len(rs[1].seeded) < 2 {
					t.Errorf("seeder calls = %v", rs[1].seeded)
				}
			}},

		seedCase("EN3-e", "echo 'kit: boom — something broke' >&2\nexit 2\n",
			"retro-gate: WARN: seeder exited 2 for "+r+": no summary: line — counted 0 partial-progress line(s)\n",
			"retro-gate: WARN: seeder failed (exit 2) for "+r+": kit: boom — something broke\n",
			"retro-gate: WARN: unknown issue create(s) failed across 1 retro(s): "+r+"\n",
			sumLine+"ran=1 created=0 skipped-dedup=0 empty=0 unclassifiable=0 absent=0 failed=1 failed-issues=unknown target=t unknown-outcome-retros=0\n"),
		seedCase("EN3-e-partial", "echo 'created: #11 row 1'\necho 'failed: row 2 refused'\nexit 2\n",
			"retro-gate: WARN: seeder exited 2 for "+r+": no summary: line — counted 1 partial-progress line(s)\n",
			"retro-gate: WARN: seeder failed (exit 2) for "+r+": failed: row 2 refused\n",
			sumLine+"ran=1 created=1 skipped-dedup=0 empty=0 unclassifiable=0 absent=0 failed=1 failed-issues=unknown"),
		seedCase("EN3-f", "echo 'empty-input: no delta section'\n", sumLine+"ran=1 created=0 skipped-dedup=0 empty=1 unclassifiable=0 absent=0 failed=0"),
		seedCase("EN3-unclassifiable", "echo 'unclassifiable: numbered list, not a table'\n",
			"retro-gate: WARN: seeder: unclassifiable for "+r+" — needs manual review, no issue auto-staged — see the unclassifiable-items table and tracking-issue proposal: stage-retro-issues.sh <retro> (kit issue #1111/#1129/#1259)\n",
			sumLine+"ran=1 created=0 skipped-dedup=0 empty=0 unclassifiable=1 absent=0 failed=0"),
		seedCase("EN3-unc-summary", "echo 'summary: created=0 skipped-duplicate=0 unclassifiable=2'\n",
			"retro-gate: WARN: seeder: 2 unclassifiable item(s) for "+r+" — see the unclassifiable-items table and tracking issue in the seeder output (stage-retro-issues.sh <retro>) (kit issue #1259)\n",
			sumLine+"ran=1 created=0 skipped-dedup=0 empty=0 unclassifiable=2"),
		seedCase("EN3-unc-both", "echo 'unclassifiable: heading'\necho 'summary: created=0 skipped-duplicate=0 unclassifiable=1'\n",
			sumLine+"ran=1 created=0 skipped-dedup=0 empty=0 unclassifiable=1 absent=0"),
		seedCase("EN3-zero-label", "echo 'retro-closed: all rows shipped'\necho 'no-match: nothing open'\n", sumLine+"ran=1 created=0 skipped-dedup=0 empty=1"),
		seedCase("EN3-no-match+summary", "echo 'summary: created=0 skipped-duplicate=0'\necho 'no-match: every row shipped'\n", sumLine+"ran=1 created=0 skipped-dedup=0 empty=1"),
		seedCase("EN3-absent", "echo 'absent-input: retro not found'\nexit 2\n",
			"retro-gate: WARN: seeder: absent-input for "+r+" (retro not found — verify path)\n",
			sumLine+"ran=1 created=0 skipped-dedup=0 empty=0 unclassifiable=0 absent=1 failed=0 failed-issues=0"),
		seedCase("EN3-absent+summary (#971 A1)", "echo 'absent-input: retro not found'\necho 'summary: created=5 skipped-duplicate=0 failed=2'\nexit 2\n",
			sumLine+"ran=1 created=0 skipped-dedup=0 empty=0 unclassifiable=0 absent=1 failed=0 failed-issues=0"),
		seedCase("EN3-absent-summary-WARN", "exit 0\n", "retro-gate: WARN: seeder exited 0 but no summary: line for "+r+"\n", sumLine+"ran=1 created=0"),
		seedCase("EN3-reason", "echo 'created: #1'\necho 'planned-issue: x'\necho 'real failure line'\nexit 2\n",
			"retro-gate: WARN: seeder failed (exit 2) for "+r+": real failure line\n"),
		seedCase("EN3-reason-typed-wins", "echo 'input-error: bad retro'\necho 'trailing noise' >&2\nexit 2\n",
			"retro-gate: WARN: seeder failed (exit 2) for "+r+": input-error: bad retro\n"),
		seedCase("EN3-reason-empty", "exit 2\n", "retro-gate: WARN: seeder failed (exit 2) for "+r+": (no output)\n"),
		seedCase("EN3-reason-80", "printf 'x%.0s' $(seq 1 120)\necho\nexit 2\n",
			"retro-gate: WARN: seeder failed (exit 2) for "+r+": "+strings.Repeat("x", 80)+"\n"),
		seedCase("EN3-944", "echo 'summary: created=1 skipped-duplicate=0 failed=3'\nexit 2\n",
			"retro-gate: WARN: 3 issue create(s) failed across 1 retro(s): "+r+"\n",
			sumLine+"ran=1 created=1 skipped-dedup=0 empty=0 unclassifiable=0 absent=0 failed=1 failed-issues=3 target=t"),
		seedCase("#971-U4", "echo 'summary: created=1 skipped-duplicate=0'\nexit 2\n",
			"retro-gate: WARN: unknown issue create(s) failed across 1 retro(s): "+r+"\n", "failed=1 failed-issues=unknown"),
		seedCase("#971-U1", "exit 3\n", "retro-gate: WARN: seeder exit 3 for "+r+": unknown mutation outcome — verify on GitHub, do not retry blindly\n"),

		// #1705: exit 3 = unknown mutation outcome, a state of its own.
		seedCase("K1", "echo 'mutation-summary: created=1 failed=0 unknown=2'\nexit 3\n",
			"retro-gate: WARN: seeder exit 3 for "+r+": unknown mutation outcome — verify on GitHub, do not retry blindly\n",
			"retro-gate: WARN: 2 issue create(s) have an UNKNOWN outcome across 1 retro(s): "+r+" — verify on GitHub before re-running; never blind-retry\n",
			"failed=0 failed-issues=0 target=t unknown-outcome-retros=1\n"),
		seedCase("K2", "exit 3\n", "retro-gate: WARN: unknown issue create(s) have an UNKNOWN outcome across 1 retro(s): "+r),
		seedCase("K3", "echo 'summary: created=0 failed=1'\nexit 2\n", "retro-gate: WARN: 1 issue create(s) failed across 1 retro(s): "+r+"\n"),
		seedCase("K5", "echo 'summary: created=0 failed=1'\necho 'mutation-summary: created=0 failed=1 unknown=2'\nexit 2\n",
			"retro-gate: WARN: seeder exit 2 for "+r+": unknown mutation outcome — verify on GitHub, do not retry blindly\n",
			"retro-gate: WARN: 1 issue create(s) failed across 1 retro(s): "+r+"\n", "retro-gate: WARN: 2 issue create(s) have an UNKNOWN outcome"),
		seedCase("K6", "echo 'mutation-summary: created=1 failed=0 unknown=0'\nexit 3\n",
			"retro-gate: WARN: seeder exit 3 for "+r+": unknown=contradictory (exit 3, summary unknown=0) — verify on GitHub, do not retry blindly\n",
			"retro-gate: WARN: unknown issue create(s) have an UNKNOWN outcome"),
		seedCase("K4", "echo 'summary: created=1 skipped-duplicate=0 failed=0'\n", sumLine+"ran=1 created=1 skipped-dedup=0 empty=0 unclassifiable=0 absent=0 failed=0 failed-issues=0 target=t unknown-outcome-retros=0\n"),
		rgCase{id: "K7/SL6", // a degraded line on stderr BEFORE stdout lines is still the logged reason; the stream is one
			setup: func(w *rgWorld) []rgRun {
				return one(seedWorld(w, "echo 'degraded: gh unavailable' >&2\necho 'planned-issue: row 1'\nexit 2\n"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].rc != 0 {
					t.Errorf("rc=%d", rs[0].rc)
				}
				has(t, "stderr", rs[0].err, "retro-gate: WARN: seeder failed (exit 2) for "+r+": degraded: gh unavailable\n")
				has(t, "log", rs[0].lastLog(), "seeding=seeder-degraded:"+r+":degraded: gh unavailable; ran=1")
			}},
		rgCase{id: "SL-seeder-failed-logged",
			setup: func(w *rgWorld) []rgRun { return one(seedWorld(w, "echo 'oops'\nexit 4\n")) },
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "log", rs[0].lastLog(), "seeding=seeder-failed:rc=4:"+r+":oops; ran=1")
			}},
	)
}

// hermetic is a PATH of the tools the gate and verify-retro.sh use: with jq, and with the stub gh only when asked.
func (w *rgWorld) hermetic(gh bool) string {
	dir := w.root + "/hermetic"
	must(w.t, os.MkdirAll(dir, 0o755))
	for _, tool := range []string{"bash", "git", "date", "dirname", "basename", "find", "grep", "egrep", "sed", "awk", "tail", "head", "wc", "mv", "rm", "mkdir", "mktemp", "readlink", "realpath", "stat", "timeout", "sort", "tr", "cut", "cat", "ls", "env", "sleep", "tee", "touch", "jq", "uniq", "tac", "sha1sum", "printf", "seq"} {
		if p, err := exec.LookPath(tool); err == nil {
			_ = os.Symlink(p, dir+"/"+tool)
		}
	}
	if gh {
		_ = os.Symlink(w.stubs+"/gh", dir+"/gh")
	}
	return dir
}
