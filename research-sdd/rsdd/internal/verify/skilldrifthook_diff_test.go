//go:build unix && !nodiff

package verify

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The hook differential: the frozen verify-skill-drift-hook.sh (which runs the frozen verify-skill-drift.sh and
// sources the frozen hook-emit.sh) and the Go hook answer the same world with the same envelope. jq is on the
// PATH of the world, so the script prints the JSON envelope the Go hook always prints.

func (w *sdWorld) sameHook() {
	w.t.Helper()
	gOut, gErr, gRC := w.runGoHook()
	bOut, bErr, bRC := w.runBash("verify-skill-drift-hook.sh")
	if gRC != bRC || w.scrub(gOut) != w.scrub(bOut) || w.scrub(gErr) != w.scrub(bErr) {
		w.t.Errorf("the hook differs from the frozen script\ngo   rc=%d\nstdout %q\nstderr %q\nbash rc=%d\nstdout %q\nstderr %q", gRC, w.scrub(gOut), w.scrub(gErr), bRC, w.scrub(bOut), w.scrub(bErr))
	}
}

type hookScenario struct {
	name  string
	setup func(w *sdWorld)
}

func hookScenarios() []hookScenario {
	stub := func(body string) func(w *sdWorld) { return func(w *sdWorld) { w.installStub(body) } }
	drifted := func(body string) func(w *sdWorld) {
		return func(w *sdWorld) { w.deploy(claudeRel, "stale\n"); w.installStub(body) }
	}
	timeout := func(v string) func(w *sdWorld) {
		return func(w *sdWorld) {
			w.installStub("echo 'verify harness=pi status=degraded x'")
			w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = v
		}
	}
	stale := func(behind int, setup func(w *sdWorld, kit string)) func(w *sdWorld) {
		return func(w *sdWorld) {
			w.installStub("exit 0")
			kit := w.gitKit(behind)
			if setup != nil {
				setup(w, kit)
			}
		}
	}
	long := strings.Repeat("x", 400)
	return []hookScenario{
		{"nothing deployed", stub("exit 0")},
		{"in sync", func(w *sdWorld) { w.deploy(claudeRel, sdKitSkill); w.installStub("exit 0") }},
		{"drift", drifted("exit 0")},
		{"every harness diverged", func(w *sdWorld) { w.deployAll("x\n"); w.installStub("exit 0") }},
		{"could not run", func(w *sdWorld) { w.env["HOME"] = ""; w.installStub("exit 0") }},
		{"could not run and a finding", func(w *sdWorld) { w.env["HOME"] = ""; w.installStub("echo 'verify harness=pi status=degraded x'") }},
		{"typed findings", stub("echo 'verify harness=pi status=degraded a'; echo 'verify kit status=behind 3'; echo 'verify harness=claude status=match'")},
		{"five findings cut to four", stub("for i in 1 2 3 4 5; do echo \"verify harness=h$i status=degraded n$i\"; done")},
		{"findings on stderr", stub("echo 'verify harness=pi status=degraded e' >&2")},
		{"long finding", stub("echo 'verify harness=pi status=degraded " + long + "'")},
		{"drift block", stub(`echo 'verify harness=claude status=drift drifted=a.md,(extra: T -> /x),b.md,c.md,d.md,e.md kept-hand-edit=f,g'`)},
		{"drift block wide", stub("echo 'verify harness=claude status=drift drifted=" + long + " kept-hand-edit=" + long + "'")},
		{"drift without members", stub("echo 'verify harness=claude status=drift nothing'; echo 'verify harness=pi status=drift drifted='")},
		{"drift with empty entries", stub("echo 'verify harness=claude status=drift drifted=,,a,'")},
		{"drift beside typed findings", drifted("echo 'verify harness=pi status=drift drifted=z.md'; echo 'verify kit status=behind 1'")},
		{"drift only annotated", stub("echo 'verify harness=claude status=drift drifted=(extra: A),(extra: B),(extra: C),(extra: D),p'")},
		{"install exits non-zero silently", stub("echo noise; exit 3")},
		{"install exits non-zero with a finding", stub("echo 'verify harness=pi status=degraded x'; exit 3")},
		{"install not executable", func(w *sdWorld) { w.env["RESEARCH_SDD_INSTALL_VERIFY_CMD"] = filepath.Join(w.root, "missing.sh") }},
		{"install is a directory", func(w *sdWorld) { w.env["RESEARCH_SDD_INSTALL_VERIFY_CMD"] = w.root }},
		{"install default path missing", func(w *sdWorld) { delete(w.env, "RESEARCH_SDD_INSTALL_VERIFY_CMD") }},
		{"install timed out", func(w *sdWorld) { w.installStub("exec sleep 30"); w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = "1" }},
		{"timeout empty", timeout("")},
		{"timeout zero", timeout("0")},
		{"timeout text", timeout("abc")},
		{"timeout with a unit", timeout("10s")},
		{"timeout fraction", timeout(".5")},
		{"timeout too long", timeout("1234567")},
		{"timeout padded", timeout("0000007")},
		{"timeout leading zeros", timeout("007")},
		{"timeout hostile", timeout("a b;$(true)'\"x")},
		{"kit not behind", stale(0, nil)},
		{"kit behind within limits", stale(3, nil)},
		{"kit behind over the commit limit", stale(3, func(w *sdWorld, _ string) { w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "2" })},
		{"kit commit limit zero", stale(1, func(w *sdWorld, _ string) { w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "0" })},
		{"kit fetch too old", stale(1, func(w *sdWorld, kit string) { w.ageFetchHead(kit, 10) })},
		{"kit day limit zero", stale(1, func(w *sdWorld, kit string) { w.ageFetchHead(kit, 2); w.env["RESEARCH_SDD_KIT_STALE_MAX_DAYS"] = "0" })},
		{"kit stale and install behind", func(w *sdWorld) {
			stale(4, func(w *sdWorld, _ string) { w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1" })(w)
			w.installStub("echo 'verify kit status=behind by 4'; echo 'verify harness=pi status=degraded x'")
		}},
		{"kit within limits and install behind", func(w *sdWorld) {
			stale(1, nil)(w)
			w.installStub("echo 'verify kit status=behind by 1'")
		}},
		{"kit diverged line wins", func(w *sdWorld) {
			stale(4, func(w *sdWorld, _ string) { w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1" })(w)
			w.installStub("echo 'verify kit status=behind diverged'")
		}},
		{"kit behind line dropped but install failed", func(w *sdWorld) {
			stale(1, nil)(w)
			w.installStub("echo 'verify kit status=behind by 1'; exit 5")
		}},
		{"kit stale after install timed out is skipped", func(w *sdWorld) {
			stale(4, func(w *sdWorld, _ string) { w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1" })(w)
			w.installStub("exec sleep 30")
			w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = "1"
		}},
		{"kit no fetch head", stale(2, func(w *sdWorld, kit string) {
			os.Remove(filepath.Join(kit, ".git", "FETCH_HEAD")) //nolint:errcheck
			w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
		})},
		{"kit no fetch head and over the limit", stale(2, func(w *sdWorld, kit string) {
			os.Remove(filepath.Join(kit, ".git", "FETCH_HEAD")) //nolint:errcheck
			w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1"
		})},
		{"kit no upstream, origin/main fallback", stale(2, func(w *sdWorld, kit string) {
			w.git(kit, "branch", "--unset-upstream")
			w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1"
		})},
		{"kit no upstream, no remote", stale(0, func(w *sdWorld, kit string) {
			w.git(kit, "branch", "--unset-upstream")
			w.git(kit, "remote", "remove", "origin")
			w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
		})},
		{"kit not a checkout, verbose", func(w *sdWorld) {
			w.installStub("exit 0")
			delete(w.env, "RESEARCH_SDD_KIT_STALE_CHECK")
			w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
		}},
		{"kit not a checkout, quiet", func(w *sdWorld) { w.installStub("exit 0"); delete(w.env, "RESEARCH_SDD_KIT_STALE_CHECK") }},
		{"kit dir does not exist, verbose", func(w *sdWorld) {
			w.installStub("exit 0")
			delete(w.env, "RESEARCH_SDD_KIT_STALE_CHECK")
			w.env["RESEARCH_SDD_KIT_DIR"] = filepath.Join(w.root, "absent")
			w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
		}},
		{"kit dir in a subdirectory of the repo", stale(2, func(w *sdWorld, kit string) {
			w.env["RESEARCH_SDD_KIT_DIR"] = filepath.Join(kit, "sub")
			w.put(filepath.Join(kit, "sub", "x"), "x", 0o644)
			w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1"
			w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
		})},
		{"kit dir two levels inside the repo", stale(2, func(w *sdWorld, kit string) {
			w.env["RESEARCH_SDD_KIT_DIR"] = filepath.Join(kit, "a", "b")
			w.put(filepath.Join(kit, "a", "b", "x"), "x", 0o644)
			w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
		})},
		{"kit invalid thresholds", stale(1, func(w *sdWorld, _ string) {
			w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "ten!"
			w.env["RESEARCH_SDD_KIT_STALE_MAX_DAYS"] = ""
		})},
		{"kit more invalid thresholds", stale(1, func(w *sdWorld, _ string) {
			w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "12345678"
			w.env["RESEARCH_SDD_KIT_STALE_MAX_DAYS"] = "-3"
		})},
		{"kit padded thresholds", stale(2, func(w *sdWorld, _ string) {
			w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "000001"
			w.env["RESEARCH_SDD_KIT_STALE_MAX_DAYS"] = "000"
		})},
		{"kit stale with a drifted harness", func(w *sdWorld) {
			stale(3, func(w *sdWorld, _ string) { w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1" })(w)
			w.deploy(piRel, "x\n")
		}},
		{"kit under an unset HOME", func(w *sdWorld) {
			stale(3, func(w *sdWorld, _ string) { w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1" })(w)
			delete(w.env, "HOME")
		}},
	}
}

func TestSkillDriftHookDifferential(t *testing.T) {
	for _, sc := range hookScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			w := newSDWorld(t)
			w.withBash()
			w.env["RESEARCH_SDD_PROFILE"] = "claude"
			sc.setup(w)
			w.sameHook()
		})
	}
}
